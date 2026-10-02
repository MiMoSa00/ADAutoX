Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Ledger = [System.Collections.Generic.List[psobject]]::new()
$script:LedgerRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ADAutoX'
$script:LedgerFilePath = Join-Path $script:LedgerRoot 'pending-ledger.json'

function Get-ADAutoXLedgerStatePath {
    [CmdletBinding()]
    param()
    if (-not (Test-Path -LiteralPath $script:LedgerRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $script:LedgerRoot -Force | Out-Null
    }
    return $script:LedgerFilePath
}

function Save-ADAutoXLedgerToDisk {
    [CmdletBinding()]
    param()
    try {
        $ledgerPath = Get-ADAutoXLedgerStatePath
        $json = $script:Ledger | ConvertTo-Json -Depth 5
        Set-Content -Path $ledgerPath -Value $json -Encoding UTF8 -Force
    }
    catch {
        throw "Failed to persist the rollback ledger to disk: $($_.Exception.Message)"
    }
}

function Load-ADAutoXLedgerFromDisk {
    [CmdletBinding()]
    param()
    $ledgerPath = Get-ADAutoXLedgerStatePath
    if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
        try {
            $json = Get-Content -LiteralPath $ledgerPath -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($json)) {
                $items = $json | ConvertFrom-Json
                $script:Ledger.Clear()
                foreach ($item in @($items)) {
                    $script:Ledger.Add($item)
                }
            }
        }
        catch {
            throw "Failed to read the persisted rollback ledger from '$ledgerPath': $($_.Exception.Message)"
        }
    }
}

function Test-ADAutoXPendingLedger {
    [CmdletBinding()]
    param()
    $ledgerPath = Get-ADAutoXLedgerStatePath
    if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { return $false }
    try {
        $json = Get-Content -LiteralPath $ledgerPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($json)) { return $false }
        $items = @($json | ConvertFrom-Json)
        return $items.Count -gt 0
    }
    catch {
        throw "The persisted rollback ledger at '$ledgerPath' is unreadable. Resolve or inspect it before starting another provisioning run: $($_.Exception.Message)"
    }
}

function Complete-ADAutoXLedger {
    [CmdletBinding()]
    param()

    $ledgerPath = Get-ADAutoXLedgerStatePath
    if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
        Remove-Item -LiteralPath $ledgerPath -Force -ErrorAction Stop
    }
    $script:Ledger.Clear()
}

function Initialize-ADAutoXLedger {
    [CmdletBinding()]
    param(
        [switch]$DiscardPendingLedger
    )

    $ledgerPath = Get-ADAutoXLedgerStatePath
    if ($DiscardPendingLedger -and (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
        Remove-Item -LiteralPath $ledgerPath -Force -ErrorAction SilentlyContinue
    }

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

    Save-ADAutoXLedgerToDisk
}

function Invoke-ADAutoXLedgerRollback {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$LogPath = ''
    )

    # If in-memory ledger is empty, attempt to recover ledger from disk (crash resilience)
    if ($script:Ledger.Count -eq 0) {
        Load-ADAutoXLedgerFromDisk
    }

    $createdItems = @($script:Ledger | Where-Object { $_.CreatedByThisRun -eq $true })
    if ($createdItems.Count -eq 0) {
        Write-ADAutoXConsole -Message 'Rollback ledger is empty. No created objects to remove.' -Level Warning
        return
    }

    Write-ADAutoXConsole -Message "Initiating transactional rollback for $($createdItems.Count) created resources..." -Level Warning
    $removedDistinguishedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Delete users first, then groups, then OUs (reverse hierarchy order)
    $users = @($createdItems | Where-Object { $_.ObjectType -eq 'User' })
    foreach ($user in $users) {
        if ($PSCmdlet.ShouldProcess($user.DistinguishedName, 'Remove-ADUser Rollback')) {
            try {
                if (Get-Command Remove-ADUser -ErrorAction SilentlyContinue) {
                    Remove-ADUser -Identity $user.DistinguishedName -Confirm:$false -ErrorAction Stop
                    [void]$removedDistinguishedNames.Add($user.DistinguishedName)
                    Write-ADAutoXConsole -Message "Rolled back User: $($user.SamAccountName)" -Level Success
                    if ($LogPath) {
                        Write-ADAutoXLogRecord -LogPath $LogPath -Action 'RollbackUser' -Target $user.DistinguishedName -Status 'Succeeded' -Message 'User account removed during rollback.'
                    }
                }
                else {
                    Write-ADAutoXConsole -Message "Skipped rolling back User '$($user.SamAccountName)': Cmdlet 'Remove-ADUser' not available." -Level Warning
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
                    [void]$removedDistinguishedNames.Add($group.DistinguishedName)
                    Write-ADAutoXConsole -Message "Rolled back Group: $($group.SamAccountName)" -Level Success
                    if ($LogPath) {
                        Write-ADAutoXLogRecord -LogPath $LogPath -Action 'RollbackGroup' -Target $group.DistinguishedName -Status 'Succeeded' -Message 'Group removed during rollback.'
                    }
                }
                else {
                    Write-ADAutoXConsole -Message "Skipped rolling back Group '$($group.SamAccountName)': Cmdlet 'Remove-ADGroup' not available." -Level Warning
                }
            }
            catch {
                Write-ADAutoXConsole -Message "Failed to rollback Group '$($group.SamAccountName)': $($_.Exception.Message)" -Level Error
            }
        }
    }

    $ous = @(
        ($createdItems | Where-Object { $_.ObjectType -eq 'OU' } |
        Sort-Object {
            @($_.DistinguishedName -split ',').Count
        } -Descending)
    )

    foreach ($ou in $ous) {
        if ($PSCmdlet.ShouldProcess($ou.DistinguishedName, 'Remove-ADOrganizationalUnit Rollback')) {
            try {
                if (Get-Command Remove-ADOrganizationalUnit -ErrorAction SilentlyContinue) {
                    Set-ADOrganizationalUnit -Identity $ou.DistinguishedName -ProtectedFromAccidentalDeletion $false -ErrorAction Stop
                    Remove-ADOrganizationalUnit -Identity $ou.DistinguishedName -Confirm:$false -ErrorAction Stop
                    [void]$removedDistinguishedNames.Add($ou.DistinguishedName)
                    Write-ADAutoXConsole -Message "Rolled back OU: $($ou.DistinguishedName)" -Level Success
                    if ($LogPath) {
                        Write-ADAutoXLogRecord -LogPath $LogPath -Action 'RollbackOU' -Target $ou.DistinguishedName -Status 'Succeeded' -Message 'OU removed during rollback.'
                    }
                }
                else {
                    Write-ADAutoXConsole -Message "Skipped rolling back OU '$($ou.DistinguishedName)': Cmdlet 'Remove-ADOrganizationalUnit' not available." -Level Warning
                }
            }
            catch {
                Write-ADAutoXConsole -Message "Failed to rollback OU '$($ou.DistinguishedName)': $($_.Exception.Message)" -Level Error
            }
        }
    }

    $remainingItems = @($createdItems | Where-Object { -not $removedDistinguishedNames.Contains($_.DistinguishedName) })
    $script:Ledger.Clear()
    foreach ($item in $remainingItems) {
        $script:Ledger.Add($item)
    }
    if ($remainingItems.Count -eq 0) {
        Complete-ADAutoXLedger
    }
    else {
        Save-ADAutoXLedgerToDisk
        Write-ADAutoXConsole -Message "Rollback incomplete; $($remainingItems.Count) ledger entries remain for recovery." -Level Warning
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
        [string]$NetBIOSName,

        [string[]]$SampleNames = @()
    )

    Write-ADAutoXConsole -Message 'Phase 1: Preflight Validation (Non-mutating)' -Level Phase
    $checks = [System.Collections.Generic.List[psobject]]::new()

    # If RSAT / Active Directory module cmdlets are not present on local machine, simulate preflight
    if (-not (Get-Command Get-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
        Write-ADAutoXConsole -Message "[Offline/Preview] Active Directory module not present locally. Simulating preflight checks." -Level Warning
        $checks.Add([pscustomobject]@{
            Name    = 'Company OU'
            Status  = 'NeedsAttention'
            Details = "Company OU '$CompanyOuName' will be evaluated during Phase 2."
        })
        $checks.Add([pscustomobject]@{
            Name    = 'Staff OU'
            Status  = 'NeedsAttention'
            Details = "Staff OU '$StaffOuName' will be evaluated during Phase 2."
        })
        foreach ($dept in $Departments) {
            $checks.Add([pscustomobject]@{
                Name    = "Department Structure: $dept"
                Status  = 'NeedsAttention'
                Details = "Department OU '$dept' will be evaluated during Phase 2."
            })
        }
        $summary = [pscustomobject]@{
            PassedCount         = 0
            NeedsAttentionCount = $checks.Count
            CollisionCount      = 0
            Checks              = $checks.ToArray()
        }
        Write-ADAutoXConsole -Message "Preflight completed: $($summary.NeedsAttentionCount) pending creation/validation." -Level Info
        return $summary
    }

    # 1. Check Root Company OU
    $safeCompanyFilter = ConvertTo-ADLdapFilter -Value $CompanyOuName
    try {
        $companyOUs = @(Get-ADOrganizationalUnit -LDAPFilter "(ou=$safeCompanyFilter)" -SearchBase $DomainDN -SearchScope OneLevel -ErrorAction Stop)
    }
    catch {
        throw "Preflight failed while checking the root company OU '$CompanyOuName': $($_.Exception.Message)"
    }
    $companyExists = $companyOUs.Count -gt 0

    $checks.Add([pscustomobject]@{
        Name    = 'Company OU'
        Status  = if ($companyExists) { 'Passed' } else { 'NeedsAttention' }
        Details = if ($companyExists) { "Root OU '$CompanyOuName' already exists in AD (will not be created/ledgered)." } else { "Root OU '$CompanyOuName' does not exist; will be created." }
    })

    # 2. Check Staff OU
    $staffExists = $false
    if ($companyExists) {
        $safeStaffFilter = ConvertTo-ADLdapFilter -Value $StaffOuName
        try {
            $staffOUs = @(Get-ADOrganizationalUnit -LDAPFilter "(ou=$safeStaffFilter)" -SearchBase $companyOUs[0].DistinguishedName -SearchScope OneLevel -ErrorAction Stop)
        }
        catch {
            throw "Preflight failed while checking the Staff OU '$StaffOuName': $($_.Exception.Message)"
        }
        $staffExists = $staffOUs.Count -gt 0
    }
    $checks.Add([pscustomobject]@{
        Name    = 'Staff OU'
        Status  = if ($staffExists) { 'Passed' } else { 'NeedsAttention' }
        Details = if ($staffExists) { "Staff OU '$StaffOuName' already exists in AD." } else { "Staff OU '$StaffOuName' will be created." }
    })

    # 3. Check Department OUs & Groups
    $companyDN = "OU=$(ConvertTo-ADDistinguishedNameValue -Value $CompanyOuName),$DomainDN"
    $staffDN   = "OU=$(ConvertTo-ADDistinguishedNameValue -Value $StaffOuName),$companyDN"

    foreach ($dept in $Departments) {
        $safeDeptFilter = ConvertTo-ADLdapFilter -Value $dept
        try {
            $deptOUs = @(if ($staffExists) { Get-ADOrganizationalUnit -LDAPFilter "(ou=$safeDeptFilter)" -SearchBase $staffDN -SearchScope OneLevel -ErrorAction Stop })
        }
        catch {
            throw "Preflight failed while checking the department OU '$dept': $($_.Exception.Message)"
        }
        $deptExists = $deptOUs.Count -gt 0

        $checks.Add([pscustomobject]@{
            Name    = "Department OU: $dept"
            Status  = if ($deptExists) { 'Passed' } else { 'NeedsAttention' }
            Details = if ($deptExists) { "Department OU '$dept' exists." } else { "Department OU '$dept' will be created." }
        })

        # Check Department Groups
        $userGroupSam = "$dept-Users"
        $safeGroupFilter = ConvertTo-ADLdapFilter -Value $userGroupSam
        $groupObj = Get-ADGroup -LDAPFilter "(samAccountName=$safeGroupFilter)" -ErrorAction Stop
        $groupExists = $null -ne $groupObj

        $checks.Add([pscustomobject]@{
            Name    = "Department Group: $userGroupSam"
            Status  = if ($groupExists) { 'Passed' } else { 'NeedsAttention' }
            Details = if ($groupExists) { "Security Group '$userGroupSam' exists." } else { "Security Group '$userGroupSam' will be created." }
        })
    }

    # 4. Check potential user SAM account collisions
    $collisionCount = 0
    if ($SampleNames.Count -gt 0) {
        $preflightUsedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in $SampleNames) {
            $nameTokens = @($name.Trim() -split '\s+', 2)
            $baseSam = if ($nameTokens.Count -gt 1) { "$($nameTokens[0]).$($nameTokens[1])" } else { $nameTokens[0] }
            $sanitizedSam = Get-ADSanitizedSamAccountName -BaseName $baseSam -UsedNames $preflightUsedNames
            $safeSamFilter = ConvertTo-ADLdapFilter -Value $sanitizedSam
            $existingUser = Get-ADUser -LDAPFilter "(samAccountName=$safeSamFilter)" -ErrorAction Stop
            if ($null -ne $existingUser) {
                $collisionCount++
                $checks.Add([pscustomobject]@{
                    Name    = "User Collision Check: $sanitizedSam"
                    Status  = 'CollisionWarning'
                    Details = "User '$sanitizedSam' already exists in AD. Provisioner will append a unique numerical suffix or skip."
                })
            }
        }
    }

    # This check uses the same sanitizer as the provisioner, so it remains aligned with real-world AD naming.

    $passedCount         = @($checks | Where-Object { $_.Status -eq 'Passed' }).Count
    $needsAttentionCount = @($checks | Where-Object { $_.Status -eq 'NeedsAttention' }).Count

    $summary = [pscustomobject]@{
        PassedCount         = $passedCount
        NeedsAttentionCount = $needsAttentionCount
        CollisionCount      = $collisionCount
        Checks              = $checks.ToArray()
    }

    Write-ADAutoXConsole -Message "Preflight completed: $passedCount existing resources verified, $needsAttentionCount pending creation, $collisionCount collision warnings." -Level Info
    return $summary
}

Export-ModuleMember -Function Test-ADAutoXPendingLedger, `
                              Complete-ADAutoXLedger, `
                              Initialize-ADAutoXLedger, `
                              Get-ADAutoXLedger, `
                              Add-ADAutoXLedgerEntry, `
                              Invoke-ADAutoXLedgerRollback, `
                              Invoke-ADAutoXPreflight
