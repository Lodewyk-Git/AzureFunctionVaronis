using Varonis.Sentinel.Functions.Models;

namespace Varonis.Sentinel.Functions.Services;

public interface IVaronisApiClient
{
    Task<string> GetAccessTokenAsync(CancellationToken cancellationToken = default);

    Task<VaronisSearchResponse> SearchAlertsAsync(
        string accessToken,
        VaronisSearchRequest request,
        CancellationToken cancellationToken = default);

    Task<VaronisSearchResponse> GetSearchResultsAsync(
        string accessToken,
        string searchUrl,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Best-effort POST to the Varonis async-search terminate URL after pagination completes,
    /// so the search does not idle on the server side until natural expiry. Failures are logged
    /// but never propagated - terminate is housekeeping, not part of the ingestion contract.
    /// </summary>
    Task TryTerminateSearchAsync(
        string accessToken,
        string terminateUrl,
        CancellationToken cancellationToken = default);
}
