using System.ComponentModel.DataAnnotations;

namespace Varonis.Sentinel.Functions.Options;

public sealed class FailureStoreOptions
{
    [Required]
    public string ContainerName { get; init; } = "varonis-failures";
}
