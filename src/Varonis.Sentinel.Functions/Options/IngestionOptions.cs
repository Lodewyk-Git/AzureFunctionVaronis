using System.ComponentModel.DataAnnotations;

namespace Varonis.Sentinel.Functions.Options;

public sealed class IngestionOptions
{
    [Required]
    [Url]
    public string Endpoint { get; init; } = string.Empty;

    [Required]
    public string DcrImmutableId { get; init; } = string.Empty;

    [Required]
    public string StreamName { get; init; } = "Custom-VaronisAlerts_CL";

    [Range(1, 100000)]
    public int MaxRecordsPerUpload { get; init; } = 5000;

    // Azure Monitor Logs Ingestion API rejects payloads larger than 1 MB (uncompressed).
    // Default leaves ~100 KB of headroom for request framing.
    [Range(10_000, 1_000_000)]
    public int MaxPayloadBytes { get; init; } = 900_000;
}
