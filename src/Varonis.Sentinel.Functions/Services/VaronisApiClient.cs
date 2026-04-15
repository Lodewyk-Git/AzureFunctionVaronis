using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Varonis.Sentinel.Functions.Models;
using Varonis.Sentinel.Functions.Options;
using Varonis.Sentinel.Functions.Utilities;

namespace Varonis.Sentinel.Functions.Services;

public sealed class VaronisApiClient : IVaronisApiClient
{
    private const int ErrorBodyLogLimit = 4096;

    private static readonly HashSet<HttpStatusCode> TransientStatusCodes =
    [
        HttpStatusCode.RequestTimeout,
        HttpStatusCode.TooManyRequests,
        HttpStatusCode.BadGateway,
        HttpStatusCode.ServiceUnavailable,
        HttpStatusCode.GatewayTimeout
    ];

    // Safety skew so we refresh before the token actually expires.
    private static readonly TimeSpan TokenExpirySkew = TimeSpan.FromSeconds(60);

    // Fallback lifetime when Varonis does not return expires_in.
    private static readonly TimeSpan DefaultTokenLifetime = TimeSpan.FromMinutes(10);

    private static readonly IReadOnlyList<string> LegacyAlertColumns =
    [
        "Alert.ID",
        "Alert.Filer.Name",
        "Alert.Time",
        "Alert.User.IsFlagged",
        "Alert.Data.IsSensitive",
        "Alert.Data.IsFlagged",
        "Alert.CloseReason.Name",
        "Alert.Location.SubdivisionName",
        "Alert.Location.CountryName",
        "Alert.Location.AbnormalLocation",
        "Alert.Location.BlacklistedLocation",
        "Alert.Filer.Platform.Name",
        "Alert.TimeUTC",
        "Alert.Initial.Event.TimeLocal",
        "Alert.Initial.Event.TimeUTC",
        "Alert.User.AccountType.AggregatedName",
        "Alert.User.Name",
        "Alert.User.SamAccountName",
        "Alert.User.AccountType.Name",
        "Alert.AssignedToVaronis",
        "Alert.Rule.Severity.Name",
        "Alert.Rule.Name",
        "Alert.Device.HostName",
        "Alert.Asset.Path",
        "Alert.Status.Name",
        "Alert.ActionType.Name",
        "Alert.Rule.Category.Name",
        "Alert.Device.ExternalIPThreatTypesName",
        "Alert.Device.IsMaliciousExternalIP",
        "Alert.MitreTactic.Name",
        "Alert.ClosedByName",
        "Alert.EventsCount",
        "Alert.IngestTime",
        "Alert.Status.ID",
        "Alert.Rule.Severity.ID",
        "Alert.Rule.ID",
        "Alert.User.SidID"
    ];

    private static readonly IReadOnlyDictionary<string, string> LegacySeverityIds =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["High"] = "0",
            ["Medium"] = "1",
            ["Low"] = "2",
            ["Informational"] = "3"
        };

    private static readonly IReadOnlyDictionary<string, string> LegacyStatusIds =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["New"] = "1",
            ["Under Investigation"] = "2",
            ["Closed"] = "3",
            ["Action Required"] = "4",
            ["Auto-Resolved"] = "5"
        };

    private readonly HttpClient _httpClient;
    private readonly ISecretProvider _secretProvider;
    private readonly IVaronisTokenCache _tokenCache;
    private readonly VaronisOptions _options;
    private readonly ILogger<VaronisApiClient> _logger;

    public VaronisApiClient(
        HttpClient httpClient,
        ISecretProvider secretProvider,
        IVaronisTokenCache tokenCache,
        IOptions<VaronisOptions> options,
        ILogger<VaronisApiClient> logger)
    {
        _httpClient = httpClient;
        _secretProvider = secretProvider;
        _tokenCache = tokenCache;
        _options = options.Value;
        _logger = logger;
    }

    public async Task<string> GetAccessTokenAsync(CancellationToken cancellationToken = default)
    {
        if (_tokenCache.TryGet(out var cached))
        {
            return cached;
        }

        await _tokenCache.RefreshLock.WaitAsync(cancellationToken);
        try
        {
            // Re-check inside the lock to avoid a thundering herd after refresh.
            if (_tokenCache.TryGet(out cached))
            {
                return cached;
            }

            var apiKey = await _secretProvider.GetVaronisApiKeyAsync(cancellationToken);

            using var response = await SendWithRetryAsync(() =>
            {
                var request = new HttpRequestMessage(HttpMethod.Post, _options.AuthPath);
                request.Headers.Add("x-api-key", apiKey);
                request.Content = new FormUrlEncodedContent(new Dictionary<string, string>
                {
                    ["grant_type"] = "varonis_custom"
                });

                return request;
            }, cancellationToken);

            response.EnsureSuccessStatusCode();
            var tokenResponse = await response.Content.ReadFromJsonAsync<VaronisTokenResponse>(JsonDefaults.SerializerOptions, cancellationToken);

            if (tokenResponse is null || string.IsNullOrWhiteSpace(tokenResponse.AccessToken))
            {
                throw new InvalidOperationException("Varonis token response did not contain an access token.");
            }

            var lifetime = tokenResponse.ExpiresInSeconds > 0
                ? TimeSpan.FromSeconds(tokenResponse.ExpiresInSeconds)
                : DefaultTokenLifetime;

            if (lifetime > TokenExpirySkew)
            {
                var expiresUtc = DateTimeOffset.UtcNow.Add(lifetime).Subtract(TokenExpirySkew);
                _tokenCache.Set(tokenResponse.AccessToken, expiresUtc);
                _logger.LogInformation(
                    "Cached Varonis access token. ExpiresUtc={ExpiresUtc}, LifetimeSeconds={LifetimeSeconds}.",
                    expiresUtc,
                    (int)lifetime.TotalSeconds);
            }

            return tokenResponse.AccessToken;
        }
        finally
        {
            _tokenCache.RefreshLock.Release();
        }
    }

    public async Task<VaronisSearchResponse> SearchAlertsAsync(
        string accessToken,
        VaronisSearchRequest request,
        CancellationToken cancellationToken = default)
    {
        using var response = await SendWithRetryAsync(() =>
        {
            var requestMessage = new HttpRequestMessage(HttpMethod.Post, _options.SearchPath);
            requestMessage.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
            requestMessage.Content = JsonContent.Create(request);
            return requestMessage;
        }, cancellationToken);

        if (response.IsSuccessStatusCode)
        {
            var payload = await response.Content.ReadFromJsonAsync<VaronisSearchResponse>(JsonDefaults.SerializerOptions, cancellationToken);
            return payload ?? new VaronisSearchResponse();
        }

        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);
        if (response.StatusCode != HttpStatusCode.BadRequest)
        {
            throw CreateSearchRequestException(response.StatusCode, responseBody, "modern");
        }

        _logger.LogWarning(
            "Varonis search request with modern payload returned 400. Retrying with legacy payload. ResponseBody={ResponseBody}",
            Truncate(responseBody, ErrorBodyLogLimit));

        var legacyRequest = BuildLegacySearchRequest(request);
        using var legacyResponse = await SendWithRetryAsync(() =>
        {
            var requestMessage = new HttpRequestMessage(HttpMethod.Post, _options.SearchPath);
            requestMessage.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
            requestMessage.Content = JsonContent.Create(legacyRequest, options: JsonDefaults.SerializerOptions);
            return requestMessage;
        }, cancellationToken);

        if (!legacyResponse.IsSuccessStatusCode)
        {
            var legacyResponseBody = await legacyResponse.Content.ReadAsStringAsync(cancellationToken);
            throw CreateSearchRequestException(legacyResponse.StatusCode, legacyResponseBody, "legacy");
        }

        _logger.LogInformation("Varonis legacy search payload succeeded after modern payload 400.");
        var legacyPayload = await legacyResponse.Content.ReadFromJsonAsync<VaronisSearchResponse>(JsonDefaults.SerializerOptions, cancellationToken);
        return legacyPayload ?? new VaronisSearchResponse();
    }

    public async Task<VaronisSearchResponse> GetSearchResultsAsync(
        string accessToken,
        string searchUrl,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(searchUrl))
        {
            throw new ArgumentException("searchUrl cannot be null or empty.", nameof(searchUrl));
        }

        using var response = await SendWithRetryAsync(() =>
        {
            var requestMessage = new HttpRequestMessage(HttpMethod.Get, BuildSearchUri(searchUrl));
            requestMessage.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
            return requestMessage;
        }, cancellationToken);

        response.EnsureSuccessStatusCode();
        var payload = await response.Content.ReadFromJsonAsync<VaronisSearchResponse>(JsonDefaults.SerializerOptions, cancellationToken);
        return payload ?? new VaronisSearchResponse();
    }

    private async Task<HttpResponseMessage> SendWithRetryAsync(
        Func<HttpRequestMessage> requestFactory,
        CancellationToken cancellationToken)
    {
        var maxAttempts = _options.RetryCount + 1;

        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            using var request = requestFactory();

            try
            {
                var response = await _httpClient.SendAsync(request, cancellationToken);
                if (TransientStatusCodes.Contains(response.StatusCode) && attempt < maxAttempts)
                {
                    var delay = GetDelay(attempt);
                    _logger.LogWarning(
                        "Transient Varonis API response ({StatusCode}) on attempt {Attempt}/{MaxAttempts}; retrying in {Delay}.",
                        (int)response.StatusCode,
                        attempt,
                        maxAttempts,
                        delay);

                    response.Dispose();
                    await Task.Delay(delay, cancellationToken);
                    continue;
                }

                return response;
            }
            catch (HttpRequestException ex) when (attempt < maxAttempts)
            {
                var delay = GetDelay(attempt);
                _logger.LogWarning(
                    ex,
                    "Transient Varonis API request failure on attempt {Attempt}/{MaxAttempts}; retrying in {Delay}.",
                    attempt,
                    maxAttempts,
                    delay);

                await Task.Delay(delay, cancellationToken);
            }
        }

        throw new InvalidOperationException("Varonis API request failed after all retry attempts.");
    }

    internal Uri BuildSearchUri(string searchUrl)
    {
        if (Uri.TryCreate(searchUrl, UriKind.Absolute, out var absoluteUri))
        {
            var baseUri = _httpClient.BaseAddress;
            if (baseUri is not null &&
                !absoluteUri.Host.Equals(baseUri.Host, StringComparison.OrdinalIgnoreCase))
            {
                _logger.LogWarning(
                    "Rejected search URL with unexpected host '{RejectedHost}'. Expected '{ExpectedHost}'.",
                    absoluteUri.Host,
                    baseUri.Host);
                throw new InvalidOperationException(
                    $"Search URL host '{absoluteUri.Host}' does not match the configured Varonis base URL host '{baseUri.Host}'.");
            }

            return absoluteUri;
        }

        if (searchUrl.StartsWith('/'))
        {
            return new Uri(searchUrl, UriKind.Relative);
        }

        return new Uri($"/app/dataquery/api/search/{searchUrl.TrimStart('/')}", UriKind.Relative);
    }

    private TimeSpan GetDelay(int attempt)
    {
        var baseDelay = TimeSpan.FromSeconds(_options.RetryBaseDelaySeconds);
        var exponentialDelay = TimeSpan.FromMilliseconds(baseDelay.TotalMilliseconds * Math.Pow(2, attempt - 1));
        var jitter = TimeSpan.FromMilliseconds(Random.Shared.Next(0, 250));
        return exponentialDelay + jitter;
    }

    private LegacySearchRequest BuildLegacySearchRequest(VaronisSearchRequest request)
    {
        var filters = new List<LegacySearchFilter>
        {
            new()
            {
                Operator = "Between",
                Path = "Alert.TimeUTC",
                Values =
                [
                    new LegacyDateRangeValue
                    {
                        StartDate = request.FromUtc.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss"),
                        EndDate = request.ToUtc.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss")
                    }
                ]
            }
        };

        var severityValues = request.Severity
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .Select(item =>
            {
                if (LegacySeverityIds.TryGetValue(item, out var value))
                {
                    return new LegacyFilterValue { Value = value, DisplayValue = item };
                }

                return null;
            })
            .Where(item => item is not null)
            .Select(item => item!)
            .ToList();

        if (severityValues.Count > 0)
        {
            filters.Add(new LegacySearchFilter
            {
                Operator = "In",
                Path = "Alert.Rule.Severity.ID",
                Values = severityValues.Cast<object>().ToList()
            });
        }

        var statusValues = request.Status
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .Select(item =>
            {
                if (LegacyStatusIds.TryGetValue(item, out var value))
                {
                    return new LegacyFilterValue { Value = value, DisplayValue = item };
                }

                return null;
            })
            .Where(item => item is not null)
            .Select(item => item!)
            .ToList();

        if (statusValues.Count > 0)
        {
            filters.Add(new LegacySearchFilter
            {
                Operator = "In",
                Path = "Alert.Status.ID",
                Values = statusValues.Cast<object>().ToList()
            });
        }

        var ruleIdValues = request.ThreatDetectionPolicies
            .Where(item => int.TryParse(item, out _))
            .Select(item => new LegacyFilterValue { Value = item, DisplayValue = item })
            .ToList();

        if (ruleIdValues.Count > 0)
        {
            filters.Add(new LegacySearchFilter
            {
                Operator = "In",
                Path = "Alert.Rule.ID",
                Values = ruleIdValues.Cast<object>().ToList()
            });
        }
        else if (request.ThreatDetectionPolicies.Count > 0)
        {
            _logger.LogWarning(
                "ThreatDetectionPolicies were provided as names, but the legacy payload only supports numeric rule IDs. Ignoring these values: {Policies}",
                string.Join(", ", request.ThreatDetectionPolicies));
        }

        // Exclude aggregated rows so only actionable alert instances are returned.
        filters.Add(new LegacySearchFilter
        {
            Operator = "Equals",
            Path = "Alert.AggregationFilter",
            Values =
            [
                new LegacyFilterValue
                {
                    DisplayValue = "Alert.AggregationFilter",
                    Value = "1"
                }
            ]
        });

        return new LegacySearchRequest
        {
            Query = new LegacySearchQuery
            {
                EntityName = "Alert",
                Filter = new LegacyFilterGroup
                {
                    FilterOperator = "And",
                    Filters = filters
                }
            },
            Rows = new LegacyRowDataRequest
            {
                Columns = LegacyAlertColumns,
                Ordering =
                [
                    new LegacyOrdering
                    {
                        Path = "Alert.TimeUTC",
                        SortOrder = "Asc"
                    }
                ]
            },
            RequestParams = new LegacyRequestParams
            {
                IgnoreCache = true,
                SearchSource = 1,
                SearchSourceName = "Alert"
            }
        };
    }

    private static Exception CreateSearchRequestException(HttpStatusCode statusCode, string responseBody, string payloadKind)
    {
        var message =
            $"Varonis search request failed with {(int)statusCode} ({statusCode}) using {payloadKind} payload. ResponseBody={Truncate(responseBody, ErrorBodyLogLimit)}";
        return new HttpRequestException(message, null, statusCode);
    }

    private static string Truncate(string value, int maxLength)
    {
        if (string.IsNullOrEmpty(value) || value.Length <= maxLength)
        {
            return value;
        }

        return $"{value[..maxLength]}...(truncated)";
    }

    private sealed class LegacySearchRequest
    {
        [JsonPropertyName("query")]
        public LegacySearchQuery Query { get; init; } = new();

        [JsonPropertyName("rows")]
        public LegacyRowDataRequest Rows { get; init; } = new();

        [JsonPropertyName("facets")]
        public object? Facets { get; init; }

        [JsonPropertyName("requestParams")]
        public LegacyRequestParams RequestParams { get; init; } = new();
    }

    private sealed class LegacySearchQuery
    {
        [JsonPropertyName("entityName")]
        public string EntityName { get; init; } = "Alert";

        [JsonPropertyName("filter")]
        public LegacyFilterGroup Filter { get; init; } = new();

        [JsonPropertyName("timeZone")]
        public string? TimeZone { get; init; }
    }

    private sealed class LegacyFilterGroup
    {
        [JsonPropertyName("filters")]
        public IList<LegacySearchFilter> Filters { get; init; } = new List<LegacySearchFilter>();

        [JsonPropertyName("filterOperator")]
        public string FilterOperator { get; init; } = "And";
    }

    private sealed class LegacySearchFilter
    {
        [JsonPropertyName("operator")]
        public string Operator { get; init; } = string.Empty;

        [JsonPropertyName("path")]
        public string Path { get; init; } = string.Empty;

        [JsonPropertyName("values")]
        public IList<object> Values { get; init; } = new List<object>();
    }

    private sealed class LegacyFilterValue
    {
        [JsonPropertyName("value")]
        public string Value { get; init; } = string.Empty;

        [JsonPropertyName("displayValue")]
        public string DisplayValue { get; init; } = string.Empty;
    }

    private sealed class LegacyDateRangeValue
    {
        [JsonPropertyName("startDate")]
        public string StartDate { get; init; } = string.Empty;

        [JsonPropertyName("endDate")]
        public string EndDate { get; init; } = string.Empty;
    }

    private sealed class LegacyRowDataRequest
    {
        [JsonPropertyName("columns")]
        public IReadOnlyList<string> Columns { get; init; } = Array.Empty<string>();

        [JsonPropertyName("ordering")]
        public IList<LegacyOrdering> Ordering { get; init; } = new List<LegacyOrdering>();
    }

    private sealed class LegacyOrdering
    {
        [JsonPropertyName("path")]
        public string Path { get; init; } = string.Empty;

        [JsonPropertyName("sortOrder")]
        public string SortOrder { get; init; } = "Asc";
    }

    private sealed class LegacyRequestParams
    {
        [JsonPropertyName("ignoreCache")]
        public bool IgnoreCache { get; init; }

        [JsonPropertyName("searchSource")]
        public int SearchSource { get; init; }

        [JsonPropertyName("searchSourceName")]
        public string SearchSourceName { get; init; } = "Alert";
    }
}
