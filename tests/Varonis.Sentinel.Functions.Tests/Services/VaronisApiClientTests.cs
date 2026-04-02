using Microsoft.Extensions.Logging;
using Moq;
using Varonis.Sentinel.Functions.Options;
using Varonis.Sentinel.Functions.Services;

namespace Varonis.Sentinel.Functions.Tests.Services;

public class VaronisApiClientTests
{
    private static VaronisApiClient CreateClient(string baseUrl = "https://tenant.varonis.net/")
    {
        var httpClient = new HttpClient { BaseAddress = new Uri(baseUrl) };
        var secretProvider = new Mock<ISecretProvider>();
        var logger = new Mock<ILogger<VaronisApiClient>>();
        var options = Microsoft.Extensions.Options.Options.Create(new VaronisOptions
        {
            BaseUrl = baseUrl,
            RetryCount = 0
        });

        return new VaronisApiClient(httpClient, secretProvider.Object, options, logger.Object);
    }

    [Fact]
    public void BuildSearchUri_AbsoluteUrlWithDifferentHost_Throws()
    {
        var sut = CreateClient("https://tenant.varonis.net/");

        var ex = Assert.Throws<InvalidOperationException>(() =>
            sut.BuildSearchUri("https://evil.example/collect-token"));

        Assert.Contains("does not match", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void BuildSearchUri_AbsoluteUrlWithSameHost_AllowsUri()
    {
        var sut = CreateClient("https://tenant.varonis.net/");

        var uri = sut.BuildSearchUri("https://tenant.varonis.net/api/search/abc");

        Assert.True(uri.IsAbsoluteUri);
        Assert.Equal("tenant.varonis.net", uri.Host);
    }

    [Fact]
    public void BuildSearchUri_BareToken_UsesExpectedSearchPath()
    {
        var sut = CreateClient();

        var uri = sut.BuildSearchUri("abc123");

        Assert.False(uri.IsAbsoluteUri);
        Assert.Equal("/app/dataquery/api/search/abc123", uri.OriginalString);
    }
}
