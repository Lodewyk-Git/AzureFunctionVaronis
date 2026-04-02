[CmdletBinding()]
param(
    [string]$ProjectPath = "src/Varonis.Sentinel.Functions/Varonis.Sentinel.Functions.csproj",
    [string]$Configuration = "Release",
    [string]$OutputDirectory = "functionapp/packages",
    [string]$Version = "",
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$projectFullPath = Join-Path $repoRoot $ProjectPath

if (-not (Test-Path -LiteralPath $projectFullPath)) {
    throw "Project file not found: $projectFullPath"
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $timestamp = Get-Date -Format "yyyyMMddHHmmss"
    $gitSha = (git -C $repoRoot rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitSha)) {
        $gitSha = "nogit"
    }

    $Version = "$timestamp-$gitSha"
}

if (-not $SkipTests) {
    $testProjectPath = Join-Path $repoRoot "tests/Varonis.Sentinel.Functions.Tests/Varonis.Sentinel.Functions.Tests.csproj"
    if (Test-Path -LiteralPath $testProjectPath) {
        dotnet test $testProjectPath --configuration $Configuration --verbosity minimal
    }
}

$artifactRoot = Join-Path $repoRoot ".artifacts"
$publishPath = Join-Path $artifactRoot "publish/$Version"
$outputPath = Join-Path $repoRoot $OutputDirectory
$manifestPath = Join-Path $repoRoot "functionapp/manifests/$Version.json"
$latestManifestPath = Join-Path $repoRoot "functionapp/manifests/latest.json"

New-Item -ItemType Directory -Path $publishPath -Force | Out-Null
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path $manifestPath -Parent) -Force | Out-Null

dotnet publish $projectFullPath `
    --configuration $Configuration `
    --output $publishPath `
    /p:UseAppHost=false `
    /p:ContinuousIntegrationBuild=true

$zipFileName = "varonis-sentinel-functions-$Version.zip"
$zipFilePath = Join-Path $outputPath $zipFileName
if (Test-Path -LiteralPath $zipFilePath) {
    Remove-Item -LiteralPath $zipFilePath -Force
}

Compress-Archive -Path (Join-Path $publishPath "*") -DestinationPath $zipFilePath -CompressionLevel Optimal

$hash = Get-FileHash -Path $zipFilePath -Algorithm SHA256
$hashFilePath = "$zipFilePath.sha256"
$hash.Hash | Out-File -FilePath $hashFilePath -Encoding ascii

if ($zipFilePath.StartsWith($repoRoot.Path, [StringComparison]::OrdinalIgnoreCase)) {
    $relativePackagePath = $zipFilePath.Substring($repoRoot.Path.Length).TrimStart('\', '/')
}
else {
    $relativePackagePath = $zipFilePath
}

$manifest = [ordered]@{
    version = $Version
    packageFileName = $zipFileName
    packageRelativePath = $relativePackagePath
    sha256 = $hash.Hash
    builtAtUtc = (Get-Date).ToUniversalTime().ToString("O")
}

$manifestJson = $manifest | ConvertTo-Json -Depth 5
$manifestJson | Set-Content -Path $manifestPath -Encoding utf8
$manifestJson | Set-Content -Path $latestManifestPath -Encoding utf8

Write-Host "Package built: $zipFilePath"
Write-Host "SHA256: $($hash.Hash)"

[pscustomobject]@{
    Version = $Version
    PackagePath = $zipFilePath
    HashPath = $hashFilePath
    ManifestPath = $manifestPath
}
