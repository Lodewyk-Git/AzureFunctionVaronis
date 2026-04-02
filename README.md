# AzureFunctionVaronis

Production-ready Azure Function integration for ingesting Varonis alerts into Microsoft Sentinel using Azure Monitor Logs Ingestion API (DCR/DCE model), with Azure-first deployment and ZIP package release flow.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FLodewyk-Git%2FAzureFunctionVaronis%2Fmain%2Fazuredeploy.json)

Deploy button expects an existing Sentinel-enabled Log Analytics workspace resource ID.

## What This Repository Delivers
- .NET 8 isolated Azure Function (`VaronisAlertTimerFunction`)
- Managed identity-first ingestion to Log Analytics custom table
- Idempotent table lifecycle automation:
  - create if missing
  - migrate classic table if present
  - reconcile schema drift safely
  - optional automatic V2 table creation for breaking changes
- Infrastructure as code (Bicep modules)
- Packaging and `WEBSITE_RUN_FROM_PACKAGE` deployment automation
- GitHub Actions CI/CD with artifact packaging and Azure deployment

## Solution Architecture
Detailed architecture is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Repository Structure
```text
AzureFunctionVaronis/
|- .github/workflows/
|  |- ci-cd.yml                         # Build/package + manual Azure deploy
|  |- release-package.yml               # Tag/manual release packaging to GitHub Releases
|- docs/
|  |- ARCHITECTURE.md                  # Architecture, flows, dependency graph, security model
|- functionapp/
|  |- packages/                        # Versioned ZIP artifacts (ignored in git)
|  |- manifests/                       # Build metadata for package versions
|  |- README.md                        # Artifact conventions
|- infra/
|  |- main.bicep                       # One-shot IaC entry point
|  |- main.parameters.example.json     # Example deployment parameters
|  |- table-schema.json                # Canonical custom table schema
|  |- modules/
|     |- core.bicep                    # Function app, storage, plan, KV, workspace refs
|     |- monitoring.bicep              # Table, DCE, DCR, DCR sender RBAC
|- scripts/
|  |- Build-Package.ps1                # Dotnet publish + zip + sha + manifest
|  |- Publish-Package.ps1              # Upload zip + set WEBSITE_RUN_FROM_PACKAGE
|  |- Invoke-TableLifecycle.ps1        # Create/migrate/reconcile custom table
|  |- Deploy-Solution.ps1              # End-to-end Azure-first deployment
|  |- Validate-Deployment.ps1          # Health + ingestion + DCR checks
|- src/Varonis.Sentinel.Functions/
|  |- Functions/VaronisAlertTimerFunction.cs
|  |- Models/
|  |- Options/
|  |- Services/
|  |- Utilities/
|  |- Program.cs
|  |- host.json
|  |- local.settings.sample.json
|  |- Varonis.Sentinel.Functions.csproj
|- AzureFunctionVaronis.sln
|- deploy.ps1                          # Root deployment entry point
|- README.md
```

## Prerequisites
- Azure subscription with permission to create Function App, Storage, Key Vault, DCR/DCE, and RBAC assignments
- Azure CLI `2.75+`
- PowerShell `7+`
- .NET SDK `9.0.x` (building `net8.0` target)
- Varonis API base URL and API key

## Azure-First Deployment
Use the root deployment entry point:

```powershell
./deploy.ps1 `
  -ResourceGroupName rg-varonis-prod `
  -Location eastus2 `
  -EnvironmentName prod `
  -NamePrefix varonis `
  -WorkspaceResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<sentinel-workspace>" `
  -TableName VaronisAlerts_CL `
  -VaronisBaseUrl "https://tenant.varonis.net" `
  -VaronisApiKey (Read-Host "Varonis API key" -AsSecureString) `
  -RunValidation
```

### What `deploy.ps1` / `Deploy-Solution.ps1` Does
1. Deploys core IaC (`infra/modules/core.bicep`).
2. Stores Varonis API key in Key Vault (if provided).
3. Runs table lifecycle reconciliation (`Invoke-TableLifecycle.ps1`).
4. Deploys monitoring IaC (`infra/modules/monitoring.bicep`) using resolved table/stream.
5. Applies function app settings for endpoint, DCR immutable ID, stream, and workspace wiring.
6. Builds package ZIP (unless skipped) and publishes via `WEBSITE_RUN_FROM_PACKAGE`.
7. Executes deployment validation (optional).

Important: deployment targets an existing Sentinel-enabled workspace and does not create a new workspace.

## Package Deployment Model (`WEBSITE_RUN_FROM_PACKAGE`)
### Build
- `scripts/Build-Package.ps1` publishes the function app and creates ZIP, SHA256, and manifest artifacts.

### Storage and Reference
- `scripts/Publish-Package.ps1` uploads ZIP to private blob storage and updates Function App package settings.

### Versioning
- Version defaults to `yyyyMMddHHmmss-<gitsha>`.
- Every build produces a versioned manifest.
- Previous package metadata is retained in app settings during publish.

### GitHub Release Integration
- `release-package.yml` publishes `varonis-sentinel-functions.zip`.
- IaC default for `WEBSITE_RUN_FROM_PACKAGE` points to:
  - `https://github.com/Lodewyk-Git/AzureFunctionVaronis/releases/latest/download/varonis-sentinel-functions.zip`

## Validation
Run deployment validation:

```powershell
./scripts/Validate-Deployment.ps1 `
  -ResourceGroupName <rg> `
  -FunctionAppName <app> `
  -WorkspaceResourceId <workspaceResourceId> `
  -TableName VaronisAlerts_CL `
  -DcrResourceId <dcrResourceId> `
  -LogsIngestionEndpoint <dceEndpoint> `
  -TriggerFunction
```

KQL check:

```kql
VaronisAlerts_CL
| where TimeGenerated > ago(60m)
| summarize Records=count(), Latest=max(TimeGenerated)
```

## Rollback
Set a known good package and restart the app:

```powershell
az functionapp config appsettings set `
  --resource-group <rg> `
  --name <app> `
  --settings "WEBSITE_RUN_FROM_PACKAGE=<known-good-package-url>"
az functionapp restart --resource-group <rg> --name <app>
```

## CI/CD
Workflow: [.github/workflows/ci-cd.yml](.github/workflows/ci-cd.yml)

Stages:
1. Build + package artifact on PR/push.
2. Manual `workflow_dispatch` deploy to Azure using OIDC.

Expected GitHub environment secrets:
- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`
- `VARONIS_BASE_URL`
- `VARONIS_API_KEY`

## References
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Release workflow (`release-package.yml`) builds and publishes package assets when a `v*` tag is pushed (or manually dispatched).
