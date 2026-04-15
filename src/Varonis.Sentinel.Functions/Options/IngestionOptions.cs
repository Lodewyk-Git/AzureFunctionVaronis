using System.ComponentModel.DataAnnotations;
using System.Text;

namespace Varonis.Sentinel.Functions.Options;

public sealed class IngestionOptions
{
    // TRANSITIONAL FALLBACKS (remove once all environments set their own Ingestion__* app settings).
    // Base64-encoded to keep tenant-specific Azure Monitor endpoints out of plain-text code search.
    // These are NOT secrets — anyone inspecting the release DLL can decode them. The obfuscation
    // reduces passive exposure (GitHub search, scrapers). Values encoded here are the TEST
    // environment's DCE/DCR; until prod app settings are populated via Portal (Path 1), a prod
    // Function App on this build will route ingestion to the TEST workspace.
    private const string EncodedDefaultEndpoint =
        "aHR0cHM6Ly92YXJvbmlzLXRlc3QtZGNlLWZjZXJxc3I0cWMzNmEtbGhiOC5lYXN0dXMtMS5pbmdlc3QubW9uaXRvci5henVyZS5jb20=";
    private const string EncodedDefaultDcrImmutableId =
        "ZGNyLWZiMjBkNjAwZGExMzQ0ODVhOTc3OTUxMDU3ZmFkYzMz";

    public static string DefaultEndpoint { get; } =
        Encoding.UTF8.GetString(Convert.FromBase64String(EncodedDefaultEndpoint));

    public static string DefaultDcrImmutableId { get; } =
        Encoding.UTF8.GetString(Convert.FromBase64String(EncodedDefaultDcrImmutableId));

    public const string DefaultStreamName = "Custom-VaronisAlerts_CL";

    [Required]
    [Url]
    public string Endpoint { get; set; } = DefaultEndpoint;

    [Required]
    public string DcrImmutableId { get; set; } = DefaultDcrImmutableId;

    [Required]
    public string StreamName { get; set; } = DefaultStreamName;

    [Range(1, 100000)]
    public int MaxRecordsPerUpload { get; init; } = 5000;

    // Azure Monitor Logs Ingestion API rejects payloads larger than 1 MB (uncompressed).
    // Default leaves ~100 KB of headroom for request framing.
    [Range(10_000, 1_000_000)]
    public int MaxPayloadBytes { get; init; } = 900_000;
}
