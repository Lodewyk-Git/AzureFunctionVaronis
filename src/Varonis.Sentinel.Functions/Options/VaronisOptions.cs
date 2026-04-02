using System.ComponentModel.DataAnnotations;

namespace Varonis.Sentinel.Functions.Options;

public sealed class VaronisOptions
{
    [Required]
    [Url]
    public string BaseUrl { get; init; } = string.Empty;

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
