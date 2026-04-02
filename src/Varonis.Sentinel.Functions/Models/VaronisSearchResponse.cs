using System.Text.Json;
using System.Text.Json.Serialization;

namespace Varonis.Sentinel.Functions.Models;

public sealed class VaronisSearchResponse
{
    [JsonPropertyName("searchUrl")]
    public string? SearchUrl { get; init; }

    [JsonPropertyName("nextSearchUrl")]
    public string? NextSearchUrl { get; init; }

    [JsonPropertyName("hasMore")]
    public bool HasMore { get; init; }

    [JsonPropertyName("columns")]
    public List<string> Columns { get; init; } = new();

    [JsonPropertyName("rows")]
    public List<List<JsonElement>> Rows { get; init; } = new();
}
