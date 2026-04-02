using System.Text.Json.Serialization;

namespace Varonis.Sentinel.Functions.Models;

public sealed class VaronisTokenResponse
{
    [JsonPropertyName("access_token")]
    public string AccessToken { get; init; } = string.Empty;

    [JsonPropertyName("token_type")]
    public string TokenType { get; init; } = string.Empty;
}
