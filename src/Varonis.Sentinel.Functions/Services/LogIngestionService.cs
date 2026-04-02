using Azure.Monitor.Ingestion;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Varonis.Sentinel.Functions.Models;
using Varonis.Sentinel.Functions.Options;

namespace Varonis.Sentinel.Functions.Services;

public sealed class LogIngestionService : ILogIngestionService
{
    private readonly LogsIngestionClient _logsIngestionClient;
    private readonly IngestionOptions _ingestionOptions;
    private readonly ILogger<LogIngestionService> _logger;

    public LogIngestionService(
        LogsIngestionClient logsIngestionClient,
        IOptions<IngestionOptions> ingestionOptions,
        ILogger<LogIngestionService> logger)
    {
        _logsIngestionClient = logsIngestionClient;
        _ingestionOptions = ingestionOptions.Value;
        _logger = logger;
    }

    public async Task UploadAlertsAsync(IReadOnlyCollection<VaronisAlert> alerts, CancellationToken cancellationToken = default)
    {
        if (alerts.Count == 0)
        {
            return;
        }

        foreach (var batch in alerts.Chunk(_ingestionOptions.MaxRecordsPerUpload))
        {
            await _logsIngestionClient.UploadAsync(
                _ingestionOptions.DcrImmutableId,
                _ingestionOptions.StreamName,
                batch,
                cancellationToken: cancellationToken);

            _logger.LogInformation(
                "Uploaded batch with {BatchCount} Varonis alert records to stream {StreamName}.",
                batch.Length,
                _ingestionOptions.StreamName);
        }
    }
}
