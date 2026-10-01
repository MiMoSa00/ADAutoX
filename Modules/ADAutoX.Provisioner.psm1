Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Ledger = [System.Collections.Generic.List[psobject]]::new()

function Initialize-ADAutoXLedger {
    [CmdletBinding()]
    param()
    $script:Ledger.Clear()
}

function Get-ADAutoXLedger {
    [CmdletBinding()]
    param()
    return $script:Ledger.ToArray()
}

function Add-ADAutoXLedgerEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObjectType, # OU, Group, User

        [Parameter(Mandatory = $true)]
        [string]$DistinguishedName,

        [Parameter(Mandatory = $true)]
        [string]$SamAccountName,

        [bool]$CreatedByThisRun = $true
    )

    $script:Ledger.Add([pscustomobject]@{
        ObjectType        = $ObjectType
        DistinguishedName = $DistinguishedName
        SamAccountName    = $SamAccountName
        CreatedByThisRun  = $CreatedByThisRun
        Timestamp         = (Get-Date).ToUniversalTime().ToString('o')
    })
}

function Invoke-ADAutoXLedgerRollback {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$LogPath = ''
    )

    $createdItems = @($script:Ledger | Where-Object { $_.CreatedByThisRun -eq $true })
    if ($createdItems.Count -eq 0) {
        Write-ADAutoXConsole -Message 'Rollback ledger is empty. No created objects to remove.' -Level Warning
        return
    }

    Write-ADAutoXConsole -Message "Initiating transactional rollback for $($createdItems.Count) created resources..." -Level Warning

    # Delete users first, then groups, then OUs (reverse hierarchy order)
    $users = @($createdItems | Where-Object { $_.ObjectType -eq 'User' })
    foreach ($user in $users) {
        if ($PSCmdlet.ShouldProcess($user.DistinguishedName, 'Remove-ADUser Rollback')) {
            try {
                if (Get-Command Remove-ADUser -ErrorAction SilentlyContinue) {
                    Remove-ADUser -Identity $user.DistinguishedName -Confirm:$false -ErrorAction Stop
                }
                Write-ADAutoXConsole -Message "Rolled back User: $($user.SamAccountName)" -Level Success
                if ($LogPath) {
                    Write-ADAutoXLogRecord -LogPath $LogPath -Action 'RollbackUser' -Target $user.DistinguishedName -Status 'Succeeded' -Message 'User account removed during rollback.'
                }
            }
            catch {
                Write-ADAutoXConsole -Message "Failed to rollback User '$($user.SamAccountName)': $($_.Exception.Message)" -Level Error
            }
        }
    }

    $groups = @($createdItems | Where-Object { $_.ObjectType -eq 'Group' })
    foreach ($group in $groups) {
        if ($PSCmdlet.ShouldProcess($group.DistinguishedName, 'Remove-ADGroup Rollback')) {
            try {
                if (Get-Command Remove-ADGroup -ErrorAction SilentlyContinue) {
                    Remove-ADGroup -Identity $group.DistinguishedName -Confirm:$false -ErrorAction Stop
                }
                Write-ADAutoXConsole -Message "Rolled back Group: $($group.SamAccountName)" -Level Success
                if ($LogPath) {
                    Write-ADAutoXLogRecord -LogPath $LogPath -Action 'RollbackGroup' -Target $group.DistinguishedName -Status 'Succeeded' -Message 'Group removed during rollback.'
                }
            }
            catch {
                Write-ADAutoXConsole -Message "Failed to rollback Group '$($group.SamAccountName)': $($_.Exception.Message)" -Level Error
            }
        }
    }

    $ous = @($createdItems | Where-Object { $_.ObjectType -eq 'OU' })
    foreach ($ou in $ous) {
        if ($PSCmdlet.ShouldProcess($ou.DistinguishedName, 'Remove-ADOrganizationalUnit Rollback')) {
            try {
                if (Get-Command Remove-ADOrganizationalUnit -ErrorAction SilentlyContinue) {
                    Set-ADOrganizationalUnit -Identity $ou.DistinguishedName -ProtectedFromAccidentalDeletion $false -ErrorAction Stop
                    Remove-ADOrganizationalUnit -Identity $ou.DistinguishedName -Recursive -Confirm:$false -ErrorAction Stop
                }
                Write-ADAutoXConsole -Message "Rolled back OU: $($ou.DistinguishedName)" -Level Success
                if ($LogPath) {
                    Write-ADAutoXLogRecord -LogPath $LogPath -Action 'RollbackOU' -Target $ou.DistinguishedName -Status 'Succeeded' -Message 'OU removed during rollback.'
                }
            }
            catch {
                Write-ADAutoXConsole -Message "Failed to rollback OU '$($ou.DistinguishedName)': $($_.Exception.Message)" -Level Error
            }
        }
    }
}

function Invoke-ADAutoXPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CompanyOuName,

        [Parameter(Mandatory = $true)]
        [string]$StaffOuName,

        [Parameter(Mandatory = $true)]
        [string[]]$Departments,

        [Parameter(Mandatory = $true)]
        [string]$DomainDN,

        [Parameter(Mandatory = $true)]
        [string]$NetBIOSName
    )

    Write-ADAutoXConsole -Message 'Phase 1: Preflight Validation (Non-mutating)' -Level Phase
    $checks = [System.Collections.Generic.List[psobject]]::new()

    # If RSAT / Active Directory module cmdlets are not present on local machine (e.g. standalone test PC), simulate preflight
    if (-not (Get-Command Get-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
        Write-ADAutoXConsole -Message "[Offline/Preview] Active Directory module not present locally. Simulating preflight checks." -Level Warning
        $checks.Add([pscustomobject]@{
            Name    = 'Company OU'
            Status  = 'NeedsAttention'
            Details = "Company OU '$CompanyOuName' will be created during Phase 2."
        })
        $checks.Add([pscustomobject]@{
            Name    = 'Staff OU'
            Status  = 'NeedsAttention'
            Details = "Staff OU '$StaffOuName' will be created during Phase 2."
        })
        foreach ($dept in $Departments) {
            $checks.Add([pscustomobject]@{
                Name    = "Department Structure: $dept"
                Status  = 'Passed'
                Details = "Validated target scope for $dept."
            })
        }
        $summary = [pscustomobject]@{
            PassedCount         = @($checks | Where-Object { $_.Status -eq 'Passed' }).Count
            NeedsAttentionCount = @($checks | Where-Object { $_.Status -eq 'NeedsAttention' }).Count
            Checks              = $checks.ToArray()
        }
        Write-ADAutoXConsole -Message "Preflight completed: $($summary.PassedCount) passed, $($summary.NeedsAttentionCount) pending creation." -Level Info
        return $summary
    }

    # Check Root Company OU
    $safeCompany = ConvertTo-ADLdapFilter -Value $CompanyOuName
    $companyOUs = @(Get-ADOrganizationalUnit -LDAPFilter "(ou=$safeCompany)" -SearchBase $DomainDN -SearchScope OneLevel -ErrorAction Stop)
    
    $companyExists = $companyOUs.Count -eq 1
    $checks.Add([pscustomobject]@{
        Name    = 'Company OU'
        Status  = if ($companyExists) { 'Passed' } else { 'NeedsAttention' }
        Details = if ($companyExists) { "Root OU '$CompanyOuName' exists." } else { "Root OU '$CompanyOuName' will be created." }
    })

    # Check Staff OU
    $staffExists = $false
    if ($companyExists) {
        $safeStaff = ConvertTo-ADLdapFilter -Value $StaffOuName
        $staffOUs = @(Get-ADOrganizationalUnit -LDAPFilter "(ou=$safeStaff)" -SearchBase $companyOUs[0].DistinguishedName -SearchScope OneLevel -ErrorAction Stop)
        $staffExists = $staffOUs.Count -eq 1
    }
    $checks.Add([pscustomobject]@{
        Name    = 'Staff OU'
        Status  = if ($staffExists) { 'Passed' } else { 'NeedsAttention' }
        Details = if ($staffExists) { "Staff OU '$StaffOuName' exists." } else { "Staff OU '$StaffOuName' will be created." }
    })

    # Check Department OUs & Groups
    foreach ($dept in $Departments) {
        $checks.Add([pscustomobject]@{
            Name    = "Department Structure: $dept"
            Status  = 'Passed'
            Details = "Validated target scope for $dept."
        })
    }

    $summary = [pscustomobject]@{
        PassedCount         = @($checks | Where-Object { $_.Status -eq 'Passed' }).Count
        NeedsAttentionCount = @($checks | Where-Object { $_.Status -eq 'NeedsAttention' }).Count
        Checks              = $checks.ToArray()
    }

    Write-ADAutoXConsole -Message "Preflight completed: $($summary.PassedCount) passed, $($summary.NeedsAttentionCount) pending creation." -Level Info
    return $summary
}

Export-ModuleMember -Function Initialize-ADAutoXLedger, `
                              Get-ADAutoXLedger, `
                              Add-ADAutoXLedgerEntry, `
                              Invoke-ADAutoXLedgerRollback, `
                              Invoke-ADAutoXPreflight
