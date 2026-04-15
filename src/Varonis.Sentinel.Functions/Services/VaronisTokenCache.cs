namespace Varonis.Sentinel.Functions.Services;

/// <summary>
/// Singleton-scoped access token cache so token lifetime survives across transient
/// <see cref="VaronisApiClient"/> instances created by the HTTP client factory.
/// </summary>
public sealed class VaronisTokenCache : IVaronisTokenCache
{
    private readonly object _gate = new();
    private string? _token;
    private DateTimeOffset _expiresUtc = DateTimeOffset.MinValue;

    public SemaphoreSlim RefreshLock { get; } = new(1, 1);

    public bool TryGet(out string token)
    {
        lock (_gate)
        {
            if (!string.IsNullOrWhiteSpace(_token) && DateTimeOffset.UtcNow < _expiresUtc)
            {
                token = _token!;
                return true;
            }
        }

        token = string.Empty;
        return false;
    }

    public void Set(string token, DateTimeOffset expiresUtc)
    {
        lock (_gate)
        {
            _token = token;
            _expiresUtc = expiresUtc;
        }
    }
}
