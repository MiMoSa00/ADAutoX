# ADAutoX Module Loader
# DEPENDENCY ORDER IS SIGNIFICANT - do not reorder this list.
# Load order: Sanitizer and Logging first (no internal deps),
# then Security (no internal deps), then Context (uses Sanitizer),
# then Provisioner (uses Sanitizer + Logging), then Reporting (uses Logging).
# Bug #27: order documented here. Bug #10: missing files throw immediately.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleRoot = $PSScriptRoot
$subModules = @(
    'ADAutoX.Sanitizer.psm1',   # Level 0: no internal dependencies
    'ADAutoX.Logging.psm1',     # Level 0: no internal dependencies
    'ADAutoX.Security.psm1',    # Level 0: no internal dependencies
    'ADAutoX.Context.psm1',     # Level 1: uses Sanitizer
    'ADAutoX.Provisioner.psm1', # Level 2: uses Sanitizer + Logging
    'ADAutoX.Reporting.psm1'    # Level 2: uses Logging
)

foreach ($sub in $subModules) {
    $subPath = Join-Path $moduleRoot "Modules\$sub"
    if (Test-Path -LiteralPath $subPath) {
        Import-Module $subPath -Force
    }
    else {
        # Bug #10: fail immediately with a clear message, not silently skip
        throw "Required module file not found: $subPath"
    }
}
