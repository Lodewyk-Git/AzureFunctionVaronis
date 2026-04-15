using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
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
    private static readonly JsonElement NullJsonElement = JsonDocument.Parse("null").RootElement.Clone();

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

            if (!response.IsSuccessStatusCode)
            {
                var errorBody = await response.Content.ReadAsStringAsync(cancellationToken);
                _logger.LogError(
                    "Varonis token endpoint returned non-success {StatusCode}. AuthPath={AuthPath}, ResponseBody={ResponseBody}",
                    (int)response.StatusCode,
                    _options.AuthPath,
                    Truncate(errorBody, ErrorBodyLogLimit));
                throw new HttpRequestException(
                    $"Varonis token endpoint returned {(int)response.StatusCode} ({response.StatusCode}). ResponseBody={Truncate(errorBody, ErrorBodyLogLimit)}",
                    inner: null,
                    statusCode: response.StatusCode);
            }

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
        // This tenant's /search endpoint wants the query/rows/requestParams shape.
        // The old "modern" shape (fromUtc/toUtc/severity) is rejected with
        //   400 "Search request must contain a query field"
        // so send the legacy shape directly. We keep the modern fallback in case we're
        // ever pointed at a newer endpoint that prefers the other way round.
        var legacyRequest = BuildLegacySearchRequest(request);

        // Log the outbound payload once per run so the actual filter shape (Alert.TimeUTC bounds,
        // severity/status IDs, AggregationFilter) is queryable in App Insights traces. This is the
        // single most useful diagnostic when Varonis returns "0 rows" - it's almost always a filter
        // that's tighter than expected.
        var legacyRequestBody = JsonSerializer.Serialize(legacyRequest, JsonDefaults.SerializerOptions);
        _logger.LogInformation(
            "Varonis search request prepared. PayloadKind=legacy, FromUtc={FromUtc}, ToUtc={ToUtc}, RequestBody={RequestBody}",
            request.FromUtc,
            request.ToUtc,
            Truncate(legacyRequestBody, ErrorBodyLogLimit));

        using var legacyResponse = await SendWithRetryAsync(() =>
        {
            var requestMessage = new HttpRequestMessage(HttpMethod.Post, _options.SearchPath);
            requestMessage.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
            requestMessage.Content = JsonContent.Create(legacyRequest, options: JsonDefaults.SerializerOptions);
            return requestMessage;
        }, cancellationToken);

        if (legacyResponse.IsSuccessStatusCode)
        {
            return await ParseSearchResponseAsync(legacyResponse, "legacy", cancellationToken);
        }

        // Legacy shape rejected - some tenants run a strictly modern API. Try the modern shape.
        var legacyErrorBody = await legacyResponse.Content.ReadAsStringAsync(cancellationToken);
        if (legacyResponse.StatusCode != HttpStatusCode.BadRequest)
        {
            _logger.LogError(
                "Varonis search returned non-success {StatusCode} using legacy payload. SearchPath={SearchPath}, ResponseBody={ResponseBody}",
                (int)legacyResponse.StatusCode,
                _options.SearchPath,
                Truncate(legacyErrorBody, ErrorBodyLogLimit));
            throw CreateSearchRequestException(legacyResponse.StatusCode, legacyErrorBody, "legacy");
        }

        _logger.LogWarning(
            "Varonis legacy payload returned 400. Retrying with modern payload. ResponseBody={ResponseBody}",
            Truncate(legacyErrorBody, ErrorBodyLogLimit));

        using var modernResponse = await SendWithRetryAsync(() =>
        {
            var requestMessage = new HttpRequestMessage(HttpMethod.Post, _options.SearchPath);
            requestMessage.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
            requestMessage.Content = JsonContent.Create(request);
            return requestMessage;
        }, cancellationToken);

        if (!modernResponse.IsSuccessStatusCode)
        {
            var modernErrorBody = await modernResponse.Content.ReadAsStringAsync(cancellationToken);
            _logger.LogError(
                "Varonis search returned non-success {StatusCode} using modern payload (after legacy 400). SearchPath={SearchPath}, ResponseBody={ResponseBody}",
                (int)modernResponse.StatusCode,
                _options.SearchPath,
                Truncate(modernErrorBody, ErrorBodyLogLimit));
            throw CreateSearchRequestException(modernResponse.StatusCode, modernErrorBody, "modern");
        }

        _logger.LogInformation("Varonis modern search payload succeeded after legacy payload 400.");
        return await ParseSearchResponseAsync(modernResponse, "modern", cancellationToken);
    }

    /// <summary>
    /// Tolerant parser: Varonis tenants have shipped at least three response shapes for /search:
    ///   1. { columns: ["Alert.ID", ...], rows: [[...], ...], hasMore, searchUrl, nextSearchUrl }
    ///   2. { columns: [{displayName, path, dataType}, ...], rows: [[...], ...], ... }
    ///   3. { data: { columns: [...], rows: [...] }, status/searchId/... }
    ///   4. A bare array of row objects.
    /// Deserializing directly into VaronisSearchResponse fails on shapes 2-4 because the model
    /// assumes shape 1. Parse via JsonDocument, identify the shape, and materialise our model
    /// out of whatever we found. Raw body (truncated) is always logged at Information so we can
    /// verify against prod without replaying.
    /// </summary>
    private async Task<VaronisSearchResponse> ParseSearchResponseAsync(
        HttpResponseMessage response,
        string payloadKind,
        CancellationToken cancellationToken)
    {
        var rawBody = await response.Content.ReadAsStringAsync(cancellationToken);
        _logger.LogInformation(
            "Varonis search response received. PayloadKind={PayloadKind}, ByteLength={ByteLength}, Body={Body}",
            payloadKind,
            rawBody?.Length ?? 0,
            Truncate(rawBody ?? string.Empty, ErrorBodyLogLimit));

        if (string.IsNullOrWhiteSpace(rawBody))
        {
            return new VaronisSearchResponse();
        }

        try
        {
            using var document = System.Text.Json.JsonDocument.Parse(rawBody);
            return MapFlexibleSearchResponse(document.RootElement);
        }
        catch (System.Text.Json.JsonException ex)
        {
            _logger.LogError(
                ex,
                "Failed to parse Varonis search response as JSON. PayloadKind={PayloadKind}.",
                payloadKind);
            throw;
        }
    }

    private static VaronisSearchResponse MapFlexibleSearchResponse(JsonElement root)
    {
        // Shape 3 first: unwrap { data: {...} } if present.
        if (root.ValueKind == JsonValueKind.Object &&
            root.TryGetProperty("data", out var dataElement) &&
            dataElement.ValueKind == JsonValueKind.Object &&
            (dataElement.TryGetProperty("rows", out _) || dataElement.TryGetProperty("columns", out _)))
        {
            root = dataElement;
        }

        if (TryExtractSearchResultLink(root, out var searchResultLink))
        {
            // Same scan also extracts the terminate URL when present, so the timer function can
            // close the search server-side after pagination completes.
            TryExtractTerminateLink(root, out var terminateLink);
            return new VaronisSearchResponse
            {
                SearchUrl = searchResultLink,
                NextSearchUrl = searchResultLink,
                HasMore = true,
                TerminateUrl = terminateLink
            };
        }

        // Shape 4: root is a JSON array of row objects. Harvest union of keys as columns.
        if (root.ValueKind == JsonValueKind.Array)
        {
            var columnsSet = new LinkedHashSet();
            var rows = new List<List<JsonElement>>();
            foreach (var item in root.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                foreach (var prop in item.EnumerateObject())
                {
                    columnsSet.Add(prop.Name);
                }
            }

            foreach (var item in root.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                var row = new List<JsonElement>();
                foreach (var column in columnsSet.Items)
                {
                    row.Add(item.TryGetProperty(column, out var value)
                        ? value.Clone()
                        : NullJsonElement);
                }
                rows.Add(row);
            }

            return new VaronisSearchResponse
            {
                Columns = columnsSet.Items.ToList(),
                Rows = rows,
                HasMore = false
            };
        }

        if (root.ValueKind != JsonValueKind.Object)
        {
            return new VaronisSearchResponse();
        }

        var columns = ExtractColumnNames(root);
        var rowMatrix = ExtractRows(root);
        var hasMore = root.TryGetProperty("hasMore", out var hm) && hm.ValueKind == JsonValueKind.True;
        var searchUrl = TryGetString(root, "searchUrl");
        var nextSearchUrl = TryGetString(root, "nextSearchUrl");

        return new VaronisSearchResponse
        {
            Columns = columns,
            Rows = rowMatrix,
            HasMore = hasMore,
            SearchUrl = searchUrl,
            NextSearchUrl = nextSearchUrl
        };
    }

    private static List<string> ExtractColumnNames(JsonElement root)
    {
        foreach (var candidate in new[]
                 {
                     new[] { "columns" },
                     new[] { "rowsData", "attributePaths" },
                     new[] { "attributePaths" },
                     new[] { "rowsData", "columns" }
                 })
        {
            if (!TryGetNestedProperty(root, out var columnsElement, candidate) ||
                columnsElement.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            var result = new List<string>();
            foreach (var column in columnsElement.EnumerateArray())
            {
                if (column.ValueKind == JsonValueKind.String)
                {
                    result.Add(column.GetString() ?? string.Empty);
                    continue;
                }

                if (column.ValueKind == JsonValueKind.Object)
                {
                    // Prefer the Varonis legacy 'path' (e.g. "Alert.ID") so mapper rules match.
                    var path = TryGetString(column, "path")
                               ?? TryGetString(column, "pathName")
                               ?? TryGetString(column, "name")
                               ?? TryGetString(column, "displayName");
                    result.Add(path ?? string.Empty);
                }
            }

            if (result.Count > 0)
            {
                return result;
            }
        }

        return new List<string>();
    }

    private static List<List<JsonElement>> ExtractRows(JsonElement root)
    {
        foreach (var candidate in new[]
                 {
                     new[] { "rows" },
                     new[] { "rowsData", "rows" },
                     new[] { "rowDatas" },
                     new[] { "results" },
                     new[] { "items" }
                 })
        {
            if (!TryGetNestedProperty(root, out var rowsElement, candidate) ||
                rowsElement.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            var rows = new List<List<JsonElement>>();
            foreach (var rowElement in rowsElement.EnumerateArray())
            {
                if (rowElement.ValueKind == JsonValueKind.Array)
                {
                    rows.Add(rowElement.EnumerateArray().Select(e => e.Clone()).ToList());
                    continue;
                }

                if (rowElement.ValueKind == JsonValueKind.Object &&
                    rowElement.TryGetProperty("row", out var nestedRow) &&
                    nestedRow.ValueKind == JsonValueKind.Array)
                {
                    rows.Add(nestedRow.EnumerateArray().Select(e => e.Clone()).ToList());
                    continue;
                }

                if (rowElement.ValueKind == JsonValueKind.Object)
                {
                    // Object row: keep values in insertion order; mapper reconstructs by column.
                    rows.Add(rowElement.EnumerateObject().Select(p => p.Value.Clone()).ToList());
                }
            }

            return rows;
        }

        return new List<List<JsonElement>>();
    }

    private static bool TryExtractSearchResultLink(JsonElement root, out string? link)
    {
        // Known top-level forms:
        // - { searchUrl: "..." }
        // - { nextSearchUrl: "..." }
        // - { rowLink: "..." }
        // - { rows: "/app/dataquery/api/search/<id>/rows" }   <-- legacy 201
        // - { searchLinks: [{ path: "...", rel: "RowsV3" }, ...] }
        // - [ { path: "...", rel: "RowsV3" } ]
        if (root.ValueKind == JsonValueKind.String)
        {
            var value = root.GetString();
            if (!string.IsNullOrWhiteSpace(value))
            {
                link = value;
                return true;
            }
        }

        if (root.ValueKind == JsonValueKind.Object)
        {
            foreach (var name in new[] { "nextSearchUrl", "searchUrl", "rowLink", "rowsLink", "rows", "path", "href", "url" })
            {
                var value = TryGetString(root, name);
                if (!string.IsNullOrWhiteSpace(value) && LooksLikeSearchPath(value))
                {
                    link = value;
                    return true;
                }
            }

            foreach (var collectionName in new[] { "searchLinks", "links", "_links" })
            {
                if (TryGetNestedProperty(root, out var links, collectionName) &&
                    TryExtractSearchResultLink(links, out link))
                {
                    return true;
                }
            }
        }

        if (root.ValueKind == JsonValueKind.Array)
        {
            // First pass: prefer an entry that explicitly identifies itself as the rows link
            // (Varonis async-search handoff: [{location, dataType: "rows"}, {location, dataType: "terminate"}, {location, dataType: "searchId"}]).
            foreach (var item in root.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                var dataType = TryGetString(item, "dataType")
                    ?? TryGetString(item, "rel")
                    ?? TryGetString(item, "type");
                if (string.IsNullOrWhiteSpace(dataType))
                {
                    continue;
                }

                var isRows = dataType.Equals("rows", StringComparison.OrdinalIgnoreCase) ||
                             dataType.StartsWith("rows", StringComparison.OrdinalIgnoreCase) ||
                             dataType.Equals("RowsV3", StringComparison.OrdinalIgnoreCase);
                if (!isRows)
                {
                    continue;
                }

                var location = TryGetString(item, "location")
                    ?? TryGetString(item, "path")
                    ?? TryGetString(item, "href")
                    ?? TryGetString(item, "url")
                    ?? TryGetString(item, "rowLink")
                    ?? TryGetString(item, "rows");
                if (!string.IsNullOrWhiteSpace(location))
                {
                    link = location;
                    return true;
                }
            }

            // Second pass: fall back to any string or path-like entry.
            foreach (var item in root.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.String)
                {
                    var value = item.GetString();
                    if (!string.IsNullOrWhiteSpace(value) && LooksLikeSearchPath(value))
                    {
                        link = value;
                        return true;
                    }
                }

                if (item.ValueKind == JsonValueKind.Object)
                {
                    foreach (var name in new[] { "location", "path", "href", "url", "rowLink", "rows" })
                    {
                        var value = TryGetString(item, name);
                        if (!string.IsNullOrWhiteSpace(value) && LooksLikeSearchPath(value))
                        {
                            link = value;
                            return true;
                        }
                    }
                }
            }
        }

        link = null;
        return false;
    }

    private static bool LooksLikeSearchPath(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        return value.Contains("/search/", StringComparison.OrdinalIgnoreCase) ||
               value.Contains("/dataquery/", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Looks for the "terminate" entry in a Varonis async-search handoff array. Mirror of
    /// TryExtractSearchResultLink but matches dataType == "terminate" (or rel/type variants).
    /// Returns false silently if the response shape doesn't carry a terminate URL - it's optional.
    /// </summary>
    private static bool TryExtractTerminateLink(JsonElement root, out string? link)
    {
        link = null;
        if (root.ValueKind != JsonValueKind.Array)
        {
            return false;
        }

        foreach (var item in root.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object)
            {
                continue;
            }

            var dataType = TryGetString(item, "dataType")
                ?? TryGetString(item, "rel")
                ?? TryGetString(item, "type");
            if (string.IsNullOrWhiteSpace(dataType) ||
                !dataType.Equals("terminate", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var location = TryGetString(item, "location")
                ?? TryGetString(item, "path")
                ?? TryGetString(item, "href")
                ?? TryGetString(item, "url");
            if (!string.IsNullOrWhiteSpace(location))
            {
                link = location;
                return true;
            }
        }

        return false;
    }

    private static bool TryGetNestedProperty(JsonElement element, out JsonElement value, params string[] path)
    {
        value = element;
        foreach (var segment in path)
        {
            if (!TryGetPropertyCaseInsensitive(value, segment, out value))
            {
                return false;
            }
        }

        return true;
    }

    private static bool TryGetPropertyCaseInsensitive(JsonElement element, string propertyName, out JsonElement value)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            value = default;
            return false;
        }

        foreach (var property in element.EnumerateObject())
        {
            if (property.Name.Equals(propertyName, StringComparison.OrdinalIgnoreCase))
            {
                value = property.Value;
                return true;
            }
        }

        value = default;
        return false;
    }

    private static string? TryGetString(JsonElement element, string propertyName)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        if (!TryGetPropertyCaseInsensitive(element, propertyName, out var prop))
        {
            return null;
        }

        return prop.ValueKind == JsonValueKind.String ? prop.GetString() : null;
    }

    /// <summary>Minimal ordered set - avoids pulling in a package or taking a dependency on .NET 9.</summary>
    private sealed class LinkedHashSet
    {
        private readonly HashSet<string> _seen = new(StringComparer.Ordinal);
        public List<string> Items { get; } = new();

        public void Add(string value)
        {
            if (_seen.Add(value))
            {
                Items.Add(value);
            }
        }
    }

    // Varonis async search: GET /rows can return 304 either because the search is still building
    // (POST /search returns 201 immediately and queues the search) or because the search produced
    // zero rows. We can't distinguish these without polling. Try a few times with backoff before
    // accepting "no rows" as the final answer.
    private static readonly TimeSpan[] RowsPollDelays =
    [
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
        TimeSpan.FromSeconds(8)
    ];

    public async Task<VaronisSearchResponse> GetSearchResultsAsync(
        string accessToken,
        string searchUrl,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(searchUrl))
        {
            throw new ArgumentException("searchUrl cannot be null or empty.", nameof(searchUrl));
        }

        var attempt = 0;
        while (true)
        {
            using var response = await SendWithRetryAsync(() =>
            {
                var requestMessage = new HttpRequestMessage(HttpMethod.Get, BuildSearchUri(searchUrl));
                requestMessage.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
                return requestMessage;
            }, cancellationToken);

            // 204 = empty rows definitively. Accept immediately.
            if (response.StatusCode == HttpStatusCode.NoContent)
            {
                _logger.LogInformation(
                    "Varonis pagination GET returned 204 No Content; accepting as empty result. SearchUrl={SearchUrl}",
                    searchUrl);
                return new VaronisSearchResponse();
            }

            // 304 = ambiguous (still building or genuinely empty). Poll with backoff.
            if (response.StatusCode == HttpStatusCode.NotModified)
            {
                if (attempt < RowsPollDelays.Length)
                {
                    var delay = RowsPollDelays[attempt];
                    _logger.LogInformation(
                        "Varonis pagination GET returned 304 (attempt {Attempt}/{MaxAttempts}). Waiting {Delay} for async search to complete. SearchUrl={SearchUrl}",
                        attempt + 1,
                        RowsPollDelays.Length + 1,
                        delay,
                        searchUrl);
                    await Task.Delay(delay, cancellationToken);
                    attempt++;
                    continue;
                }

                _logger.LogInformation(
                    "Varonis pagination GET still 304 after {MaxAttempts} attempts; treating as empty result. SearchUrl={SearchUrl}",
                    RowsPollDelays.Length + 1,
                    searchUrl);
                return new VaronisSearchResponse();
            }

            if (!response.IsSuccessStatusCode)
            {
                var errorBody = await response.Content.ReadAsStringAsync(cancellationToken);
                _logger.LogError(
                    "Varonis pagination GET returned non-success {StatusCode}. SearchUrl={SearchUrl}, ResponseBody={ResponseBody}",
                    (int)response.StatusCode,
                    searchUrl,
                    Truncate(errorBody, ErrorBodyLogLimit));
                throw CreateSearchRequestException(response.StatusCode, errorBody, "pagination");
            }

            return await ParseSearchResponseAsync(response, "pagination", cancellationToken);
        }
    }

    public async Task TryTerminateSearchAsync(
        string accessToken,
        string terminateUrl,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(terminateUrl))
        {
            return;
        }

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, BuildSearchUri(terminateUrl));
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
            // Some tenants require an explicit empty body on this endpoint; send one to be safe.
            request.Content = new StringContent(string.Empty);

            using var response = await _httpClient.SendAsync(request, cancellationToken);
            if (response.IsSuccessStatusCode)
            {
                _logger.LogInformation(
                    "Varonis search terminated. TerminateUrl={TerminateUrl}, StatusCode={StatusCode}",
                    terminateUrl,
                    (int)response.StatusCode);
                return;
            }

            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            _logger.LogWarning(
                "Varonis terminate POST returned non-success {StatusCode}. TerminateUrl={TerminateUrl}, ResponseBody={ResponseBody}",
                (int)response.StatusCode,
                terminateUrl,
                Truncate(body, ErrorBodyLogLimit));
        }
        catch (Exception ex)
        {
            // Best-effort cleanup. The search will eventually expire on the Varonis side; we never
            // fail the timer run because we couldn't close it ourselves.
            _logger.LogWarning(
                ex,
                "Varonis terminate POST threw. Run continues. TerminateUrl={TerminateUrl}",
                terminateUrl);
        }
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
                    // Read body before disposing so we can include it in the warn log; transient
                    // bodies (rate-limit JSON, gateway HTML) are usually small.
                    var transientBody = string.Empty;
                    try
                    {
                        transientBody = await response.Content.ReadAsStringAsync(cancellationToken);
                    }
                    catch
                    {
                        // best-effort; never fail a retry on logging
                    }

                    _logger.LogWarning(
                        "Transient Varonis API response ({StatusCode}) on attempt {Attempt}/{MaxAttempts}; retrying in {Delay}. ResponseBody={ResponseBody}",
                        (int)response.StatusCode,
                        attempt,
                        maxAttempts,
                        delay,
                        Truncate(transientBody, ErrorBodyLogLimit));

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
        searchUrl = searchUrl.Trim();

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

        if (searchUrl.StartsWith("app/", StringComparison.OrdinalIgnoreCase))
        {
            return new Uri($"/{searchUrl}", UriKind.Relative);
        }

        if (searchUrl.StartsWith("dataquery/", StringComparison.OrdinalIgnoreCase))
        {
            return new Uri($"/app/{searchUrl}", UriKind.Relative);
        }

        var appDataQueryIndex = searchUrl.IndexOf("/app/dataquery/", StringComparison.OrdinalIgnoreCase);
        if (appDataQueryIndex >= 0)
        {
            return new Uri(searchUrl[appDataQueryIndex..], UriKind.Relative);
        }

        var dataQueryIndex = searchUrl.IndexOf("dataquery/api/search/", StringComparison.OrdinalIgnoreCase);
        if (dataQueryIndex >= 0)
        {
            return new Uri($"/app/{searchUrl[dataQueryIndex..]}", UriKind.Relative);
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
