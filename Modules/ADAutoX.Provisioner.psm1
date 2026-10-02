Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Ledger = [System.Collections.Generic.List[psobject]]::new()

function Get-ADAutoXLedgerFilePath {
    # Persistent pending ledger path so subsequent processes/sessions can recover crashed runs (Claude design finding)
    $tempDir = [System.IO.Path]::GetTempPath()
    return Join-Path -Path $tempDir -ChildPath 'ADAutoX-Pending-Ledger.json'
}

function Save-ADAutoXLedgerToDisk {
    [CmdletBinding()]
    param()
    try {
        $ledgerPath = Get-ADAutoXLedgerFilePath
        if ($null -eq $script:Ledger -or $script:Ledger.Count -eq 0) {
            if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
                Remove-Item -LiteralPath $ledgerPath -Force -ErrorAction SilentlyContinue
            }
            return
        }
        $json = $script:Ledger.ToArray() | ConvertTo-Json -Depth 5
        Set-Content -Path $ledgerPath -Value $json -Encoding UTF8 -Force
    }
    catch {
        Write-Verbose "[ADAutoX.Provisioner] Best-effort ledger save failed (disk full or locked): $($_.Exception.Message)"
    }
}

function Import-ADAutoXLedgerFromDisk {
    [CmdletBinding()]
    param()
    $ledgerPath = Get-ADAutoXLedgerFilePath
    if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
        try {
            $json = Get-Content -LiteralPath $ledgerPath -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($json)) {
                $items = @($json | ConvertFrom-Json)
                $script:Ledger.Clear()
                foreach ($item in $items) {
                    if ($null -ne $item) {
                        $script:Ledger.Add($item)
                    }
                }
                if ($script:Ledger.Count -gt 0) {
                    Write-ADAutoXConsole -Message "Recovered crash-recovery ledger from disk ($($script:Ledger.Count) entries). Review before proceeding." -Level Warning
                }
            }
        }
        catch {
            Write-Verbose "[ADAutoX.Provisioner] Could not read crash-recovery ledger from disk: $($_.Exception.Message)"
        }
    }
}

function Initialize-ADAutoXLedger {
    [CmdletBinding()]
    param(
        # When set, attempts to recover a crash-recovery ledger from a previous failed run.
        [switch]$RecoverFromCrash
    )

    $ledgerPath = Get-ADAutoXLedgerFilePath

    if ($null -eq $script:Ledger) {
        $script:Ledger = [System.Collections.Generic.List[psobject]]::new()
    }

    if ($RecoverFromCrash -and (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
        Import-ADAutoXLedgerFromDisk
    }
    else {
        $script:Ledger.Clear()
        if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
            Remove-Item -LiteralPath $ledgerPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ADAutoXLedger {
    [CmdletBinding()]
    param()
    if ($null -eq $script:Ledger) {
        return @()
    }
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

    if ($null -eq $script:Ledger) {
        $script:Ledger = [System.Collections.Generic.List[psobject]]::new()
    }

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

    # If in-memory ledger is empty, attempt to recover from crash-recovery file
    if ($null -eq $script:Ledger -or $script:Ledger.Count -eq 0) {
        Import-ADAutoXLedgerFromDisk
    }

    $createdItems = @($script:Ledger | Where-Object { $_.CreatedByThisRun -eq $true })
    if ($createdItems.Count -eq 0) {
        Write-ADAutoXConsole -Message 'Rollback ledger is empty. No created objects to remove.' -Level Warning
        return
    }

    Write-ADAutoXConsole -Message "Initiating transactional rollback for $($createdItems.Count) created resources..." -Level Warning

    # Delete users first, then groups, then OUs in deepest-first depth order (Bug #2 rollback)
    $users = @($createdItems | Where-Object { $_.ObjectType -eq 'User' })
    foreach ($user in $users) {
        if ($PSCmdlet.ShouldProcess($user.DistinguishedName, 'Remove-ADUser Rollback')) {
            try {
                if (Get-Command Remove-ADUser -ErrorAction SilentlyContinue) {
                    Remove-ADUser -Identity $user.DistinguishedName -Confirm:$false -ErrorAction Stop
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

    # Bug #2: Sort OUs deepest-first by DN depth to avoid "parent already deleted" errors.
    # Deeper DNs have more commas, so sort descending by comma-count.
    $ous = @($createdItems | Where-Object { $_.ObjectType -eq 'OU' } |
             Sort-Object -Property {
                 if ($_.DistinguishedName) {
                     return ([regex]::Matches($_.DistinguishedName, ',')).Count
                 }
                 return 0
             } -Descending)

    foreach ($ou in $ous) {
        if ($PSCmdlet.ShouldProcess($ou.DistinguishedName, 'Remove-ADOrganizationalUnit Rollback')) {
            try {
                if (Get-Command Remove-ADOrganizationalUnit -ErrorAction SilentlyContinue) {
                    # Check if the OU still exists (parent recursive delete may have already removed it)
                    $ouStillExists = Get-ADOrganizationalUnit -Identity $ou.DistinguishedName -ErrorAction SilentlyContinue
                    if ($null -ne $ouStillExists) {
                        Set-ADOrganizationalUnit -Identity $ou.DistinguishedName -ProtectedFromAccidentalDeletion $false -ErrorAction Stop
                        Remove-ADOrganizationalUnit -Identity $ou.DistinguishedName -Recursive -Confirm:$false -ErrorAction Stop
                        Write-ADAutoXConsole -Message "Rolled back OU: $($ou.DistinguishedName)" -Level Success
                        if ($LogPath) {
                            Write-ADAutoXLogRecord -LogPath $LogPath -Action 'RollbackOU' -Target $ou.DistinguishedName -Status 'Succeeded' -Message 'OU removed during rollback.'
                        }
                    }
                    else {
                        Write-ADAutoXConsole -Message "OU '$($ou.DistinguishedName)' already removed (parent deleted). Skipping." -Level Info
                    }
                }
                else {
                    Write-ADAutoXConsole -Message "Skipped rolling back OU '$($ou.DistinguishedName)': Cmdlet not available." -Level Warning
                }
            }
            catch {
                Write-ADAutoXConsole -Message "Failed to rollback OU '$($ou.DistinguishedName)': $($_.Exception.Message)" -Level Error
            }
        }
    }

    Initialize-ADAutoXLedger
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

        # NetBIOSName is passed from the calling context for future use (e.g. UPN suffix validation)
        [string]$NetBIOSName = '',

        # All names to check for collisions, not just first 20
        [string[]]$SampleNames = @()
    )

    Write-ADAutoXConsole -Message 'Phase 1: Preflight Validation (Non-mutating)' -Level Phase
    # $NetBIOSName is retained for forward-compatibility (callers pass it; will be used for UPN suffix validation in a future release)
    $null = $NetBIOSName
    $checks = [System.Collections.Generic.List[psobject]]::new()

    # If RSAT / Active Directory module cmdlets are not present on local machine, simulate preflight
    if (-not (Get-Command -Name Get-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
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

    # 1. Check Root Company OU (Bug #Minor: use Stop not SilentlyContinue to surface real errors)
    $safeCompanyFilter = ConvertTo-ADLdapFilter -Value $CompanyOuName
    try {
        $companyOUs = @(Get-ADOrganizationalUnit -LDAPFilter "(ou=$safeCompanyFilter)" -SearchBase $DomainDN -SearchScope OneLevel -ErrorAction Stop)
    }
    catch {
        throw "Preflight: Failed to query Company OU in '$DomainDN'. Check connectivity and permissions. Error: $($_.Exception.Message)"
    }
    $companyExists = $companyOUs.Count -gt 0

    $checks.Add([pscustomobject]@{
        Name    = 'Company OU'
        Status  = if ($companyExists) { 'Passed' } else { 'NeedsAttention' }
        Details = if ($companyExists) { "Root OU '$CompanyOuName' already exists in AD (will not be created/ledgered)." } else { "Root OU '$CompanyOuName' does not exist; will be created." }
    })

    # 2. Check Staff OU
    $staffExists = $false
    $safeCompanyValue = ConvertTo-ADDistinguishedNameValue -Value $CompanyOuName
    $safeStaffValue   = ConvertTo-ADDistinguishedNameValue -Value $StaffOuName
    $companyDN = "OU=$safeCompanyValue,$DomainDN"
    $staffDN   = "OU=$safeStaffValue,$companyDN"

    if ($companyExists) {
        $safeStaffFilter = ConvertTo-ADLdapFilter -Value $StaffOuName
        try {
            $staffOUs = @(Get-ADOrganizationalUnit -LDAPFilter "(ou=$safeStaffFilter)" -SearchBase $companyOUs[0].DistinguishedName -SearchScope OneLevel -ErrorAction Stop)
            $staffExists = $staffOUs.Count -gt 0
        }
        catch {
            throw "Preflight: Failed to query Staff OU. Error: $($_.Exception.Message)"
        }
    }
    $checks.Add([pscustomobject]@{
        Name    = 'Staff OU'
        Status  = if ($staffExists) { 'Passed' } else { 'NeedsAttention' }
        Details = if ($staffExists) { "Staff OU '$StaffOuName' already exists in AD." } else { "Staff OU '$StaffOuName' will be created." }
    })

    # 3. Check Department OUs & Groups
    foreach ($dept in $Departments) {
        $safeDeptFilter = ConvertTo-ADLdapFilter -Value $dept

        # Bug #1 (StrictMode crash): wrap conditional result in @() to guarantee array, never $null
        $deptOUs = @(
            if ($staffExists) {
                try {
                    Get-ADOrganizationalUnit -LDAPFilter "(ou=$safeDeptFilter)" -SearchBase $staffDN -SearchScope OneLevel -ErrorAction Stop
                }
                catch {
                    Write-Verbose "[ADAutoX.Provisioner] Department OU '$dept' not found in AD (will be created in Phase 2)."
                }
            }
        )
        $deptExists = $deptOUs.Count -gt 0

        $checks.Add([pscustomobject]@{
            Name    = "Department OU: $dept"
            Status  = if ($deptExists) { 'Passed' } else { 'NeedsAttention' }
            Details = if ($deptExists) { "Department OU '$dept' exists." } else { "Department OU '$dept' will be created." }
        })

        # Bug #Minor: Group lookups must use a PowerShell -Filter, not LDAP escaped values
        $deptUserGroupSam = "$dept-Users"
        try {
            $groupObj = Get-ADGroup -Filter "SamAccountName -eq '$deptUserGroupSam'" -ErrorAction Stop
        }
        catch {
            $groupObj = $null
        }
        $groupExists = $null -ne $groupObj

        $checks.Add([pscustomobject]@{
            Name    = "Department Group: $deptUserGroupSam"
            Status  = if ($groupExists) { 'Passed' } else { 'NeedsAttention' }
            Details = if ($groupExists) { "Security Group '$deptUserGroupSam' exists." } else { "Security Group '$deptUserGroupSam' will be created." }
        })
    }

    # 4. Check potential user SAM account collisions (all names, not just first 20 - Bug #Minor)
    $collisionCount = 0
    foreach ($name in $SampleNames) {
        $parts = $name.Trim() -split '\s+', 2
        $baseSam = if ($parts.Count -eq 2) { "$($parts[0]).$($parts[1])" } else { $parts[0] }

        # Bug #Minor: collision check uses same sanitizer as real provisioner for consistency
        try {
            $sanitizedSam = Get-ADSanitizedSamAccountName -BaseName $baseSam
        }
        catch {
            continue
        }

        try {
            $existingUser = Get-ADUser -Filter "SamAccountName -eq '$sanitizedSam'" -ErrorAction Stop
        }
        catch {
            $existingUser = $null
        }

        if ($null -ne $existingUser) {
            $collisionCount++
            $checks.Add([pscustomobject]@{
                Name    = "User Collision Check: $sanitizedSam"
                Status  = 'CollisionWarning'
                Details = "User '$sanitizedSam' already exists in AD. Provisioner will skip creation and not add to ledger."
            })
        }
    }

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

Export-ModuleMember -Function Initialize-ADAutoXLedger, `
                              Get-ADAutoXLedger, `
                              Add-ADAutoXLedgerEntry, `
                              Invoke-ADAutoXLedgerRollback, `
                              Invoke-ADAutoXPreflight
