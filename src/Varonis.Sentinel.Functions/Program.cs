using Azure.Core;
using Azure.Identity;
using Azure.Monitor.Ingestion;
using Azure.Storage.Blobs;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Varonis.Sentinel.Functions.Options;
using Varonis.Sentinel.Functions.Services;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureServices((context, services) =>
    {
        var configuration = context.Configuration;

        // Route worker ILogger output to Application Insights via the standard WorkerService AI pipeline.
        // Connection string is supplied through APPLICATIONINSIGHTS_CONNECTION_STRING (see infra/modules/core.bicep).
        // The AI log provider installs its own filter that defaults to Warning; lift it to Information
        // so our structured ingestion traces reach App Insights.
        services.AddApplicationInsightsTelemetryWorkerService();
        services.Configure<LoggerFilterOptions>(options =>
        {
            var toRemove = options.Rules.FirstOrDefault(rule =>
                rule.ProviderName == "Microsoft.Extensions.Logging.ApplicationInsights.ApplicationInsightsLoggerProvider");
            if (toRemove is not null)
            {
                options.Rules.Remove(toRemove);
            }
        });

        services
            .AddOptions<VaronisOptions>()
            .Bind(configuration.GetSection("Varonis"))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services
            .AddOptions<IngestionOptions>()
            .Bind(configuration.GetSection("Ingestion"))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services
            .AddOptions<CheckpointOptions>()
            .Bind(configuration.GetSection("Checkpoint"))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services
            .AddOptions<FailureStoreOptions>()
            .Bind(configuration.GetSection("FailureStore"))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services
            .AddOptions<KeyVaultOptions>()
            .Bind(configuration.GetSection("KeyVault"))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        var storageAccountName = configuration["AzureWebJobsStorage__accountName"];
        if (!string.IsNullOrWhiteSpace(storageAccountName))
        {
            services.AddSingleton(new BlobServiceClient(
                new Uri($"https://{storageAccountName}.blob.core.windows.net"),
                new DefaultAzureCredential()));
        }
        else
        {
            var webJobsStorage = configuration["AzureWebJobsStorage"];
            if (string.IsNullOrWhiteSpace(webJobsStorage))
            {
                throw new InvalidOperationException(
                    "Configure either 'AzureWebJobsStorage__accountName' (managed identity) or 'AzureWebJobsStorage' (connection string).");
            }

            services.AddSingleton(new BlobServiceClient(webJobsStorage));
        }

        services.AddSingleton(provider =>
        {
            var ingestionOptions = provider.GetRequiredService<IOptions<IngestionOptions>>().Value;
            return new LogsIngestionClient(
                new Uri(ingestionOptions.Endpoint),
                new DefaultAzureCredential(),
                new LogsIngestionClientOptions
                {
                    Retry =
                    {
                        MaxRetries = 3,
                        Delay = TimeSpan.FromSeconds(2),
                        Mode = RetryMode.Exponential,
                        MaxDelay = TimeSpan.FromSeconds(30)
                    }
                });
        });

        services.AddHttpClient<IVaronisApiClient, VaronisApiClient>((provider, client) =>
        {
            var varonisOptions = provider.GetRequiredService<IOptions<VaronisOptions>>().Value;
            client.BaseAddress = new Uri(varonisOptions.BaseUrl.TrimEnd('/') + "/");
            client.Timeout = TimeSpan.FromSeconds(varonisOptions.RequestTimeoutSeconds);
        });

        services.AddSingleton<ISecretProvider, SecretProvider>();
        services.AddSingleton<IVaronisTokenCache, VaronisTokenCache>();
        services.AddSingleton<ICheckpointService, CheckpointService>();
        services.AddSingleton<IFailureStoreService, FailureStoreService>();
        services.AddSingleton<ILogIngestionService, LogIngestionService>();
    })
    .Build();

await host.RunAsync();
