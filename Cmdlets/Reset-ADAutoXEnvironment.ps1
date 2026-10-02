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

try {
    $adInfo = Initialize-ADAutoXContext -Server $Server -Credential $Credential
    $safeCompanyOuValue = ConvertTo-ADDistinguishedNameValue -Value $CompanyOuName
    $targetDN = "OU=$safeCompanyOuValue,$($adInfo.DomainDN)"

    if ($WhatIfPreference) {
        Write-ADAutoXConsole -Message "[WhatIf Mode] Previewing environment teardown for OU '$CompanyOuName'." -Level Warning
        $existingOu = Get-ADOrganizationalUnit -Identity $targetDN -ErrorAction SilentlyContinue
        if ($null -eq $existingOu) {
            Write-ADAutoXConsole -Message "Target OU '$targetDN' does not exist. Nothing to clean up." -Level Warning
            return
        }

        $counts = @(Get-ADObject -Filter * -SearchBase $targetDN)
        $userCount = @($counts | Where-Object { $_.ObjectClass -eq 'user' }).Count
        $groupCount = @($counts | Where-Object { $_.ObjectClass -eq 'group' }).Count
        $subOuCount = @($counts | Where-Object { $_.ObjectClass -eq 'organizationalUnit' }).Count

        Write-ADAutoXConsole -Message "[WhatIf Mode] OU '$CompanyOuName' contains $userCount users, $groupCount groups, and $subOuCount child OUs. No deletion will occur in preview mode." -Level Warning
        return
    }

    $ouExists = Test-Path "AD:\$targetDN" -ErrorAction SilentlyContinue
    if (-not $ouExists) {
        Write-ADAutoXConsole -Message "Target OU '$targetDN' does not exist. Nothing to clean up." -Level Warning
        return
    }

    if ($PSCmdlet.ShouldProcess($targetDN, "Unprotect and Recursively Delete OU $CompanyOuName")) {
        $allOUs = @()
        $queue = @($targetDN)
        while ($queue.Count -gt 0) {
            $currentDn = $queue[0]
            $queue = @($queue | Select-Object -Skip 1)
            $allOUs += $currentDn
            try {
                $childOus = @(Get-ADOrganizationalUnit -SearchBase $currentDn -Filter * -SearchScope OneLevel -ErrorAction Stop)
                foreach ($child in $childOus) {
                    $queue += $child.DistinguishedName
                }
            }
            catch {
                # No children found or access denied; continue safely to the next item.
            }
        }

        foreach ($ouDn in $allOUs) {
            try {
                Set-ADOrganizationalUnit -Identity $ouDn -ProtectedFromAccidentalDeletion $false -ErrorAction Stop
            }
            catch {
                Write-ADAutoXConsole -Message "Could not disable accidental deletion protection on '$ouDn': $($_.Exception.Message)" -Level Warning
            }
        }

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
