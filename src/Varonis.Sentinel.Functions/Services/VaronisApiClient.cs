using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Varonis.Sentinel.Functions.Models;
using Varonis.Sentinel.Functions.Options;
using Varonis.Sentinel.Functions.Utilities;

namespace Varonis.Sentinel.Functions.Services;

public sealed class VaronisApiClient : IVaronisApiClient
{
    private static readonly HashSet<HttpStatusCode> TransientStatusCodes =
    [
        HttpStatusCode.RequestTimeout,
        HttpStatusCode.TooManyRequests,
        HttpStatusCode.BadGateway,
        HttpStatusCode.ServiceUnavailable,
        HttpStatusCode.GatewayTimeout
    ];

    private readonly HttpClient _httpClient;
    private readonly ISecretProvider _secretProvider;
    private readonly VaronisOptions _options;
    private readonly ILogger<VaronisApiClient> _logger;

    public VaronisApiClient(
        HttpClient httpClient,
        ISecretProvider secretProvider,
        IOptions<VaronisOptions> options,
        ILogger<VaronisApiClient> logger)
    {
        _httpClient = httpClient;
        _secretProvider = secretProvider;
        _options = options.Value;
        _logger = logger;
    }

    public async Task<string> GetAccessTokenAsync(CancellationToken cancellationToken = default)
    {
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

        return tokenResponse.AccessToken;
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

        response.EnsureSuccessStatusCode();
        var payload = await response.Content.ReadFromJsonAsync<VaronisSearchResponse>(JsonDefaults.SerializerOptions, cancellationToken);
        return payload ?? new VaronisSearchResponse();
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
}
