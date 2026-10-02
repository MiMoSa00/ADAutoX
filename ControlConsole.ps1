<#
.SYNOPSIS
    Interactive Control Console and Operator Dashboard for ADAutoX.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rootDir = $PSScriptRoot
Import-Module (Join-Path $rootDir 'ADAutoX.psd1') -Force

function Show-ADAutoXMenu {
    Clear-Host
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host "                ADAutoX Enterprise Active Directory Framework            " -ForegroundColor Cyan
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host "  1. Preview Provisioning (-WhatIf Mode)" -ForegroundColor Yellow
    Write-Host "  2. Execute Live Bulk Provisioning (Transactional Rollback Enabled)" -ForegroundColor Green
    Write-Host "  3. View / Filter Audit Logs (JSONL Reader)" -ForegroundColor White
    Write-Host "  4. Execute Security Posture Scan" -ForegroundColor White
    Write-Host "  5. Manage User Lifecycle (Enable, Disable, Unlock, Reset Password)" -ForegroundColor White
    Write-Host "  6. Reset / Teardown Lab Environment (-AllowDestructiveOperation)" -ForegroundColor Red
    Write-Host "  7. Run Framework Unit Test Suite" -ForegroundColor Magenta
    Write-Host "  8. Exit Console" -ForegroundColor Gray
    Write-Host "==========================================================================" -ForegroundColor Cyan
}

while ($true) {
    Show-ADAutoXMenu
    $choice = Read-Host "Select an option [1-8]"

    switch ($choice) {
        '1' {
            Write-Host "`n[Preview Provisioning Mode]" -ForegroundColor Yellow
            try {
                $countInput = Read-Host "Enter number of accounts to preview (Default: 5)"
                $count = if ([string]::IsNullOrWhiteSpace($countInput)) { 5 } else { [int]$countInput }
                powershell -ExecutionPolicy Bypass -File (Join-Path $rootDir 'Cmdlets\Invoke-ADAutoXProvision.ps1') -AccountCount $count -WhatIf
            }
            catch {
                Write-Host "Invalid input. Please enter a whole number." -ForegroundColor Red
            }
            Read-Host "`nPress Enter to return to menu..."
        }
        '2' {
            Write-Host "`n[Live Bulk Provisioning Mode]" -ForegroundColor Green
            try {
                $countInput = Read-Host "Enter number of accounts to provision (Default: 20)"
                $count = if ([string]::IsNullOrWhiteSpace($countInput)) { 20 } else { [int]$countInput }
                powershell -ExecutionPolicy Bypass -File (Join-Path $rootDir 'Cmdlets\Invoke-ADAutoXProvision.ps1') -AccountCount $count -RollbackOnFailure
            }
            catch {
                Write-Host "Invalid input. Please enter a whole number." -ForegroundColor Red
            }
            Read-Host "`nPress Enter to return to menu..."
        }
        '3' {
            Write-Host "`n[Audit Log Viewer]" -ForegroundColor White
            $identityFilter = Read-Host "Optional Identity filter (blank for all)"
            $actionFilter   = Read-Host "Optional Action filter (blank for all)"
            $statusFilter   = Read-Host "Optional Status filter (blank for all)"
            $actorFilter    = Read-Host "Optional Actor filter (blank for all)"
            powershell -ExecutionPolicy Bypass -File (Join-Path $rootDir 'Cmdlets\Get-ADAutoXAuditReport.ps1') -Identity $identityFilter -Action $actionFilter -Status $statusFilter -Actor $actorFilter
            Read-Host "`nPress Enter to return to menu..."
        }
        '4' {
            Write-Host "`n[Security Posture Scan]" -ForegroundColor White
            $searchBase = Read-Host "Optional SearchBase (blank for default forest)"
            $inactiveDaysInput = Read-Host "Inactive days threshold (Default: 90)"
            $scanParams = @{}
            if ($searchBase) { $scanParams.SearchBase = $searchBase }
            if ($inactiveDaysInput) { $scanParams.InactiveDays = [int]$inactiveDaysInput }
            Get-ADAutoXSecurityScan @scanParams
            Read-Host "`nPress Enter to return to menu..."
        }
        '5' {
            Write-Host "`n[Manage User Lifecycle]" -ForegroundColor White
            $identity = Read-Host "Enter target SamAccountName (e.g. chinedu.okafor)"
            $action   = Read-Host "Enter Action (Enable, Disable, Unlock, ResetPassword, Move, Terminate)"
            if ($identity -and $action) {
                powershell -ExecutionPolicy Bypass -File (Join-Path $rootDir 'Cmdlets\Manage-ADAutoXUser.ps1') -Identity $identity -Action $action
            }
            Read-Host "`nPress Enter to return to menu..."
        }
        '6' {
            Write-Host "`n[Reset / Teardown Lab Environment]" -ForegroundColor Red
            $confirm = Read-Host "Type 'DELETE' to confirm environment teardown"
            if ($confirm -ceq 'DELETE') {
                powershell -ExecutionPolicy Bypass -File (Join-Path $rootDir 'Cmdlets\Reset-ADAutoXEnvironment.ps1') -AllowDestructiveOperation
            } else {
                Write-Host "Reset cancelled." -ForegroundColor Yellow
            }
            Read-Host "`nPress Enter to return to menu..."
        }
        '7' {
            Write-Host "`n[Running ADAutoX Unit Test Suite]" -ForegroundColor Magenta
            powershell -ExecutionPolicy Bypass -File (Join-Path $rootDir 'Tests\Run-Tests.ps1')
            Read-Host "`nPress Enter to return to menu..."
        }
        '8' {
            Write-Host "Exiting ADAutoX Console. Goodbye!" -ForegroundColor Cyan
            exit 0
        }
        default {
            Write-Host "Invalid option. Try again." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}
