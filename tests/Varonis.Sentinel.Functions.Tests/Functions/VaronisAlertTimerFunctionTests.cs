using System.Text.Json;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Moq;
using Varonis.Sentinel.Functions.Functions;
using Varonis.Sentinel.Functions.Models;
using Varonis.Sentinel.Functions.Options;
using Varonis.Sentinel.Functions.Services;

namespace Varonis.Sentinel.Functions.Tests.Functions;

public class VaronisAlertTimerFunctionTests
{
    private readonly Mock<IVaronisApiClient> _apiClient = new();
    private readonly Mock<ICheckpointService> _checkpoint = new();
    private readonly Mock<ILogIngestionService> _ingestion = new();
    private readonly Mock<IFailureStoreService> _failureStore = new();
    private readonly Mock<ILogger<VaronisAlertTimerFunction>> _logger = new();

    private VaronisAlertTimerFunction CreateSut()
    {
        var options = Microsoft.Extensions.Options.Options.Create(new VaronisOptions
        {
            BaseUrl = "https://tenant.varonis.net",
            SeverityCsv = "High",
            StatusCsv = "New",
            MaxAlertRetrieval = 1000
        });

        return new VaronisAlertTimerFunction(
            _apiClient.Object,
            _checkpoint.Object,
            _ingestion.Object,
            _failureStore.Object,
            options,
            _logger.Object);
    }

    private static FunctionContext CreateContext()
    {
        var context = new Mock<FunctionContext>();
        context.Setup(c => c.InvocationId).Returns("inv-1");
        return context.Object;
    }

    private static JsonElement ToElement(string value) => JsonSerializer.SerializeToElement(value);

    [Fact]
    public async Task Run_NoAlerts_DoesNotUpload()
    {
        _checkpoint.Setup(x => x.GetLastCheckpointUtcAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(DateTimeOffset.UtcNow.AddMinutes(-30));

        _apiClient.Setup(x => x.GetAccessTokenAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync("token");

        _apiClient.Setup(x => x.SearchAlertsAsync(
                It.IsAny<string>(),
                It.IsAny<VaronisSearchRequest>(),
                It.IsAny<CancellationToken>()))
            .ReturnsAsync(new VaronisSearchResponse());

        var sut = CreateSut();
        await sut.Run(new TimerInfo(), CreateContext(), CancellationToken.None);

        _ingestion.Verify(x => x.UploadAlertsAsync(It.IsAny<IReadOnlyCollection<VaronisAlert>>(), It.IsAny<CancellationToken>()), Times.Never);
        _checkpoint.Verify(x => x.SetLastCheckpointUtcAsync(It.IsAny<DateTimeOffset>(), It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task Run_WhenFailureStoreAlsoFails_RethrowsOriginalException()
    {
        _checkpoint.Setup(x => x.GetLastCheckpointUtcAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(DateTimeOffset.UtcNow.AddMinutes(-30));

        _apiClient.Setup(x => x.GetAccessTokenAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync("token");

        _apiClient.Setup(x => x.SearchAlertsAsync(
                It.IsAny<string>(),
                It.IsAny<VaronisSearchRequest>(),
                It.IsAny<CancellationToken>()))
            .ReturnsAsync(new VaronisSearchResponse
            {
                Columns = new List<string> { "alertId" },
                Rows = new List<List<JsonElement>>
                {
                    new() { ToElement("a1") }
                }
            });

        var original = new InvalidOperationException("upload failed");
        _ingestion.Setup(x => x.UploadAlertsAsync(It.IsAny<IReadOnlyCollection<VaronisAlert>>(), It.IsAny<CancellationToken>()))
            .ThrowsAsync(original);

        _failureStore.Setup(x => x.SaveFailedBatchAsync(
                It.IsAny<IReadOnlyCollection<VaronisAlert>>(),
                It.IsAny<Exception>(),
                It.IsAny<string>(),
                It.IsAny<CancellationToken>()))
            .ThrowsAsync(new IOException("blob unavailable"));

        var sut = CreateSut();
        var ex = await Assert.ThrowsAsync<InvalidOperationException>(() => sut.Run(new TimerInfo(), CreateContext(), CancellationToken.None));

        Assert.Same(original, ex);
        _failureStore.Verify(x => x.SaveFailedBatchAsync(
            It.IsAny<IReadOnlyCollection<VaronisAlert>>(),
            original,
            It.IsAny<string>(),
            CancellationToken.None), Times.Once);
        _checkpoint.Verify(x => x.SetLastCheckpointUtcAsync(It.IsAny<DateTimeOffset>(), It.IsAny<CancellationToken>()), Times.Never);
    }
}
