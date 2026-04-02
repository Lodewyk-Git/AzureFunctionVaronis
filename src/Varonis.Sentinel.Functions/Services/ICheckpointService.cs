namespace Varonis.Sentinel.Functions.Services;

public interface ICheckpointService
{
    Task<DateTimeOffset> GetLastCheckpointUtcAsync(CancellationToken cancellationToken = default);

    Task SetLastCheckpointUtcAsync(DateTimeOffset checkpointUtc, CancellationToken cancellationToken = default);
}
