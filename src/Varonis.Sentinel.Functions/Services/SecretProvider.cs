using Azure.Identity;
using Azure.Security.KeyVault.Secrets;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Varonis.Sentinel.Functions.Options;

namespace Varonis.Sentinel.Functions.Services;

public sealed class SecretProvider : ISecretProvider
{
    private readonly VaronisOptions _varonisOptions;
    private readonly KeyVaultOptions _keyVaultOptions;
    private readonly ILogger<SecretProvider> _logger;
    private readonly SemaphoreSlim _cacheLock = new(1, 1);
    private SecretClient? _secretClient;
    private string? _cachedApiKey;
    private DateTimeOffset _cacheExpiresUtc = DateTimeOffset.MinValue;

    public SecretProvider(
        IOptions<VaronisOptions> varonisOptions,
        IOptions<KeyVaultOptions> keyVaultOptions,
        ILogger<SecretProvider> logger)
    {
        _varonisOptions = varonisOptions.Value;
        _keyVaultOptions = keyVaultOptions.Value;
        _logger = logger;
    }

    public async Task<string> GetVaronisApiKeyAsync(CancellationToken cancellationToken = default)
    {
        if (!string.IsNullOrWhiteSpace(_varonisOptions.ApiKey))
        {
            return _varonisOptions.ApiKey;
        }

        await _cacheLock.WaitAsync(cancellationToken);
        try
        {
            if (!string.IsNullOrWhiteSpace(_cachedApiKey) && DateTimeOffset.UtcNow < _cacheExpiresUtc)
            {
                return _cachedApiKey;
            }

            if (string.IsNullOrWhiteSpace(_keyVaultOptions.VaultUri))
            {
                throw new InvalidOperationException(
                    "Varonis API key is not configured. Set either Varonis__ApiKey or KeyVault__VaultUri with Varonis__ApiKeySecretName.");
            }

            _secretClient ??= new SecretClient(new Uri(_keyVaultOptions.VaultUri), new DefaultAzureCredential());

            var secretResponse = await _secretClient.GetSecretAsync(_varonisOptions.ApiKeySecretName, cancellationToken: cancellationToken);
            var secretValue = secretResponse.Value.Value;
            if (string.IsNullOrWhiteSpace(secretValue))
            {
                throw new InvalidOperationException($"Secret '{_varonisOptions.ApiKeySecretName}' in Key Vault is empty.");
            }

            _cachedApiKey = secretValue;
            _cacheExpiresUtc = DateTimeOffset.UtcNow.AddMinutes(15);
            _logger.LogInformation("Loaded Varonis API key from Key Vault secret {SecretName}.", _varonisOptions.ApiKeySecretName);

            return _cachedApiKey;
        }
        finally
        {
            _cacheLock.Release();
        }
    }
}
