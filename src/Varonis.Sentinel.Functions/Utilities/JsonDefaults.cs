using System.Text.Json;

namespace Varonis.Sentinel.Functions.Utilities;

public static class JsonDefaults
{
    public static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true
    };
}
