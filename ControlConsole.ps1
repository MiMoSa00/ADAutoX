<#
.SYNOPSIS
    Interactive Control Console and Operator Dashboard for ADAutoX.

.NOTES
    Write-Host is used intentionally throughout this script: it is a colorized
    interactive terminal dashboard where output capture/redirection is not needed.
    PSAvoidUsingWriteHost is suppressed on all functions via SuppressMessageAttribute.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rootDir = $PSScriptRoot
Import-Module (Join-Path -Path $rootDir -ChildPath 'ADAutoX.psd1') -Force

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
            $countInput = Read-Host "Enter number of accounts to preview (Default: 5)"
            $count = 5
            if ($countInput) {
                try { $count = [int]$countInput }
                catch { Write-Host "Invalid number, using default 5." -ForegroundColor Yellow }
            }
            # BUG-34: Run in-process with & instead of spawning a new bypass process
            & (Join-Path -Path $rootDir -ChildPath 'Cmdlets\Invoke-ADAutoXProvision.ps1') -AccountCount $count -WhatIf
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
            & (Join-Path -Path $rootDir -ChildPath 'Cmdlets\Invoke-ADAutoXProvision.ps1') -AccountCount $count -RollbackOnFailure
            Read-Host "`nPress Enter to return to menu..."
        }
        '3' {
            Write-Host "`n[Audit Log Viewer]" -ForegroundColor White
            $filterAction   = Read-Host "Filter by Action (e.g. CreateUser, ResetPassword) - leave blank for all"
            $filterStatus   = Read-Host "Filter by Status (e.g. Succeeded, Failed, Skipped) - leave blank for all"
            $filterIdentity = Read-Host "Filter by Identity (partial DN or name match) - leave blank for all"
            $showFull       = Read-Host "Show full record details? (y/n, default n)"

            $auditArgs = @{}
            if ($filterAction)   { $auditArgs['Action'] = $filterAction }
            if ($filterStatus)   { $auditArgs['Status'] = $filterStatus }
            if ($filterIdentity) { $auditArgs['Identity'] = $filterIdentity }
            if ($showFull -eq 'y') { $auditArgs['Full'] = $true }

            & (Join-Path -Path $rootDir -ChildPath 'Cmdlets\Get-ADAutoXAuditReport.ps1') @auditArgs
            Read-Host "`nPress Enter to return to menu..."
        }
        '4' {
            Write-Host "`n[Security Posture Scan]" -ForegroundColor White
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
            
            # BUG-33: Show the six valid actions as a menu
            Write-Host "Valid Actions: Enable, Disable, Unlock, ResetPassword, Move, Terminate"
            $action = Read-Host "Enter Action"
            
            if ($identity -and $action) {
                $manageArgs = @{
                    Identity = $identity
                    Action   = $action
                }
                
                # BUG-33: Ask for extra parameters based on action
                if ($action -ieq 'Move') {
                    $targetOu = Read-Host "Enter Target OU for Move"
                    $manageArgs['TargetOU'] = $targetOu
                }
                elseif ($action -ieq 'Terminate') {
                    $targetOu = Read-Host "Enter Target OU for Terminate (Optional, leave blank to just disable)"
                    if ($targetOu) { $manageArgs['TargetOU'] = $targetOu }
                    $reason = Read-Host "Enter Termination Reason (Optional)"
                    if ($reason) { $manageArgs['Reason'] = $reason }
                }

                & (Join-Path -Path $rootDir -ChildPath 'Cmdlets\Manage-ADAutoXUser.ps1') @manageArgs
            }
            Read-Host "`nPress Enter to return to menu..."
        }
        '6' {
            Write-Host "`n[Reset / Teardown Lab Environment]" -ForegroundColor Red
            
            # BUG-32: Ask for OU name and offer WhatIf preview
            $ouName = Read-Host "Enter the name of the root Company OU to delete (Default: Company)"
            if ([string]::IsNullOrWhiteSpace($ouName)) { $ouName = 'Company' }
            
            Write-Host "Previewing deletion..." -ForegroundColor Yellow
            & (Join-Path -Path $rootDir -ChildPath 'Cmdlets\Reset-ADAutoXEnvironment.ps1') -CompanyOuName $ouName -WhatIf

            Write-Host "`nThis operation will RECURSIVELY DELETE the entire '$ouName' OU structure and all users, groups, and OUs inside it." -ForegroundColor Red
            
            $confirm = Read-Host "Type exactly '$ouName' to confirm deletion"
            if ($confirm -ceq $ouName) {
                & (Join-Path -Path $rootDir -ChildPath 'Cmdlets\Reset-ADAutoXEnvironment.ps1') -CompanyOuName $ouName -AllowDestructiveOperation
            }
            else {
                Write-Host "Reset cancelled. (Tip: type exactly the OU name to confirm.)" -ForegroundColor Yellow
            }
            Read-Host "`nPress Enter to return to menu..."
        }
        '7' {
            Write-Host "`n[Running ADAutoX Unit Test Suite]" -ForegroundColor Magenta
            & (Join-Path -Path $rootDir -ChildPath 'Tests\Run-Tests.ps1')
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
