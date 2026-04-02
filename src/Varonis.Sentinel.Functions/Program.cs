using Azure.Identity;
using Azure.Monitor.Ingestion;
using Azure.Storage.Blobs;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;
using Varonis.Sentinel.Functions.Options;
using Varonis.Sentinel.Functions.Services;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureServices((context, services) =>
    {
        var configuration = context.Configuration;

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

        var webJobsStorage = configuration["AzureWebJobsStorage"];
        if (string.IsNullOrWhiteSpace(webJobsStorage))
        {
            throw new InvalidOperationException("Configuration value 'AzureWebJobsStorage' is required.");
        }

        services.AddSingleton(new BlobServiceClient(webJobsStorage));

        services.AddSingleton(provider =>
        {
            var ingestionOptions = provider.GetRequiredService<IOptions<IngestionOptions>>().Value;
            return new LogsIngestionClient(new Uri(ingestionOptions.Endpoint), new DefaultAzureCredential());
        });

        services.AddHttpClient<IVaronisApiClient, VaronisApiClient>((provider, client) =>
        {
            var varonisOptions = provider.GetRequiredService<IOptions<VaronisOptions>>().Value;
            client.BaseAddress = new Uri(varonisOptions.BaseUrl.TrimEnd('/') + "/");
            client.Timeout = TimeSpan.FromSeconds(varonisOptions.RequestTimeoutSeconds);
        });

        services.AddSingleton<ISecretProvider, SecretProvider>();
        services.AddSingleton<ICheckpointService, CheckpointService>();
        services.AddSingleton<IFailureStoreService, FailureStoreService>();
        services.AddSingleton<ILogIngestionService, LogIngestionService>();
    })
    .Build();

await host.RunAsync();
