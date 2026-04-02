using Varonis.Sentinel.Functions.Models;

namespace Varonis.Sentinel.Functions.Services;

public interface IFailureStoreService
{
    Task SaveFailedBatchAsync(
        IReadOnlyCollection<VaronisAlert> alerts,
        Exception exception,
        string correlationId,
        CancellationToken cancellationToken = default);
}
