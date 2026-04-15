using System.Net;
using System.Reflection;
using System.Text.Json;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Varonis.Sentinel.Functions.Options;
using Varonis.Sentinel.Functions.Utilities;

namespace Varonis.Sentinel.Functions.Functions;

/// <summary>
/// Lightweight liveness probe. Returns 200 when the worker process is alive and its
/// dependency bindings are resolvable. Intentionally does not call Varonis or ingest
/// into Log Analytics — those are covered by Validate-Deployment.ps1 and Sentinel-side alerts.
/// </summary>
public sealed class HealthCheckFunction
{
    private static readonly string AssemblyVersion =
        typeof(HealthCheckFunction).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
        ?? typeof(HealthCheckFunction).Assembly.GetName().Version?.ToString()
        ?? "unknown";

    private readonly IngestionOptions _ingestionOptions;
    private readonly VaronisOptions _varonisOptions;
    private readonly ILogger<HealthCheckFunction> _logger;

    public HealthCheckFunction(
        IOptions<IngestionOptions> ingestionOptions,
        IOptions<VaronisOptions> varonisOptions,
        ILogger<HealthCheckFunction> logger)
    {
        _ingestionOptions = ingestionOptions.Value;
        _varonisOptions = varonisOptions.Value;
        _logger = logger;
    }

    [Function("HealthCheck")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "health")] HttpRequestData request,
        CancellationToken cancellationToken)
    {
        var body = new
        {
            status = "ok",
            version = AssemblyVersion,
            utc = DateTimeOffset.UtcNow.ToString("O"),
            dependencies = new
            {
                varonisBaseUrlConfigured = !string.IsNullOrWhiteSpace(_varonisOptions.BaseUrl),
                ingestionEndpointConfigured = !string.IsNullOrWhiteSpace(_ingestionOptions.Endpoint),
                dcrImmutableIdConfigured = !string.IsNullOrWhiteSpace(_ingestionOptions.DcrImmutableId),
                streamConfigured = !string.IsNullOrWhiteSpace(_ingestionOptions.StreamName)
            }
        };

        var response = request.CreateResponse(HttpStatusCode.OK);
        response.Headers.Add("Content-Type", "application/json; charset=utf-8");
        response.Headers.Add("Cache-Control", "no-store");
        await response.WriteStringAsync(JsonSerializer.Serialize(body, JsonDefaults.SerializerOptions), cancellationToken);
        _logger.LogDebug("HealthCheck probe served. Version={Version}.", AssemblyVersion);
        return response;
    }
}
