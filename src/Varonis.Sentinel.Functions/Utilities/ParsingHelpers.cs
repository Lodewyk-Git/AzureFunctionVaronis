namespace Varonis.Sentinel.Functions.Utilities;

public static class ParsingHelpers
{
    public static IReadOnlyList<string> SplitCsv(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return Array.Empty<string>();
        }

        return value
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public static TimeSpan ParseDuration(string value, TimeSpan fallback)
    {
        return TimeSpan.TryParse(value, out var parsed) ? parsed : fallback;
    }
}
