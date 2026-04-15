namespace Varonis.Sentinel.Functions.Services;

public interface IVaronisTokenCache
{
    bool TryGet(out string token);

    void Set(string token, DateTimeOffset expiresUtc);

    SemaphoreSlim RefreshLock { get; }
}
