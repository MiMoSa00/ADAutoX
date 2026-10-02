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
    Write-Host "  3. View / Filter Audit Logs" -ForegroundColor White
    Write-Host "  4. Execute Security Posture Scan" -ForegroundColor White
    Write-Host "  5. Manage User Lifecycle (Enable, Disable, Unlock, ResetPassword, Move, Terminate)" -ForegroundColor White
    Write-Host "  6. Reset / Teardown Lab Environment (-AllowDestructiveOperation)" -ForegroundColor Red
    Write-Host "  7. Run Framework Unit Test Suite" -ForegroundColor Magenta
    Write-Host "  8. Exit Console" -ForegroundColor Gray
    Write-Host "==========================================================================" -ForegroundColor Cyan
}

# Bug #13 (console loop): handle EOF gracefully so the loop terminates on piped/automated runs
while ($true) {
    Show-ADAutoXMenu

    $choice = $null
    try {
        $choice = Read-Host "Select an option [1-8]"
    }
    catch {
        Write-Host "Input stream closed. Exiting." -ForegroundColor Yellow
        break
    }
    if ($null -eq $choice) { break }

    switch ($choice) {
        '1' {
            Write-Host "`n[Preview Provisioning Mode]" -ForegroundColor Yellow
            # Bug #13 (console crashes on bad input): wrap int conversion
            $countInput = Read-Host "Enter number of accounts to preview (Default: 5)"
            $count = 5
            if ($countInput) {
                try { $count = [int]$countInput }
                catch { Write-Host "Invalid number, using default 5." -ForegroundColor Yellow }
            }
            powershell -ExecutionPolicy Bypass -File (Join-Path $rootDir 'Cmdlets\Invoke-ADAutoXProvision.ps1') -AccountCount $count -WhatIf
            Read-Host "`nPress Enter to return to menu..."
        }
        '2' {
            Write-Host "`n[Live Bulk Provisioning Mode]" -ForegroundColor Green
            $countInput = Read-Host "Enter number of accounts to provision (Default: 20)"
            $count = 20
            if ($countInput) {
                try { $count = [int]$countInput }
                catch { Write-Host "Invalid number, using default 20." -ForegroundColor Yellow }
            }
            powershell -ExecutionPolicy Bypass -File (Join-Path $rootDir 'Cmdlets\Invoke-ADAutoXProvision.ps1') -AccountCount $count -RollbackOnFailure
            Read-Host "`nPress Enter to return to menu..."
        }
        '3' {
            Write-Host "`n[Audit Log Viewer]" -ForegroundColor White
            # Bug #17: expose filtering options consistently
            $filterAction   = Read-Host "Filter by Action (e.g. CreateUser, ResetPassword) - leave blank for all"
            $filterStatus   = Read-Host "Filter by Status (e.g. Succeeded, Failed, Skipped) - leave blank for all"
            $filterIdentity = Read-Host "Filter by Identity (partial DN or name match) - leave blank for all"
            $showFull       = Read-Host "Show full record details? (y/n, default n)"
            $fullFlag = if ($showFull -eq 'y') { '-Full' } else { '' }

            $auditArgs = @("-File", (Join-Path $rootDir 'Cmdlets\Get-ADAutoXAuditReport.ps1'))
            if ($filterAction)   { $auditArgs += @('-Action', $filterAction) }
            if ($filterStatus)   { $auditArgs += @('-Status', $filterStatus) }
            if ($filterIdentity) { $auditArgs += @('-Identity', $filterIdentity) }
            if ($showFull -eq 'y') { $auditArgs += '-Full' }

            powershell -ExecutionPolicy Bypass @auditArgs
            Read-Host "`nPress Enter to return to menu..."
        }
        '4' {
            Write-Host "`n[Security Posture Scan]" -ForegroundColor White
            # Bug #17: expose scan options consistently
            $searchBase  = Read-Host "Enter SearchBase DN (leave blank for domain root)"
            $inactiveDays = Read-Host "Flag accounts inactive for how many days? (Default: 90)"
            $days = 90
            if ($inactiveDays) {
                try { $days = [int]$inactiveDays }
                catch { Write-Host "Invalid number, using default 90." -ForegroundColor Yellow }
            }
            $scanParams = @{}
            if ($searchBase) { $scanParams['SearchBase'] = $searchBase }
            $scanParams['InactiveDays'] = $days
            Get-ADAutoXSecurityScan @scanParams
            Read-Host "`nPress Enter to return to menu..."
        }
        '5' {
            Write-Host "`n[Manage User Lifecycle]" -ForegroundColor White
            $identity = Read-Host "Enter target SamAccountName (e.g. chinedu.okafor)"
            # Bug #18: all 6 actions listed including Move
            $action   = Read-Host "Enter Action (Enable, Disable, Unlock, ResetPassword, Move, Terminate)"
            if ($identity -and $action) {
                powershell -ExecutionPolicy Bypass -File (Join-Path $rootDir 'Cmdlets\Manage-ADAutoXUser.ps1') -Identity $identity -Action $action
            }
            Read-Host "`nPress Enter to return to menu..."
        }
        '6' {
            Write-Host "`n[Reset / Teardown Lab Environment]" -ForegroundColor Red
            Write-Host "This operation will RECURSIVELY DELETE the entire OU structure and all users, groups, and OUs inside it." -ForegroundColor Red

            # Bug #16: case-sensitive comparison using -ceq
            $confirm = Read-Host "Type exactly 'DELETE' (uppercase) to confirm"
            if ($confirm -ceq 'DELETE') {
                powershell -ExecutionPolicy Bypass -File (Join-Path $rootDir 'Cmdlets\Reset-ADAutoXEnvironment.ps1') -AllowDestructiveOperation
            }
            else {
                Write-Host "Reset cancelled. (Tip: type DELETE in uppercase to confirm.)" -ForegroundColor Yellow
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
            Write-Host "Invalid option '$choice'. Choose 1-8." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}
