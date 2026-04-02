using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Varonis.Sentinel.Functions.Models;
using Varonis.Sentinel.Functions.Options;
using Varonis.Sentinel.Functions.Services;
using Varonis.Sentinel.Functions.Utilities;

namespace Varonis.Sentinel.Functions.Functions;

public sealed class VaronisAlertTimerFunction
{
    private readonly IVaronisApiClient _varonisApiClient;
    private readonly ICheckpointService _checkpointService;
    private readonly ILogIngestionService _logIngestionService;
    private readonly IFailureStoreService _failureStoreService;
    private readonly VaronisOptions _varonisOptions;
    private readonly ILogger<VaronisAlertTimerFunction> _logger;

    public VaronisAlertTimerFunction(
        IVaronisApiClient varonisApiClient,
        ICheckpointService checkpointService,
        ILogIngestionService logIngestionService,
        IFailureStoreService failureStoreService,
        IOptions<VaronisOptions> varonisOptions,
        ILogger<VaronisAlertTimerFunction> logger)
    {
        _varonisApiClient = varonisApiClient;
        _checkpointService = checkpointService;
        _logIngestionService = logIngestionService;
        _failureStoreService = failureStoreService;
        _varonisOptions = varonisOptions.Value;
        _logger = logger;
    }

    [Function("VaronisAlertTimerFunction")]
    public async Task Run([TimerTrigger("%TimerSchedule%")] TimerInfo timerInfo, FunctionContext functionContext, CancellationToken cancellationToken)
    {
        var correlationId = functionContext.InvocationId;
        var runStartedUtc = DateTimeOffset.UtcNow;
        var alerts = new List<VaronisAlert>();

        try
        {
            var checkpointUtc = await _checkpointService.GetLastCheckpointUtcAsync(cancellationToken);
            _logger.LogInformation(
                "Starting Varonis ingestion run. CorrelationId={CorrelationId}, LastCheckpointUtc={CheckpointUtc}, ScheduleStatus={ScheduleStatus}.",
                correlationId,
                checkpointUtc,
                timerInfo.ScheduleStatus?.Last);

            var searchRequest = BuildSearchRequest(checkpointUtc, runStartedUtc);
            var accessToken = await _varonisApiClient.GetAccessTokenAsync(cancellationToken);

            alerts = await RetrieveAlertsAsync(accessToken, searchRequest, correlationId, cancellationToken);
            if (alerts.Count > 0)
            {
                await _logIngestionService.UploadAlertsAsync(alerts, cancellationToken);
            }

            await _checkpointService.SetLastCheckpointUtcAsync(runStartedUtc, cancellationToken);
            _logger.LogInformation(
                "Completed Varonis ingestion run. CorrelationId={CorrelationId}, AlertCount={AlertCount}.",
                correlationId,
                alerts.Count);
        }
        catch (Exception ex)
        {
            try
            {
                await _failureStoreService.SaveFailedBatchAsync(alerts, ex, correlationId, CancellationToken.None);
            }
            catch (Exception storeEx)
            {
                _logger.LogError(storeEx, "Failed to persist failure batch to blob storage. CorrelationId={CorrelationId}.", correlationId);
            }

            _logger.LogError(ex, "Varonis ingestion run failed. CorrelationId={CorrelationId}.", correlationId);
            throw;
        }
    }

    private async Task<List<VaronisAlert>> RetrieveAlertsAsync(
        string accessToken,
        VaronisSearchRequest searchRequest,
        string correlationId,
        CancellationToken cancellationToken)
    {
        var allAlerts = new List<VaronisAlert>();
        var page = await _varonisApiClient.SearchAlertsAsync(accessToken, searchRequest, cancellationToken);
        AddMappedAlerts(page, allAlerts, correlationId, searchRequest.MaxResults);

        var nextSearchUrl = ResolveNextSearchUrl(page);
        var safetyPageLimit = 500;
        var pagesRead = 0;

        while (!string.IsNullOrWhiteSpace(nextSearchUrl) &&
               allAlerts.Count < searchRequest.MaxResults &&
               pagesRead < safetyPageLimit)
        {
            page = await _varonisApiClient.GetSearchResultsAsync(accessToken, nextSearchUrl, cancellationToken);
            AddMappedAlerts(page, allAlerts, correlationId, searchRequest.MaxResults);
            nextSearchUrl = ResolveNextSearchUrl(page);
            pagesRead++;
        }

        return allAlerts
            .GroupBy(item => $"{item.AlertId}|{item.AlertTimeUtc:O}", StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First())
            .ToList();
    }

    private static string? ResolveNextSearchUrl(VaronisSearchResponse response)
    {
        if (!string.IsNullOrWhiteSpace(response.NextSearchUrl))
        {
            return response.NextSearchUrl;
        }

        if (response.HasMore && !string.IsNullOrWhiteSpace(response.SearchUrl))
        {
            return response.SearchUrl;
        }

        return null;
    }

    private static void AddMappedAlerts(
        VaronisSearchResponse response,
        List<VaronisAlert> destination,
        string correlationId,
        int maxAlerts)
    {
        foreach (var alert in VaronisAlertMapper.Map(response, correlationId))
        {
            destination.Add(alert);
            if (destination.Count >= maxAlerts)
            {
                return;
            }
        }
    }

    private VaronisSearchRequest BuildSearchRequest(DateTimeOffset fromUtc, DateTimeOffset toUtc)
    {
        return new VaronisSearchRequest
        {
            FromUtc = fromUtc,
            ToUtc = toUtc,
            Severity = ParsingHelpers.SplitCsv(_varonisOptions.SeverityCsv),
            Status = ParsingHelpers.SplitCsv(_varonisOptions.StatusCsv),
            ThreatDetectionPolicies = ParsingHelpers.SplitCsv(_varonisOptions.ThreatDetectionPoliciesCsv),
            MaxResults = _varonisOptions.MaxAlertRetrieval
        };
    }

}
