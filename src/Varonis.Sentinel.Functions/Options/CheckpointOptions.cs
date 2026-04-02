using System.ComponentModel.DataAnnotations;

namespace Varonis.Sentinel.Functions.Options;

public sealed class CheckpointOptions
{
    [Required]
    public string ContainerName { get; init; } = "varonis-checkpoints";

    [Required]
    public string BlobName { get; init; } = "varonis-alerts-checkpoint.json";

    [Required]
    public string InitialLookback { get; init; } = "14.00:00:00";
}
