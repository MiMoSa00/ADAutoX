Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$global:TestFailures = 0

Write-Host "=========================================================" -ForegroundColor Yellow
Write-Host "         ADAutoX Framework - Unit Test Suite             " -ForegroundColor Yellow
Write-Host "=========================================================" -ForegroundColor Yellow

. (Join-Path $PSScriptRoot 'Sanitizer.Tests.ps1')
. (Join-Path $PSScriptRoot 'Security.Tests.ps1')

# Manifest integrity: verify every function declared in FunctionsToExport is actually available
Write-Host "`n=== Running ADAutoX.psd1 Manifest Integrity Tests ===" -ForegroundColor Cyan
$manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'ADAutoX.psd1'
$manifest = Import-PowerShellDataFile -Path $manifestPath
$allPass = $true
foreach ($fn in $manifest.FunctionsToExport) {
    if (Get-Command $fn -ErrorAction SilentlyContinue) {
        Write-Host "  [PASS] Manifest function exported and available: $fn" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Manifest function missing or not loaded: $fn" -ForegroundColor Red
        $global:TestFailures++
        $allPass = $false
    }
}
if ($allPass) {
    Write-Host "  All $($manifest.FunctionsToExport.Count) declared functions verified." -ForegroundColor Green
}

# Manifest private variable guard: VariablesToExport must be @() (not '*')
$varExport = $manifest.VariablesToExport
$noWildcard = ($null -eq $varExport) -or ($varExport.Count -eq 0) -or ($varExport -notcontains '*')
if ($noWildcard) {
    Write-Host "  [PASS] VariablesToExport is locked (not '*') - private module state is protected." -ForegroundColor Green
} else {
    Write-Host "  [FAIL] VariablesToExport is '*' - private module state is exposed globally." -ForegroundColor Red
    $global:TestFailures++
}

Write-Host "`n---------------------------------------------------------" -ForegroundColor Yellow
if ($global:TestFailures -eq 0) {
    Write-Host " ALL UNIT TESTS PASSED! SUCCESS." -ForegroundColor Green
    exit 0
} else {
    Write-Host " FAILED UNIT TESTS: $global:TestFailures" -ForegroundColor Red
    exit 1
}
