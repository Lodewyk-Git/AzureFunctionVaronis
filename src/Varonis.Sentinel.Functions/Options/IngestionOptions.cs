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
}
