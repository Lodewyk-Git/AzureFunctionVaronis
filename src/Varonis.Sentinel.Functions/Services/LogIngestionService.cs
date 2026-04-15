using System.Text.Json;
using Azure.Monitor.Ingestion;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Varonis.Sentinel.Functions.Models;
using Varonis.Sentinel.Functions.Options;
using Varonis.Sentinel.Functions.Utilities;

namespace Varonis.Sentinel.Functions.Services;

public sealed class LogIngestionService : ILogIngestionService
{
    // Per-record JSON separator (comma) plus enclosing brackets ("[","]").
    private const int JsonArrayFramingBytes = 2;
    private const int JsonRecordSeparatorBytes = 1;

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

        var maxRecords = _ingestionOptions.MaxRecordsPerUpload;
        var maxBytes = _ingestionOptions.MaxPayloadBytes;

        var current = new List<VaronisAlert>();
        var currentBytes = JsonArrayFramingBytes;

        foreach (var alert in alerts)
        {
            var recordBytes = JsonSerializer.SerializeToUtf8Bytes(alert, JsonDefaults.SerializerOptions).Length;
            var addedBytes = recordBytes + (current.Count == 0 ? 0 : JsonRecordSeparatorBytes);

            if (recordBytes + JsonArrayFramingBytes > maxBytes)
            {
                // Oversized single record: upload in isolation so the run doesn't stall,
                // but surface a warning because this will almost certainly be rejected with 413.
                _logger.LogWarning(
                    "Single Varonis alert record size {RecordBytes} exceeds MaxPayloadBytes {MaxPayloadBytes}. Attempting isolated upload; expect ingestion rejection.",
                    recordBytes,
                    maxBytes);

                if (current.Count > 0)
                {
                    await FlushAsync(current, cancellationToken);
                    current.Clear();
                    currentBytes = JsonArrayFramingBytes;
                }

                await FlushAsync(new[] { alert }, cancellationToken);
                continue;
            }

            if (current.Count >= maxRecords ||
                (current.Count > 0 && currentBytes + addedBytes > maxBytes))
            {
                await FlushAsync(current, cancellationToken);
                current.Clear();
                currentBytes = JsonArrayFramingBytes;
                addedBytes = recordBytes; // first record in new batch has no separator
            }

            current.Add(alert);
            currentBytes += addedBytes;
        }

        if (current.Count > 0)
        {
            await FlushAsync(current, cancellationToken);
        }
    }

    private async Task FlushAsync(IReadOnlyCollection<VaronisAlert> batch, CancellationToken cancellationToken)
    {
        await _logsIngestionClient.UploadAsync(
            _ingestionOptions.DcrImmutableId,
            _ingestionOptions.StreamName,
            batch,
            cancellationToken: cancellationToken);

        _logger.LogInformation(
            "Uploaded batch with {BatchCount} Varonis alert records to stream {StreamName}.",
            batch.Count,
            _ingestionOptions.StreamName);
    }
}
