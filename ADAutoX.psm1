# ADAutoX Module Loader
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleRoot = $PSScriptRoot
$subModules = @(
    'ADAutoX.Sanitizer.psm1',
    'ADAutoX.Logging.psm1',
    'ADAutoX.Security.psm1',
    'ADAutoX.Context.psm1',
    'ADAutoX.Provisioner.psm1',
    'ADAutoX.Reporting.psm1'
)

foreach ($sub in $subModules) {
    $subPath = Join-Path $moduleRoot "Modules\$sub"
    if (Test-Path -LiteralPath $subPath) {
        Import-Module $subPath -Force
    }
}
