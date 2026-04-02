# Function Package Artifacts

This folder holds versioned ZIP packages consumed by Azure Function Apps through `WEBSITE_RUN_FROM_PACKAGE`.

- `packages/`: Build output ZIP artifacts (not committed).
- `manifests/`: Build metadata (`latest.json` and versioned manifests) used by deployment automation.

Use `scripts/Build-Package.ps1` to generate package artifacts and `scripts/Publish-Package.ps1` to publish and activate them.
