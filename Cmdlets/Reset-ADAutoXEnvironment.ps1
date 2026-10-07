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
Import-Module (Join-Path -Path $rootDir -ChildPath 'ADAutoX.psd1') -Force

if ([string]::IsNullOrWhiteSpace($AuditLogPath)) {
    $AuditLogPath = Join-Path -Path $rootDir -ChildPath 'ADAutoX-Audit.jsonl'
}

if (-not $WhatIfPreference -and -not $AllowDestructiveOperation) {
    throw 'Destructive reset requires explicit approval. Pass -AllowDestructiveOperation or preview with -WhatIf.'
}

$correlationId = New-ADAutoXCorrelationId
Write-ADAutoXConsole -Message "Initiating ADAutoX Environment Reset [CorrelationID: $correlationId]" -Level Phase

try {
    $adInfo = Initialize-ADAutoXContext -Server $Server -Credential $Credential

    # Bug #3 / #29: always sanitize the OU name before using it in a DN path
    $safeCompanyOuValue = ConvertTo-ADDistinguishedNameValue -Value $CompanyOuName
    $targetDN = "OU=$safeCompanyOuValue,$($adInfo.DomainDN)"

    if ($WhatIfPreference) {
        Write-ADAutoXConsole -Message "[WhatIf Mode] Checking target OU '$CompanyOuName' in domain '$($adInfo.DomainName)'..." -Level Warning

        # Bug #14: In WhatIf, actually connect and query what is inside the OU
        $existingOu = $null
        try {
            $existingOu = Get-ADOrganizationalUnit -Identity $targetDN -ErrorAction Stop
        }
        catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
            Write-ADAutoXConsole -Message "[WhatIf] Target OU '$targetDN' does not exist. Nothing to delete." -Level Warning
            return
        }
        catch {
            # Bug #29: don't swallow real connectivity errors as "nothing to clean up"
            throw "WhatIf preflight failed: Could not check target OU. Verify connectivity and permissions. Error: $($_.Exception.Message)"
        }

        $allObjects  = @(Get-ADObject -Filter * -SearchBase $targetDN -ErrorAction SilentlyContinue)
        $userCount   = @($allObjects | Where-Object { $_.ObjectClass -eq 'user' }).Count
        $groupCount  = @($allObjects | Where-Object { $_.ObjectClass -eq 'group' }).Count
        $subOuCount  = @($allObjects | Where-Object { $_.ObjectClass -eq 'organizationalUnit' }).Count

        Write-ADAutoXConsole -Message "[WhatIf] OU '$CompanyOuName' contains: $userCount user(s), $groupCount group(s), $subOuCount child OU(s). Live run would recursively delete all of them." -Level Warning
        return
    }

    # Bug #29: distinguish "doesn't exist" from genuine errors rather than swallowing both
    $ouExists = $false
    try {
        $null = Get-ADOrganizationalUnit -Identity $targetDN -ErrorAction Stop
        $ouExists = $true
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        $ouExists = $false
    }
    catch {
        throw "Failed to verify target OU existence. Check connectivity and permissions. Error: $($_.Exception.Message)"
    }

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
        
        # BUG-31: List and log each object before deletion
        try {
            $objectsToDelete = @(Get-ADObject -Filter * -SearchBase $targetDN -ErrorAction Stop | Sort-Object DistinguishedName -Descending)
            foreach ($obj in $objectsToDelete) {
                Write-ADAutoXLogRecord -LogPath $AuditLogPath `
                                       -Action 'DeleteObject' `
                                       -Target $obj.DistinguishedName `
                                       -TargetType $obj.ObjectClass `
                                       -Status 'Started' `
                                       -Message "Deleting $($obj.ObjectClass): $($obj.Name)" `
                                       -CorrelationId $correlationId
            }
        } catch {
            Write-ADAutoXConsole -Message "Could not enumerate objects for detailed audit logging: $($_.Exception.Message)" -Level Warning
        }

        Remove-ADOrganizationalUnit -Identity $targetDN -Recursive -Confirm:$false -ErrorAction Stop

        if ($null -ne $objectsToDelete) {
            foreach ($obj in $objectsToDelete) {
                Write-ADAutoXLogRecord -LogPath $AuditLogPath `
                                       -Action 'DeleteObject' `
                                       -Target $obj.DistinguishedName `
                                       -TargetType $obj.ObjectClass `
                                       -Status 'Succeeded' `
                                       -Message "Deleted $($obj.ObjectClass): $($obj.Name)" `
                                       -CorrelationId $correlationId
            }
        }

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
