namespace Varonis.Sentinel.Functions.Models;

public sealed class CheckpointState
{
    public DateTimeOffset LastSuccessfulCheckpointUtc { get; init; }
}
