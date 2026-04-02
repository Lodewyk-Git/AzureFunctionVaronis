[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [string]$TableName = "",

    [string]$SchemaFilePath = "infra/table-schema.json",

    [switch]$AutoMigrateClassic = $true,

    [switch]$AllowBreakingChangeWithV2Table,

    [switch]$AsJson,

    [string]$SubscriptionId = ""
)

$ErrorActionPreference = "Stop"

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    az account set --subscription $SubscriptionId | Out-Null
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$resolvedSchemaPath = if ([IO.Path]::IsPathRooted($SchemaFilePath)) { $SchemaFilePath } else { Join-Path $repoRoot $SchemaFilePath }

if (-not (Test-Path -LiteralPath $resolvedSchemaPath)) {
    throw "Schema file not found: $resolvedSchemaPath"
}

$schema = Get-Content -Path $resolvedSchemaPath -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($TableName)) {
    $TableName = $schema.tableName
}

if (-not $TableName.EndsWith("_CL")) {
    throw "Custom log table name must end with '_CL'. Received '$TableName'."
}

$columnsFromSchema = @($schema.columns)
if ($columnsFromSchema.Count -eq 0) {
    throw "Schema file does not contain any columns."
}

$desiredColumns = @{}
foreach ($column in $columnsFromSchema) {
    $desiredColumns[$column.name] = $column.type.ToString().ToLowerInvariant()
}

function Get-Table {
    param([string]$TableNameValue)

    $output = az monitor log-analytics workspace table list `
        --resource-group $ResourceGroupName `
        --workspace-name $WorkspaceName `
        --only-show-errors `
        --output json 2>$null

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list tables in workspace '$WorkspaceName'."
    }

    $tables = $output | ConvertFrom-Json
    foreach ($table in $tables) {
        if ($table.name -eq $TableNameValue) {
            return $table
        }
    }

    return $null
}

function Get-TableStrict {
    param([string]$TableNameValue)

    $output = az monitor log-analytics workspace table show `
        --resource-group $ResourceGroupName `
        --workspace-name $WorkspaceName `
        --name $TableNameValue `
        --only-show-errors `
        --output json 2>&1

    if ($LASTEXITCODE -eq 0) {
        return ($output | ConvertFrom-Json)
    }

    $errorText = ($output | Out-String)
    if ($errorText -match "not found|ResourceNotFound|Could not find") {
        return $null
    }
    throw "Failed to fetch table '$TableNameValue'. Error: $errorText"
}

function New-ColumnArguments {
    param([hashtable]$Columns)

    return @(
        foreach ($key in $Columns.Keys) {
            "$key=$($Columns[$key])"
        }
    )
}

function Get-VersionedTableName {
    param([string]$OriginalTableName)

    $baseName = $OriginalTableName.Substring(0, $OriginalTableName.Length - 3)
    for ($version = 2; $version -le 20; $version++) {
        $candidate = "${baseName}_v${version}_CL"
        if ($candidate.Length -gt 63) {
            $candidate = $candidate.Substring(0, 63)
            if (-not $candidate.EndsWith("_CL")) {
                $candidate = $candidate.Substring(0, 60) + "_CL"
            }
        }

        $existing = Get-Table -TableNameValue $candidate
        if ($null -eq $existing) {
            return $candidate
        }
    }

    throw "Unable to generate a free v2 table name for '$OriginalTableName'."
}

function Create-Table {
    param(
        [string]$TableToCreate,
        [hashtable]$ColumnsMap
    )

    $columnArgs = New-ColumnArguments -Columns $ColumnsMap
    $planValue = if ([string]::IsNullOrWhiteSpace($schema.plan)) { "Analytics" } else { $schema.plan }
    $retentionValue = if ($null -eq $schema.retentionInDays) { 30 } else { [int]$schema.retentionInDays }
    $totalRetentionValue = if ($null -eq $schema.totalRetentionInDays) { 90 } else { [int]$schema.totalRetentionInDays }

    $args = @(
        "monitor", "log-analytics", "workspace", "table", "create",
        "--resource-group", $ResourceGroupName,
        "--workspace-name", $WorkspaceName,
        "--name", $TableToCreate,
        "--plan", $planValue,
        "--retention-time", $retentionValue,
        "--total-retention-time", $totalRetentionValue,
        "--columns"
    ) + $columnArgs + @("--only-show-errors", "--output", "json")

    $createOutput = az @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create table '$TableToCreate'. Error: $($createOutput | Out-String)"
    }
}

function Update-TableColumns {
    param(
        [string]$TableToUpdate,
        [hashtable]$ColumnsMap
    )

    $columnArgs = New-ColumnArguments -Columns $ColumnsMap

    $args = @(
        "monitor", "log-analytics", "workspace", "table", "update",
        "--resource-group", $ResourceGroupName,
        "--workspace-name", $WorkspaceName,
        "--name", $TableToUpdate,
        "--columns"
    ) + $columnArgs + @("--only-show-errors", "--output", "json")

    $updateOutput = az @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to update table '$TableToUpdate'. Error: $($updateOutput | Out-String)"
    }
}

$resolvedTableName = $TableName
$created = $false
$migrated = $false
$createdV2 = $false
$alreadyDcrBased = $false
$migrationSkippedReason = ""
$addedColumns = @()
$typeMismatches = @()

$table = Get-Table -TableNameValue $resolvedTableName

if ($null -eq $table) {
    Create-Table -TableToCreate $resolvedTableName -ColumnsMap $desiredColumns
    $created = $true
    $table = Get-TableStrict -TableNameValue $resolvedTableName
}
else {
    $tableSubType = $table.schema.tableSubType
    $alreadyDcrBased = ($tableSubType -eq "DataCollectionRuleBased")

    if ($AutoMigrateClassic -and -not $alreadyDcrBased) {
        try {
            $migrateOutput = az monitor log-analytics workspace table migrate `
                --resource-group $ResourceGroupName `
                --workspace-name $WorkspaceName `
                --table-name $resolvedTableName `
                --only-show-errors `
                --output json 2>&1

            if ($LASTEXITCODE -eq 0) {
                $migrated = $true
            }
            else {
                $errorText = ($migrateOutput | Out-String)
                if ($errorText -match "No Content") {
                    $migrated = $true
                }
                elseif ($errorText -notmatch "already|cannot|not eligible|BadRequest") {
                    throw "Table migration command failed: $errorText"
                }
            }
        }
        catch {
            if ($_.Exception.Message -match "No Content") {
                $migrated = $true
            }
            elseif ($_.Exception.Message -notmatch "already|cannot|not eligible|BadRequest") {
                throw
            }
        }
    }
    elseif ($AutoMigrateClassic -and $alreadyDcrBased) {
        $migrationSkippedReason = "Table already DataCollectionRuleBased."
    }
    elseif (-not $AutoMigrateClassic) {
        $migrationSkippedReason = "Auto migration disabled by parameter."
    }

    $table = Get-TableStrict -TableNameValue $resolvedTableName
}

$existingColumns = @{}
foreach ($column in @($table.schema.columns)) {
    $existingColumns[$column.name] = $column.type.ToString().ToLowerInvariant()
}

foreach ($columnName in $desiredColumns.Keys) {
    if (-not $existingColumns.ContainsKey($columnName)) {
        $addedColumns += $columnName
        continue
    }

    if ($existingColumns[$columnName] -ne $desiredColumns[$columnName]) {
        $typeMismatches += [pscustomobject]@{
            Column = $columnName
            ExistingType = $existingColumns[$columnName]
            DesiredType = $desiredColumns[$columnName]
        }
    }
}

if ($typeMismatches.Count -gt 0) {
    if (-not $AllowBreakingChangeWithV2Table) {
        $mismatchText = ($typeMismatches | ConvertTo-Json -Depth 5 -Compress)
        throw "Breaking schema drift detected in table '$resolvedTableName'. Rerun with -AllowBreakingChangeWithV2Table to create a v2 table. Mismatches: $mismatchText"
    }

    $resolvedTableName = Get-VersionedTableName -OriginalTableName $resolvedTableName
    Create-Table -TableToCreate $resolvedTableName -ColumnsMap $desiredColumns
    $createdV2 = $true
    $created = $true
}
elseif ($addedColumns.Count -gt 0) {
    foreach ($key in $desiredColumns.Keys) {
        $existingColumns[$key] = $desiredColumns[$key]
    }

    Update-TableColumns -TableToUpdate $resolvedTableName -ColumnsMap $existingColumns
}

$result = [pscustomobject]@{
    OriginalTableName = $TableName
    ResolvedTableName = $resolvedTableName
    ResolvedStreamName = "Custom-$resolvedTableName"
    Created = $created
    CreatedV2 = $createdV2
    AlreadyDcrBased = $alreadyDcrBased
    MigratedClassic = $migrated
    MigrationSkippedReason = $migrationSkippedReason
    AddedColumns = $addedColumns
    TypeMismatches = $typeMismatches
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
}
else {
    $result
}
