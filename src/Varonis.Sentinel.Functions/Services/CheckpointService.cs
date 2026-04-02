using System.Text.Json;
using Azure.Storage.Blobs;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Varonis.Sentinel.Functions.Models;
using Varonis.Sentinel.Functions.Options;
using Varonis.Sentinel.Functions.Utilities;

namespace Varonis.Sentinel.Functions.Services;

public sealed class CheckpointService : ICheckpointService
{
    private readonly BlobContainerClient _containerClient;
    private readonly CheckpointOptions _options;
    private readonly ILogger<CheckpointService> _logger;

    public CheckpointService(
        BlobServiceClient blobServiceClient,
        IOptions<CheckpointOptions> options,
        ILogger<CheckpointService> logger)
    {
        _options = options.Value;
        _logger = logger;
        _containerClient = blobServiceClient.GetBlobContainerClient(_options.ContainerName);
    }

    public async Task<DateTimeOffset> GetLastCheckpointUtcAsync(CancellationToken cancellationToken = default)
    {
        await _containerClient.CreateIfNotExistsAsync(cancellationToken: cancellationToken);

        var blobClient = _containerClient.GetBlobClient(_options.BlobName);
        var exists = await blobClient.ExistsAsync(cancellationToken);
        if (!exists.Value)
        {
            var fallback = DateTimeOffset.UtcNow.Subtract(ParsingHelpers.ParseDuration(_options.InitialLookback, TimeSpan.FromDays(14)));
            _logger.LogInformation("Checkpoint blob was not found. Using fallback checkpoint {CheckpointUtc}.", fallback);
            return fallback;
        }

        var download = await blobClient.DownloadContentAsync(cancellationToken);
        var checkpoint = JsonSerializer.Deserialize<CheckpointState>(download.Value.Content, JsonDefaults.SerializerOptions);
        if (checkpoint is null)
        {
            throw new InvalidOperationException("Checkpoint blob exists but could not be deserialized.");
        }

        return checkpoint.LastSuccessfulCheckpointUtc;
    }

    public async Task SetLastCheckpointUtcAsync(DateTimeOffset checkpointUtc, CancellationToken cancellationToken = default)
    {
        await _containerClient.CreateIfNotExistsAsync(cancellationToken: cancellationToken);
        var blobClient = _containerClient.GetBlobClient(_options.BlobName);
        var state = new CheckpointState { LastSuccessfulCheckpointUtc = checkpointUtc };

        await blobClient.UploadAsync(BinaryData.FromObjectAsJson(state, JsonDefaults.SerializerOptions), overwrite: true, cancellationToken);
        _logger.LogInformation("Checkpoint updated to {CheckpointUtc}.", checkpointUtc);
    }
}
