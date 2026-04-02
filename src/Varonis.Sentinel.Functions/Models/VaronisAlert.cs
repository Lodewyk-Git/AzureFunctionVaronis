using System.Text.Json.Serialization;

namespace Varonis.Sentinel.Functions.Models;

public sealed class VaronisAlert
{
    [JsonPropertyName("TimeGenerated")]
    public DateTimeOffset TimeGenerated { get; init; }

    [JsonPropertyName("AlertId")]
    public string AlertId { get; init; } = string.Empty;

    [JsonPropertyName("AlertTimeUtc")]
    public DateTimeOffset AlertTimeUtc { get; init; }

    [JsonPropertyName("Severity")]
    public string Severity { get; init; } = string.Empty;

    [JsonPropertyName("Status")]
    public string Status { get; init; } = string.Empty;

    [JsonPropertyName("ThreatDetectionPolicy")]
    public string ThreatDetectionPolicy { get; init; } = string.Empty;

    [JsonPropertyName("Description")]
    public string Description { get; init; } = string.Empty;

    [JsonPropertyName("Actor")]
    public string Actor { get; init; } = string.Empty;

    [JsonPropertyName("Asset")]
    public string Asset { get; init; } = string.Empty;

    [JsonPropertyName("SourceSystem")]
    public string SourceSystem { get; init; } = "Varonis";

    [JsonPropertyName("RawRecord")]
    public IReadOnlyDictionary<string, string> RawRecord { get; init; } = new Dictionary<string, string>();

    [JsonPropertyName("IngestedAtUtc")]
    public DateTimeOffset IngestedAtUtc { get; init; }

    [JsonPropertyName("CorrelationId")]
    public string CorrelationId { get; init; } = string.Empty;
}
