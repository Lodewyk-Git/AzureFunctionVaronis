using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Varonis.Sentinel.Functions.Models;

namespace Varonis.Sentinel.Functions.Utilities;

public static class VaronisAlertMapper
{
    public static IEnumerable<VaronisAlert> Map(VaronisSearchResponse response, string correlationId)
    {
        if (response.Columns.Count == 0 || response.Rows.Count == 0)
        {
            yield break;
        }

        foreach (var row in response.Rows)
        {
            var raw = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var maxIndex = Math.Min(response.Columns.Count, row.Count);
            for (var index = 0; index < maxIndex; index++)
            {
                raw[response.Columns[index]] = JsonElementToString(row[index]);
            }

            var alertTime = ParseDateTimeOffset(
                GetFirstValue(
                    raw,
                    "alertTimeUtc",
                    "timestamp",
                    "createdAt",
                    "eventTime",
                    "timeGenerated",
                    "Alert.TimeUTC",
                    "Alert.Initial.Event.TimeUTC",
                    "Alert.Time",
                    "Alert.Initial.Event.TimeLocal")) ?? DateTimeOffset.UtcNow;

            yield return new VaronisAlert
            {
                TimeGenerated = alertTime,
                AlertId = GetFirstValue(raw, "alertId", "id", "eventId", "Alert.ID") ?? GenerateDeterministicId(raw),
                AlertTimeUtc = alertTime,
                Severity = GetFirstValue(raw, "severity", "Alert.Rule.Severity.Name") ?? string.Empty,
                Status = GetFirstValue(raw, "status", "Alert.Status.Name") ?? string.Empty,
                ThreatDetectionPolicy = GetFirstValue(
                    raw,
                    "threatDetectionPolicy",
                    "threatPolicy",
                    "policyName",
                    "Alert.Rule.Name",
                    "Alert.Rule.Category.Name") ?? string.Empty,
                Description = GetFirstValue(
                    raw,
                    "description",
                    "message",
                    "title",
                    "name",
                    "Alert.Rule.Name",
                    "Alert.ActionType.Name") ?? string.Empty,
                Actor = GetFirstValue(
                    raw,
                    "actor",
                    "user",
                    "username",
                    "principal",
                    "Alert.User.Name",
                    "Alert.User.SamAccountName") ?? string.Empty,
                Asset = GetFirstValue(
                    raw,
                    "asset",
                    "resource",
                    "device",
                    "host",
                    "target",
                    "Alert.Asset.Path",
                    "Alert.Device.HostName",
                    "Alert.Filer.Name") ?? string.Empty,
                RawRecord = raw,
                IngestedAtUtc = DateTimeOffset.UtcNow,
                CorrelationId = correlationId
            };
        }
    }

    private static DateTimeOffset? ParseDateTimeOffset(string? value)
    {
        if (DateTimeOffset.TryParse(value, out var parsed))
        {
            return parsed;
        }

        return null;
    }

    private static string JsonElementToString(JsonElement value)
    {
        return value.ValueKind switch
        {
            JsonValueKind.Null => string.Empty,
            JsonValueKind.True => bool.TrueString,
            JsonValueKind.False => bool.FalseString,
            JsonValueKind.String => value.GetString() ?? string.Empty,
            _ => value.ToString()
        };
    }

    internal static string GenerateDeterministicId(IReadOnlyDictionary<string, string> raw)
    {
        var content = string.Join("|", raw
            .OrderBy(kv => kv.Key, StringComparer.OrdinalIgnoreCase)
            .Select(kv => $"{kv.Key}={kv.Value}"));
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(content));
        return Convert.ToHexString(hash)[..32].ToLowerInvariant();
    }

    private static string? GetFirstValue(IReadOnlyDictionary<string, string> values, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (values.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }

        return null;
    }
}
