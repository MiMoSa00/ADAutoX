Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Ledger = [System.Collections.Generic.List[psobject]]::new()
$script:LedgerRunId = ''
$script:LedgerCompanyDN = ''

# ---------------------------------------------------------------------------
# BUG-03 / BUG-18 — Ledger: per-user protected folder, per-run filename
# ---------------------------------------------------------------------------

function Get-ADAutoXLedgerDirectory {
    # Store the ledger in a per-user location, not the world-writable temp folder.
    if ($PSVersionTable.PSVersion.Major -ge 6 -and
        [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::Windows)) {
        $base = [System.Environment]::GetFolderPath('LocalApplicationData')
    }
    elseif ($PSVersionTable.PSVersion.Major -lt 6 -and $env:OS -like '*Windows*') {
        $base = [System.Environment]::GetFolderPath('LocalApplicationData')
    }
    else {
        # Linux / macOS — per-user home dir
        $base = [System.Environment]::GetFolderPath('UserProfile')
        if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:HOME }
    }
    $dir = Join-Path -Path $base -ChildPath '.adautox\ledgers'
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    return $dir
}

function Get-ADAutoXLedgerFilePath {
    param([string]$RunId = $script:LedgerRunId)
    $dir = Get-ADAutoXLedgerDirectory
    # BUG-18: one file per run (CorrelationId + PID), never shared between concurrent runs
    $safeid = $RunId -replace '[^a-zA-Z0-9\-]', '_'
    return Join-Path -Path $dir -ChildPath "ADAutoX-Ledger-$safeid.json"
}

function Get-ADAutoXLedgerHmac {
    <#
    .SYNOPSIS
        Returns a deterministic per-machine HMAC key derived from the current user's SID.
        Not a secret key for multi-user use; prevents accidental/casual tampering only.
    #>
    param([string]$Content)
    try {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    catch {
        $sid = [System.Environment]::UserName
    }
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($sid)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
    try {
        $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Content))
        return [System.Convert]::ToBase64String($hash)
    }
    finally {
        $hmac.Dispose()
    }
}

function Protect-ADAutoXLedgerFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $isWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or
                     [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
                         [System.Runtime.InteropServices.OSPlatform]::Windows)
        if ($isWindows) {
            $acl = Get-Acl -LiteralPath $Path
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
                $null = $acl.RemoveAccessRule($rule)
            }
            $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $currentSid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow)
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        }
        else {
            # chmod 600 on Linux/macOS
            & chmod 600 $Path 2>$null
        }
    }
    catch {
        Write-Verbose "[ADAutoX.Provisioner] Could not restrict ledger file permissions: $($_.Exception.Message)"
    }
}

function Save-ADAutoXLedgerToDisk {
    [CmdletBinding()]
    param()
    if ([string]::IsNullOrWhiteSpace($script:LedgerRunId)) { return }
    try {
        $ledgerPath = Get-ADAutoXLedgerFilePath
        if ($null -eq $script:Ledger -or $script:Ledger.Count -eq 0) {
            if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
                Remove-Item -LiteralPath $ledgerPath -Force -ErrorAction SilentlyContinue
            }
            return
        }
        $payload = [ordered]@{
            RunId     = $script:LedgerRunId
            CompanyDN = $script:LedgerCompanyDN
            Entries   = $script:Ledger.ToArray()
        }
        $json = $payload | ConvertTo-Json -Depth 6
        $hmac = Get-ADAutoXLedgerHmac -Content $json
        $wrapper = [ordered]@{ Hmac = $hmac; Payload = $json }
        $wrapperJson = $wrapper | ConvertTo-Json -Depth 2

        # Write to a temp file first, then move atomically (avoids partial writes)
        $tmpPath = "$ledgerPath.tmp"
        Set-Content -Path $tmpPath -Value $wrapperJson -Encoding UTF8 -Force
        Protect-ADAutoXLedgerFile -Path $tmpPath
        Move-Item -LiteralPath $tmpPath -Destination $ledgerPath -Force
    }
    catch {
        Write-Verbose "[ADAutoX.Provisioner] Best-effort ledger save failed: $($_.Exception.Message)"
    }
}

function Import-ADAutoXLedgerFromDisk {
    [CmdletBinding()]
    param([string]$RunId = $script:LedgerRunId)
    $ledgerPath = Get-ADAutoXLedgerFilePath -RunId $RunId
    if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { return }
    try {
        $wrapperJson = Get-Content -LiteralPath $ledgerPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($wrapperJson)) { return }
        $wrapper = $wrapperJson | ConvertFrom-Json
        if (-not $wrapper.Hmac -or -not $wrapper.Payload) {
            Write-ADAutoXConsole -Message 'Crash-recovery ledger has invalid structure — ignoring.' -Level Warning
            return
        }

        # BUG-03: Verify HMAC before trusting anything in the file
        $expectedHmac = Get-ADAutoXLedgerHmac -Content $wrapper.Payload
        if ($wrapper.Hmac -ne $expectedHmac) {
            Write-ADAutoXConsole -Message 'Crash-recovery ledger HMAC mismatch — file may have been tampered with. Ignoring.' -Level Warning
            return
        }

        $payload = $wrapper.Payload | ConvertFrom-Json
        $script:LedgerRunId   = $payload.RunId
        $script:LedgerCompanyDN = $payload.CompanyDN

        $items = @($payload.Entries)
        $script:Ledger.Clear()
        foreach ($item in $items) {
            if ($null -ne $item) { $script:Ledger.Add($item) }
        }
        if ($script:Ledger.Count -gt 0) {
            Write-ADAutoXConsole -Message "Recovered crash-recovery ledger from disk ($($script:Ledger.Count) entries, RunId=$($script:LedgerRunId))." -Level Warning
        }
    }
    catch {
        Write-Verbose "[ADAutoX.Provisioner] Could not read crash-recovery ledger: $($_.Exception.Message)"
    }
}

function Initialize-ADAutoXLedger {
    [CmdletBinding()]
    param(
        [switch]$RecoverFromCrash,
        [string]$RunId = '',
        # BUG-03: caller must supply the CompanyDN so rollback can validate DNs
        [string]$CompanyDN = ''
    )

    if ($null -eq $script:Ledger) {
        $script:Ledger = [System.Collections.Generic.List[psobject]]::new()
    }

    if ($RecoverFromCrash) {
        # Attempt to discover an orphaned ledger file from a prior run
        $ledgerDir = Get-ADAutoXLedgerDirectory
        $orphans = @(Get-ChildItem -Path $ledgerDir -Filter 'ADAutoX-Ledger-*.json' -ErrorAction SilentlyContinue)
        if ($orphans.Count -gt 0) {
            # Pick the most recent one
            $latest = $orphans | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $orphanRunId = $latest.Name -replace '^ADAutoX-Ledger-' -replace '\.json$'
            Import-ADAutoXLedgerFromDisk -RunId $orphanRunId
        }
    }
    else {
        $script:Ledger.Clear()
        # BUG-18: assign a fresh, unique run ID
        if ([string]::IsNullOrWhiteSpace($RunId)) {
            $script:LedgerRunId = "$([System.Guid]::NewGuid().ToString('N'))-$PID"
        }
        else {
            $script:LedgerRunId = $RunId
        }
        $script:LedgerCompanyDN = $CompanyDN

        # Clean up any pre-existing file for this run ID (shouldn't exist)
        $path = Get-ADAutoXLedgerFilePath
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ADAutoXLedger {
    [CmdletBinding()]
    param()
    if ($null -eq $script:Ledger) { return @() }
    return $script:Ledger.ToArray()
}

function Add-ADAutoXLedgerEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObjectType,

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
        RunId             = $script:LedgerRunId
        Timestamp         = (Get-Date).ToUniversalTime().ToString('o')
    })

    Save-ADAutoXLedgerToDisk
}

function Invoke-ADAutoXLedgerRollback {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$LogPath = '',
        # BUG-03: expected company DN — every object's DN must be a descendant
        [string]$ExpectedCompanyDN = ''
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

    # BUG-03: Determine the authoritative company DN
    $anchorDN = if (-not [string]::IsNullOrWhiteSpace($ExpectedCompanyDN)) {
        $ExpectedCompanyDN
    }
    elseif (-not [string]::IsNullOrWhiteSpace($script:LedgerCompanyDN)) {
        $script:LedgerCompanyDN
    }
    else { '' }

    # BUG-03: Validate that every DN actually sits under the company OU
    if (-not [string]::IsNullOrWhiteSpace($anchorDN)) {
        $invalid = @($createdItems | Where-Object {
            -not $_.DistinguishedName.EndsWith(",$anchorDN", [System.StringComparison]::OrdinalIgnoreCase) -and
            $_.DistinguishedName -ne $anchorDN
        })
        if ($invalid.Count -gt 0) {
            Write-ADAutoXConsole -Message "SECURITY: Rollback aborted — $($invalid.Count) ledger entry/entries are NOT under the expected OU '$anchorDN'. The ledger may have been tampered with:" -Level Error
            foreach ($item in $invalid) {
                Write-ADAutoXConsole -Message "  Suspicious DN: $($item.DistinguishedName)" -Level Error
            }
            throw "Rollback aborted: ledger contains entries outside the expected company OU boundary '$anchorDN'."
        }
    }

    Write-ADAutoXConsole -Message "Initiating rollback for $($createdItems.Count) created resources..." -Level Warning
    Write-ADAutoXConsole -Message "Objects to be removed:" -Level Warning
    foreach ($item in $createdItems) {
        Write-ADAutoXConsole -Message "  [$($item.ObjectType)] $($item.DistinguishedName)" -Level Warning
    }

    # BUG-04: Track which entries were actually deleted vs failed
    $deletedDNs   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $failureCount = 0
    $isWhatIf     = -not $PSCmdlet.ShouldProcess('RollbackCheck', 'Test-ShouldProcess-Sentinel')

    $users = @($createdItems | Where-Object { $_.ObjectType -eq 'User' })
    foreach ($user in $users) {
        if ($PSCmdlet.ShouldProcess($user.DistinguishedName, 'Remove-ADUser Rollback')) {
            try {
                if (Get-Command Remove-ADUser -ErrorAction SilentlyContinue) {
                    Remove-ADUser -Identity $user.DistinguishedName -Confirm:$false -ErrorAction Stop
                    Write-ADAutoXConsole -Message "Rolled back User: $($user.SamAccountName)" -Level Success
                    [void]$deletedDNs.Add($user.DistinguishedName)
                    if ($LogPath) {
                        Write-ADAutoXLogRecord -LogPath $LogPath -Action 'RollbackUser' -Target $user.DistinguishedName -Status 'Succeeded' -Message 'User account removed during rollback.'
                    }
                }
                else {
                    Write-ADAutoXConsole -Message "Skipped rolling back User '$($user.SamAccountName)': Cmdlet 'Remove-ADUser' not available." -Level Warning
                    $failureCount++
                }
            }
            catch {
                Write-ADAutoXConsole -Message "Failed to rollback User '$($user.SamAccountName)': $($_.Exception.Message)" -Level Error
                if ($LogPath) {
                    Write-ADAutoXLogRecord -LogPath $LogPath -Action 'RollbackUser' -Target $user.DistinguishedName -Status 'Failed' -Message $_.Exception.Message
                }
                $failureCount++
            }
        }
        # BUG-04: if ShouldProcess returned false (-WhatIf), do NOT modify the ledger
    }

    $groups = @($createdItems | Where-Object { $_.ObjectType -eq 'Group' })
    foreach ($group in $groups) {
        if ($PSCmdlet.ShouldProcess($group.DistinguishedName, 'Remove-ADGroup Rollback')) {
            try {
                if (Get-Command Remove-ADGroup -ErrorAction SilentlyContinue) {
                    Remove-ADGroup -Identity $group.DistinguishedName -Confirm:$false -ErrorAction Stop
                    Write-ADAutoXConsole -Message "Rolled back Group: $($group.SamAccountName)" -Level Success
                    [void]$deletedDNs.Add($group.DistinguishedName)
                    if ($LogPath) {
                        Write-ADAutoXLogRecord -LogPath $LogPath -Action 'RollbackGroup' -Target $group.DistinguishedName -Status 'Succeeded' -Message 'Group removed during rollback.'
                    }
                }
                else {
                    Write-ADAutoXConsole -Message "Skipped rolling back Group '$($group.SamAccountName)': Cmdlet 'Remove-ADGroup' not available." -Level Warning
                    $failureCount++
                }
            }
            catch {
                Write-ADAutoXConsole -Message "Failed to rollback Group '$($group.SamAccountName)': $($_.Exception.Message)" -Level Error
                if ($LogPath) {
                    Write-ADAutoXLogRecord -LogPath $LogPath -Action 'RollbackGroup' -Target $group.DistinguishedName -Status 'Failed' -Message $_.Exception.Message
                }
                $failureCount++
            }
        }
    }

    # Sort OUs deepest-first by DN depth to avoid "parent already deleted" errors.
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
                    $ouStillExists = Get-ADOrganizationalUnit -Identity $ou.DistinguishedName -ErrorAction SilentlyContinue
                    if ($null -ne $ouStillExists) {
                        Set-ADOrganizationalUnit -Identity $ou.DistinguishedName -ProtectedFromAccidentalDeletion $false -ErrorAction Stop
                        Remove-ADOrganizationalUnit -Identity $ou.DistinguishedName -Recursive -Confirm:$false -ErrorAction Stop
                        Write-ADAutoXConsole -Message "Rolled back OU: $($ou.DistinguishedName)" -Level Success
                        [void]$deletedDNs.Add($ou.DistinguishedName)
                        if ($LogPath) {
                            Write-ADAutoXLogRecord -LogPath $LogPath -Action 'RollbackOU' -Target $ou.DistinguishedName -Status 'Succeeded' -Message 'OU removed during rollback.'
                        }
                    }
                    else {
                        Write-ADAutoXConsole -Message "OU '$($ou.DistinguishedName)' already removed (parent deleted). Marking complete." -Level Info
                        [void]$deletedDNs.Add($ou.DistinguishedName)
                    }
                }
                else {
                    Write-ADAutoXConsole -Message "Skipped rolling back OU '$($ou.DistinguishedName)': Cmdlet not available." -Level Warning
                    $failureCount++
                }
            }
            catch {
                Write-ADAutoXConsole -Message "Failed to rollback OU '$($ou.DistinguishedName)': $($_.Exception.Message)" -Level Error
                if ($LogPath) {
                    Write-ADAutoXLogRecord -LogPath $LogPath -Action 'RollbackOU' -Target $ou.DistinguishedName -Status 'Failed' -Message $_.Exception.Message
                }
                $failureCount++
            }
        }
    }

    # BUG-04: Only remove successfully deleted entries; keep failures; skip wipe on -WhatIf
    if (-not $isWhatIf) {
        if ($failureCount -eq 0) {
            # All done — clear ledger and remove file
            $script:Ledger.Clear()
            $ledgerPath = Get-ADAutoXLedgerFilePath
            if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
                Remove-Item -LiteralPath $ledgerPath -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            # Remove only the successfully deleted entries from the in-memory ledger
            $remaining = [System.Collections.Generic.List[psobject]]::new()
            foreach ($entry in $script:Ledger) {
                if (-not $deletedDNs.Contains($entry.DistinguishedName)) {
                    $remaining.Add($entry)
                }
            }
            $script:Ledger = $remaining
            Save-ADAutoXLedgerToDisk

            Write-ADAutoXConsole -Message "ROLLBACK INCOMPLETE: $failureCount object(s) could not be removed. They remain in the ledger for your next recovery attempt. Review the audit log for details." -Level Error
            if ($LogPath) {
                Write-ADAutoXLogRecord -LogPath $LogPath -Action 'RollbackSummary' -Target 'Ledger' -Status 'CompletedWithErrors' -Message "Rollback finished with $failureCount failure(s). Remaining entries kept in ledger."
            }
            # BUG-04: Exit with a non-zero code so callers/scripts detect the failure
            $global:LASTEXITCODE = 1
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

        [string]$NetBIOSName = '',

        # BUG-19: caller must pass names already parsed via the shared parsing helper
        # so that preflight uses identical rules to the provisioner
        [psobject[]]$ParsedNames = @()
    )

    Write-ADAutoXConsole -Message 'Phase 1: Preflight Validation (Non-mutating)' -Level Phase
    $null = $NetBIOSName
    $checks = [System.Collections.Generic.List[psobject]]::new()

    # BUG-39: Validate department names up front
    foreach ($dept in $Departments) {
        if ([string]::IsNullOrWhiteSpace($dept)) {
            throw "Department name cannot be empty or whitespace."
        }
        if ($dept.Length -gt 64) {
            throw "Department name '$dept' exceeds the 64-character AD limit."
        }
        # Characters not safe in OU names or SAM account names
        if ($dept -match '[/\\:*?"<>|]') {
            throw "Department name '$dept' contains characters not allowed in AD OU or group names: / \ : * ? `" < > |"
        }
    }

    if (-not (Get-Command -Name Get-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
        Write-ADAutoXConsole -Message "[Offline/Preview] Active Directory module not present locally. Simulating preflight checks." -Level Warning
        $obj1 = [pscustomobject]@{ Name = 'Company OU'; Status = 'NeedsAttention'; Details = "Company OU '$CompanyOuName' will be evaluated during Phase 2." }
        $checks.Add($obj1)

        $obj2 = [pscustomobject]@{ Name = 'Staff OU'; Status = 'NeedsAttention'; Details = "Staff OU '$StaffOuName' will be evaluated during Phase 2." }
        $checks.Add($obj2)

        foreach ($dept in $Departments) {
            $objDept = [pscustomobject]@{ Name = "Department Structure: $dept"; Status = 'NeedsAttention'; Details = "Department OU '$dept' will be evaluated during Phase 2." }
            $checks.Add($objDept)
        }
        $summary = [pscustomobject]@{ PassedCount = 0; NeedsAttentionCount = $checks.Count; CollisionCount = 0; Checks = $checks.ToArray() }
        Write-ADAutoXConsole -Message "Preflight completed: $($summary.NeedsAttentionCount) pending creation/validation." -Level Info
        return $summary
    }

    $safeCompanyFilter = ConvertTo-ADLdapFilter -Value $CompanyOuName
    try {
        $companyOUs = @(Get-ADOrganizationalUnit -LDAPFilter "(ou=$safeCompanyFilter)" -SearchBase $DomainDN -SearchScope OneLevel -ErrorAction Stop)
    }
    catch {
        # BUG-21: surface real errors (not just "not found") as hard failures
        throw "Preflight: Failed to query Company OU in '$DomainDN'. Check connectivity and permissions. Error: $($_.Exception.Message)"
    }
    $companyExists = $companyOUs.Count -gt 0

    $statusCompany  = if ($companyExists) { 'Passed' } else { 'NeedsAttention' }
    $detailsCompany = if ($companyExists) { "Root OU '$CompanyOuName' already exists in AD (will not be created/ledgered)." } else { "Root OU '$CompanyOuName' does not exist; will be created." }
    $checks.Add([pscustomobject]@{ Name = 'Company OU'; Status = $statusCompany; Details = $detailsCompany })

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

    $statusStaff  = if ($staffExists) { 'Passed' } else { 'NeedsAttention' }
    $detailsStaff = if ($staffExists) { "Staff OU '$StaffOuName' already exists in AD." } else { "Staff OU '$StaffOuName' will be created." }
    $checks.Add([pscustomobject]@{ Name = 'Staff OU'; Status = $statusStaff; Details = $detailsStaff })

    foreach ($dept in $Departments) {
        $safeDeptFilter = ConvertTo-ADLdapFilter -Value $dept
        $deptOUs = @()
        if ($staffExists) {
            try {
                $ouResult = Get-ADOrganizationalUnit -LDAPFilter "(ou=$safeDeptFilter)" -SearchBase $staffDN -SearchScope OneLevel -ErrorAction Stop
                $deptOUs = @($ouResult)
            }
            catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
                # Only swallow "not found" — BUG-21
                Write-Verbose "[ADAutoX.Provisioner] Department OU '$dept' not found (will be created in Phase 2)."
            }
            catch {
                # Real connectivity / permission error — propagate
                throw "Preflight: Error querying department OU '$dept': $($_.Exception.Message)"
            }
        }
        $deptExists = $deptOUs.Count -gt 0

        $statusDept  = if ($deptExists) { 'Passed' } else { 'NeedsAttention' }
        $detailsDept = if ($deptExists) { "Department OU '$dept' exists." } else { "Department OU '$dept' will be created." }
        $checks.Add([pscustomobject]@{ Name = "Department OU: $dept"; Status = $statusDept; Details = $detailsDept })

        # BUG-05: Look for the group by its exact expected DN (inside the Groups OU), not domain-wide
        $deptUserGroupSam = "$dept-Users"
        $safeDeptValue    = ConvertTo-ADDistinguishedNameValue -Value $dept
        $expectedGroupDN  = "CN=$deptUserGroupSam,OU=Groups,OU=$safeDeptValue,$staffDN"
        $groupStatus      = 'NeedsAttention'
        $groupDetails     = "Security Group '$deptUserGroupSam' will be created at expected DN."

        if ($deptExists) {
            try {
                $groupAtExpectedDN = Get-ADGroup -Identity $expectedGroupDN -ErrorAction Stop
                if ($null -ne $groupAtExpectedDN) {
                    $groupStatus  = 'Passed'
                    $groupDetails = "Security Group '$deptUserGroupSam' exists at expected DN."
                }
            }
            catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
                # Not found at expected DN — check if a same-named group exists elsewhere (warning)
                try {
                    $elsewhereGroup = Get-ADGroup -Filter { SamAccountName -eq $deptUserGroupSam } -ErrorAction Stop
                    if ($null -ne $elsewhereGroup) {
                        $groupStatus  = 'CollisionWarning'
                        $groupDetails = "A group named '$deptUserGroupSam' already exists at '$($elsewhereGroup.DistinguishedName)' - NOT at the expected location. Provisioner will halt unless -AdoptExistingGroups is passed."
                    }
                }
                catch { }
            }
            catch {
                throw "Preflight: Error querying group '$deptUserGroupSam': $($_.Exception.Message)"
            }
        }
        $checks.Add([pscustomobject]@{ Name = "Department Group: $deptUserGroupSam"; Status = $groupStatus; Details = $groupDetails })
    }

    # BUG-19: Use the same parsed-name list the provisioner will use, including wrap-around suffix
    $collisionCount  = 0
    $usedSamPreflight = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($identity in $ParsedNames) {
        $baseSam = if ($identity.IsMononym) { $identity.FirstName } else { "$($identity.FirstName).$($identity.LastName)" }
        $sanitizedSam = $null
        try {
            $sanitizedSam = Get-ADSanitizedSamAccountName -BaseName $baseSam -UsedNames $usedSamPreflight
        }
        catch {
            continue # BUG-22: skip unresolvable names rather than aborting
        }

        try {
            # BUG-21: only swallow "not found"; let real errors propagate
            $existingUser = Get-ADUser -Filter { SamAccountName -eq $sanitizedSam } -ErrorAction Stop
        }
        catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
            $existingUser = $null
        }
        catch {
            throw "Preflight: Error checking user SAM '$sanitizedSam': $($_.Exception.Message)"
        }

        if ($null -ne $existingUser) {
            $collisionCount++
            $checks.Add([pscustomobject]@{
                Name    = "User Collision Check: $sanitizedSam"
                Status  = 'CollisionWarning'
                Details = "User '$sanitizedSam' already exists in AD. Provisioner will skip creation."
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
