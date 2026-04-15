using System.ComponentModel.DataAnnotations;
using System.Text;

namespace Varonis.Sentinel.Functions.Options;

public sealed class VaronisOptions
{
    // Tenant-default base URL, Base64-encoded to keep the raw hostname out of plain-text
    // code search and scraper scans. This is NOT a secret — the release zip is public and
    // anyone can decode it by reading this constant. The obfuscation exists only to reduce
    // passive exposure (GitHub search, bots indexing *.varonis.io). Override at deploy time
    // via -VaronisBaseUrl on Deploy-Solution.ps1.
    private const string EncodedDefaultBaseUrl = "aHR0cHM6Ly9vbWluc3VyZS52YXJvbmlzLmlv";

    public static string DefaultBaseUrl { get; } =
        Encoding.UTF8.GetString(Convert.FromBase64String(EncodedDefaultBaseUrl));

    [Required]
    [Url]
    public string BaseUrl { get; set; } = DefaultBaseUrl;

    public string ApiKey { get; init; } = string.Empty;

    public string ApiKeySecretName { get; init; } = "VaronisApiKey";

    public string SeverityCsv { get; init; } = "Low,Medium,High,Informational";

    public string StatusCsv { get; init; } = "New,Under Investigation";

    public string ThreatDetectionPoliciesCsv { get; init; } = string.Empty;

    [Range(1, 100000)]
    public int MaxAlertRetrieval { get; init; } = 1000;

    [Range(10, 600)]
    public int RequestTimeoutSeconds { get; init; } = 100;

    [Range(0, 10)]
    public int RetryCount { get; init; } = 3;

    [Range(1, 120)]
    public int RetryBaseDelaySeconds { get; init; } = 2;

    public string AuthPath { get; init; } = "/api/authentication/api_keys/token";

    public string SearchPath { get; init; } = "/app/dataquery/api/search/v2/search";
}
