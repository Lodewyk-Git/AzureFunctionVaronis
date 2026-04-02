using Varonis.Sentinel.Functions.Models;

namespace Varonis.Sentinel.Functions.Services;

public interface ILogIngestionService
{
    Task UploadAlertsAsync(IReadOnlyCollection<VaronisAlert> alerts, CancellationToken cancellationToken = default);
}
