Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$global:TestFailures = 0

Write-Host "=========================================================" -ForegroundColor Yellow
Write-Host "         ADAutoX Framework - Unit Test Suite             " -ForegroundColor Yellow
Write-Host "=========================================================" -ForegroundColor Yellow

. (Join-Path $PSScriptRoot 'Sanitizer.Tests.ps1')
. (Join-Path $PSScriptRoot 'Security.Tests.ps1')

$manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'ADAutoX.psd1'
Import-Module $manifestPath -Force
if (Get-Command Test-ADAutoXPendingLedger -ErrorAction SilentlyContinue) {
    Write-Host '  [PASS] Module manifest exports pending-ledger guard' -ForegroundColor Green
} else {
    Write-Host '  [FAIL] Module manifest exports pending-ledger guard' -ForegroundColor Red
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
