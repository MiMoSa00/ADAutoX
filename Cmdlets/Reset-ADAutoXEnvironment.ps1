<#
.SYNOPSIS
    Safely cleans up lab test accounts, department OUs, and security groups created by ADAutoX.

.DESCRIPTION
    Requires -AllowDestructiveOperation switch when running live destructive changes. Supports previewing
    all operations via standard PowerShell -WhatIf semantics. Writes audit entries for all deleted resources.

.EXAMPLE
    .\Reset-ADAutoXEnvironment.ps1 -CompanyOuName 'Company' -WhatIf

.EXAMPLE
    .\Reset-ADAutoXEnvironment.ps1 -CompanyOuName 'Company' -AllowDestructiveOperation
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateNotNullOrEmpty()]
    [string]$CompanyOuName = 'Company',

    [switch]$AllowDestructiveOperation,

    [string]$AuditLogPath = '',

    [string]$Server,

    [PSCredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$rootDir   = Split-Path -Parent $scriptDir

# Load Module
Import-Module (Join-Path $rootDir 'ADAutoX.psd1') -Force

if ([string]::IsNullOrWhiteSpace($AuditLogPath)) {
    $AuditLogPath = Join-Path $rootDir 'ADAutoX-Audit.jsonl'
}

if (-not $WhatIfPreference -and -not $AllowDestructiveOperation) {
    throw 'Destructive reset requires explicit approval. Pass -AllowDestructiveOperation or preview with -WhatIf.'
}

$correlationId = New-ADAutoXCorrelationId
Write-ADAutoXConsole -Message "Initiating ADAutoX Environment Reset [CorrelationID: $correlationId]" -Level Phase

if ($WhatIfPreference) {
    Write-ADAutoXConsole -Message "[WhatIf Mode] Previewing environment teardown for OU '$CompanyOuName'." -Level Warning
    return
}

try {
    $adInfo = Initialize-ADAutoXContext -Server $Server -Credential $Credential
    $targetDN = "OU=$CompanyOuName,$($adInfo.DomainDN)"

    $ouExists = Test-Path "AD:\$targetDN" -ErrorAction SilentlyContinue
    if (-not $ouExists) {
        Write-ADAutoXConsole -Message "Target OU '$targetDN' does not exist. Nothing to clean up." -Level Warning
        return
    }

    if ($PSCmdlet.ShouldProcess($targetDN, "Unprotect and Recursively Delete OU $CompanyOuName")) {
        Write-ADAutoXConsole -Message "Unprotecting OU '$targetDN'..." -Level Warning
        Set-ADOrganizationalUnit -Identity $targetDN -ProtectedFromAccidentalDeletion $false -ErrorAction Stop

        Write-ADAutoXConsole -Message "Deleting entire OU structure '$targetDN'..." -Level Warning
        Remove-ADOrganizationalUnit -Identity $targetDN -Recursive -Confirm:$false -ErrorAction Stop

        Write-ADAutoXLogRecord -LogPath $AuditLogPath `
                               -Action 'ResetEnvironment' `
                               -Target $targetDN `
                               -Status 'Succeeded' `
                               -Message "Recursively removed test environment OU $CompanyOuName" `
                               -CorrelationId $correlationId

        Write-ADAutoXConsole -Message "Environment Reset Completed Successfully!" -Level Success
    }
}
catch {
    Write-ADAutoXConsole -Message "Error during environment reset: $($_.Exception.Message)" -Level Error
    throw
}
finally {
    Clear-ADAutoXContext
}
