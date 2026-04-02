using System.Text.Json.Serialization;

namespace Varonis.Sentinel.Functions.Models;

public sealed class VaronisSearchRequest
{
    [JsonPropertyName("fromUtc")]
    public DateTimeOffset FromUtc { get; init; }

    [JsonPropertyName("toUtc")]
    public DateTimeOffset ToUtc { get; init; }

    [JsonPropertyName("severity")]
    public IReadOnlyList<string> Severity { get; init; } = Array.Empty<string>();

    [JsonPropertyName("status")]
    public IReadOnlyList<string> Status { get; init; } = Array.Empty<string>();

    [JsonPropertyName("threatDetectionPolicies")]
    public IReadOnlyList<string> ThreatDetectionPolicies { get; init; } = Array.Empty<string>();

    [JsonPropertyName("maxResults")]
    public int MaxResults { get; init; } = 1000;
}
