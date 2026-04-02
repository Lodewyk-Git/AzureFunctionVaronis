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
}
