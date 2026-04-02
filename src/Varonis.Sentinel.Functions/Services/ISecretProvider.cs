namespace Varonis.Sentinel.Functions.Services;

public interface ISecretProvider
{
    Task<string> GetVaronisApiKeyAsync(CancellationToken cancellationToken = default);
}
