[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [string[]]$ExpectedFunctionNames = @("HealthCheck", "VaronisAlertTimerFunction")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $PackagePath)) {
    throw "Package file not found: $PackagePath"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

$zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
try {
    $entries = @($zip.Entries)
    $entryNames = $entries | ForEach-Object { $_.FullName }

    $hasAzureFunctionsFolder = $false
    foreach ($name in $entryNames) {
        if ($name.StartsWith(".azurefunctions/", [StringComparison]::OrdinalIgnoreCase) -or
            $name.Equals(".azurefunctions", [StringComparison]::OrdinalIgnoreCase)) {
            $hasAzureFunctionsFolder = $true
            break
        }
    }

    if (-not $hasAzureFunctionsFolder) {
        throw "Package is missing '.azurefunctions' at zip root. Function indexing will fail with '0 functions found'."
    }

    if ($entryNames -notcontains "host.json") {
        throw "Package is missing host.json at zip root."
    }

    if ($entryNames -notcontains "functions.metadata") {
        throw "Package is missing functions.metadata at zip root."
    }

    $metadataEntry = $entries | Where-Object { $_.FullName -eq "functions.metadata" } | Select-Object -First 1
    if ($null -eq $metadataEntry) {
        throw "functions.metadata entry was not readable."
    }

    $reader = [System.IO.StreamReader]::new($metadataEntry.Open())
    try {
        $metadataJson = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }

    $functions = $metadataJson | ConvertFrom-Json
    if ($null -eq $functions) {
        throw "functions.metadata is empty or invalid JSON."
    }

    $functionList = @($functions)
    if ($functionList.Count -eq 0) {
        throw "functions.metadata has no function definitions."
    }

    $functionNames = @($functionList | ForEach-Object { $_.name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $missingFunctions = @($ExpectedFunctionNames | Where-Object { $functionNames -notcontains $_ })
    if ($missingFunctions.Count -gt 0) {
        throw "functions.metadata missing expected functions: $($missingFunctions -join ', '). Found: $($functionNames -join ', ')"
    }

    $missingScriptFiles = New-Object System.Collections.Generic.List[string]
    foreach ($f in $functionList) {
        if ([string]::IsNullOrWhiteSpace($f.scriptFile)) {
            $missingScriptFiles.Add("$($f.name):<empty scriptFile>") | Out-Null
            continue
        }

        if ($entryNames -notcontains $f.scriptFile) {
            $missingScriptFiles.Add("$($f.name):$($f.scriptFile)") | Out-Null
        }
    }

    if ($missingScriptFiles.Count -gt 0) {
        throw "Script file(s) referenced in functions.metadata not found at package root: $($missingScriptFiles -join ', ')"
    }

    [pscustomobject]@{
        PackagePath = $PackagePath
        HostJsonAtRoot = $true
        AzureFunctionsFolderAtRoot = $true
        FunctionCount = $functionList.Count
        Functions = $functionNames
        VerifiedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    }
}
finally {
    $zip.Dispose()
}
