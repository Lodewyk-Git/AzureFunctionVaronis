using System.Text.Json;
using Azure.Storage.Blobs;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Varonis.Sentinel.Functions.Models;
using Varonis.Sentinel.Functions.Options;
using Varonis.Sentinel.Functions.Utilities;

namespace Varonis.Sentinel.Functions.Services;

public sealed class FailureStoreService : IFailureStoreService
{
    private readonly BlobContainerClient _containerClient;
    private readonly ILogger<FailureStoreService> _logger;
    private volatile bool _containerEnsured;

    public FailureStoreService(
        BlobServiceClient blobServiceClient,
        IOptions<FailureStoreOptions> options,
        ILogger<FailureStoreService> logger)
    {
        _containerClient = blobServiceClient.GetBlobContainerClient(options.Value.ContainerName);
        _logger = logger;
    }

    public async Task SaveFailedBatchAsync(
        IReadOnlyCollection<VaronisAlert> alerts,
        Exception exception,
        string correlationId,
        CancellationToken cancellationToken = default)
    {
        if (alerts.Count == 0)
        {
            return;
        }

        await EnsureContainerAsync(cancellationToken);

        var blobName = $"{DateTimeOffset.UtcNow:yyyy/MM/dd/HH/mm}/failed-{correlationId}.json";
        var blobClient = _containerClient.GetBlobClient(blobName);

        var payload = new
        {
            CorrelationId = correlationId,
            FailedAtUtc = DateTimeOffset.UtcNow,
            ErrorType = exception.GetType().Name,
            ErrorMessage = exception.Message,
            Alerts = alerts
        };

        await blobClient.UploadAsync(
            BinaryData.FromObjectAsJson(payload, JsonDefaults.SerializerOptions),
            overwrite: true,
            cancellationToken);

        _logger.LogError(exception, "Saved failed batch with {AlertCount} alerts to blob {BlobName}.", alerts.Count, blobName);
    }

    private async Task EnsureContainerAsync(CancellationToken cancellationToken)
    {
        if (_containerEnsured) return;
        await _containerClient.CreateIfNotExistsAsync(cancellationToken: cancellationToken);
        _containerEnsured = true;
    }
}
