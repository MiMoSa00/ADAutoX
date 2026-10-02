<#
.SYNOPSIS
    Provisions department OUs, security groups, standard users, and department administrator group assignments in Active Directory.

.DESCRIPTION
    Executes a structured 4-phase provisioning pipeline:
    Phase 1: Real preflight validation against AD (collision checking, OU/group existence)
    Phase 2: Active Directory object creation (OUs, Security Groups, Users, Group Memberships)
    Phase 3: Live state verification against the target Domain Controller (fails the run on mismatch)
    Phase 4: CSV reporting, audit logging, and timestamped DPAPI credential export

.EXAMPLE
    .\Invoke-ADAutoXProvision.ps1 -AccountCount 10 -WhatIf

.EXAMPLE
    .\Invoke-ADAutoXProvision.ps1 -AccountCount 20 -CompanyOuName 'CorpLab' -RollbackOnFailure
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # Bug #7: 0 now means "create zero", not "create all". Use a large number or omit to create all.
    [ValidateRange(1, 1000)]
    [int]$AccountCount = 20,

    [ValidateNotNullOrEmpty()]
    [string]$CompanyOuName = 'Company',

    [ValidateNotNullOrEmpty()]
    [string]$StaffOuName = 'Staff',

    # Bug #2 (ValidateNotNullOrEmpty on empty default): removed the attribute so the IsNullOrWhiteSpace
    # fallback below can work as originally intended.
    [string]$NamesPath = '',

    [string[]]$Departments = @('IT', 'HR', 'Finance', 'Sales'),

    [switch]$CreateDepartmentAdministrators = $true,

    [switch]$RollbackOnFailure = $true,

    # Bug #8: Omit to get a timestamped, per-run filename (no silent overwrite of previous run's passwords)
    [string]$PasswordFile = '',

    [switch]$IncludePasswordInReport,

    [string]$ReportPath = '',

    [string]$AuditLogPath = '',

    [string]$Server,

    [string]$UPNSuffix,

    [PSCredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$rootDir   = Split-Path -Parent $scriptDir

# Load Module
Import-Module (Join-Path -Path $rootDir -ChildPath 'ADAutoX.psd1') -Force

if ([string]::IsNullOrWhiteSpace($NamesPath)) {
    $NamesPath = Join-Path -Path $rootDir -ChildPath 'Data\sample-names.txt'
}
if ([string]::IsNullOrWhiteSpace($AuditLogPath)) {
    $AuditLogPath = Join-Path -Path $rootDir -ChildPath 'ADAutoX-Audit.jsonl'
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path -Path $rootDir -ChildPath 'ADAutoX-Provisioning-Report.csv'
}
# Bug #8: default to timestamped per-run filename so previous runs' passwords are never silently overwritten
if ([string]::IsNullOrWhiteSpace($PasswordFile)) {
    $runStamp  = (Get-Date).ToString('yyyy-MM-dd-HHmmss')
    $PasswordFile = Join-Path -Path $rootDir -ChildPath "user-passwords-$runStamp.clixml"
}

$correlationId = New-ADAutoXCorrelationId
Write-ADAutoXConsole -Message "Starting ADAutoX Provisioning Session [CorrelationID: $correlationId]" -Level Phase

# Parse names file
if (-not (Test-Path -LiteralPath $NamesPath -PathType Leaf)) {
    throw "Names data file not found: $NamesPath"
}

$rawNames = Get-Content -LiteralPath $NamesPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$namePairs = [System.Collections.Generic.List[psobject]]::new()
foreach ($line in $rawNames) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

    # Bug #19: split on LAST space so "Mary Jane Watson" - FirstName="Mary Jane", LastName="Watson"
    # This preserves compound first-names and properly handles multi-word names.
    $lastSpaceIndex = $trimmed.LastIndexOf(' ')
    if ($lastSpaceIndex -gt 0) {
        $parsedFirst = $trimmed.Substring(0, $lastSpaceIndex).Trim()
        $parsedLast  = $trimmed.Substring($lastSpaceIndex + 1).Trim()
        $namePairs.Add([pscustomobject]@{ FirstName = $parsedFirst; LastName = $parsedLast; IsMononym = $false })
    }
    else {
        # Single-word name (mononym)
        $namePairs.Add([pscustomobject]@{ FirstName = $trimmed; LastName = ''; IsMononym = $true })
    }
}

if ($namePairs.Count -eq 0) {
    throw "No valid names found in $NamesPath"
}

Write-ADAutoXConsole -Message "Loaded $($namePairs.Count) identity templates from $NamesPath" -Level Info

# Initialize AD Context
$adInfo = $null
if ($WhatIfPreference) {
    Write-ADAutoXConsole -Message "[WhatIf Mode] Skipping live AD Domain Controller connection." -Level Warning
    $mockDomain = 'lab.local'
    $mockDN     = 'DC=lab,DC=local'
    if (Get-Command Get-ADDomain -ErrorAction SilentlyContinue) {
        try {
            $realDomain = Get-ADDomain -ErrorAction SilentlyContinue
            if ($realDomain) {
                $mockDomain = $realDomain.DNSRoot
                $mockDN     = $realDomain.DistinguishedName
            }
        } catch {}
    }
    $adInfo = [pscustomobject]@{
        Server      = 'DC01'
        DomainName  = $mockDomain
        DomainDN    = $mockDN
        NetBIOSName = 'CORP'
        UPNSuffixes = @($mockDomain)
    }
}
else {
    try {
        $adInfo = Initialize-ADAutoXContext -Server $Server -Credential $Credential
        Write-ADAutoXConsole -Message "Connected to DC '$($adInfo.Server)' [Domain: $($adInfo.DomainName)]" -Level Success
    }
    catch {
        Write-ADAutoXConsole -Message "Active Directory connection failed: $($_.Exception.Message)" -Level Error
        throw
    }
}

$effectiveUpnSuffix = if ($UPNSuffix) { $UPNSuffix } else { $adInfo.DomainName }

# Build the full list of names that will be provisioned for the collision preflight
$sampleNameList = @($namePairs | Select-Object -First $AccountCount | ForEach-Object {
    if ($_.IsMononym) { $_.FirstName } else { "$($_.FirstName) $($_.LastName)" }
})

try {
    # Phase 1: Preflight (pass ALL names to check - not just first 20)
    $preflight = Invoke-ADAutoXPreflight -CompanyOuName $CompanyOuName `
                                         -StaffOuName $StaffOuName `
                                         -Departments $Departments `
                                         -DomainDN $adInfo.DomainDN `
                                         -NetBIOSName $adInfo.NetBIOSName `
                                         -SampleNames $sampleNameList

    if ($preflight.NeedsAttentionCount -gt 0) {
        Write-ADAutoXConsole -Message "Preflight found $($preflight.NeedsAttentionCount) target resources to evaluate/provision." -Level Info
    }
    if ($preflight.CollisionCount -gt 0) {
        Write-ADAutoXConsole -Message "Preflight found $($preflight.CollisionCount) existing user(s) - these will be skipped and NOT added to the rollback ledger." -Level Warning
    }

    # Phase 2: Execution & Provisioning
    Write-ADAutoXConsole -Message "Phase 2: Execution & Provisioning" -Level Phase
    Initialize-ADAutoXLedger
    $createdCredentials = @{}
    $reportRows = [System.Collections.Generic.List[psobject]]::new()
    $usedSamNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Sanitize base OU names for DistinguishedName building
    $safeCompanyOuValue = ConvertTo-ADDistinguishedNameValue -Value $CompanyOuName
    $safeStaffOuValue   = ConvertTo-ADDistinguishedNameValue -Value $StaffOuName

    # Base DNs
    $companyDN = "OU=$safeCompanyOuValue,$($adInfo.DomainDN)"
    $staffDN   = "OU=$safeStaffOuValue,$companyDN"

    # -- 1. Root Company OU ------------------------------------------------------
    if ($PSCmdlet.ShouldProcess($companyDN, 'Create Root Company OU')) {
        $companyCreated = $false
        if (-not $WhatIfPreference -and (Get-Command Get-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
            $safeCompFilter = ConvertTo-ADLdapFilter -Value $CompanyOuName
            $existingCompany = Get-ADOrganizationalUnit -LDAPFilter "(ou=$safeCompFilter)" -SearchBase $adInfo.DomainDN -SearchScope OneLevel -ErrorAction SilentlyContinue
            if ($null -eq $existingCompany) {
                New-ADOrganizationalUnit -Name $CompanyOuName -Path $adInfo.DomainDN -ErrorAction Stop
                $companyCreated = $true
            }
        } else { $companyCreated = $true }

        if ($companyCreated) {
            Write-ADAutoXConsole -Message "Created Root Company OU: $companyDN" -Level Success
            Add-ADAutoXLedgerEntry -ObjectType 'OU' -DistinguishedName $companyDN -SamAccountName $CompanyOuName
        } else {
            Write-ADAutoXConsole -Message "Root Company OU already exists: $companyDN (Skipped)" -Level Info
        }
    }

    # -- 2. Staff OU --------------------------------------------------------------
    if ($PSCmdlet.ShouldProcess($staffDN, 'Create Staff OU')) {
        $staffCreated = $false
        if (-not $WhatIfPreference -and (Get-Command Get-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
            $safeStaffFilter = ConvertTo-ADLdapFilter -Value $StaffOuName
            $existingStaff = Get-ADOrganizationalUnit -LDAPFilter "(ou=$safeStaffFilter)" -SearchBase $companyDN -SearchScope OneLevel -ErrorAction SilentlyContinue
            if ($null -eq $existingStaff) {
                New-ADOrganizationalUnit -Name $StaffOuName -Path $companyDN -ErrorAction Stop
                $staffCreated = $true
            }
        } else { $staffCreated = $true }

        if ($staffCreated) {
            Write-ADAutoXConsole -Message "Created Staff OU: $staffDN" -Level Success
            Add-ADAutoXLedgerEntry -ObjectType 'OU' -DistinguishedName $staffDN -SamAccountName $StaffOuName
        } else {
            Write-ADAutoXConsole -Message "Staff OU already exists: $staffDN (Skipped)" -Level Info
        }
    }

    # -- 3. Department OUs & Security Groups (deduplicated, one pass per dept) --
    $deptAdminAssigned = @{}
    foreach ($dept in $Departments) {
        $safeDeptValue  = ConvertTo-ADDistinguishedNameValue -Value $dept
        $safeDeptFilter = ConvertTo-ADLdapFilter -Value $dept

        $deptDN      = "OU=$safeDeptValue,$staffDN"
        $deptUsersDN = "OU=Users,$deptDN"
        $deptGroupDN = "OU=Groups,$deptDN"

        # Department OU
        if ($PSCmdlet.ShouldProcess($deptDN, "Create Department OU $dept")) {
            $deptCreated = $false
            if (-not $WhatIfPreference -and (Get-Command Get-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
                $existingDeptOU = Get-ADOrganizationalUnit -LDAPFilter "(ou=$safeDeptFilter)" -SearchBase $staffDN -SearchScope OneLevel -ErrorAction SilentlyContinue
                if ($null -eq $existingDeptOU) {
                    New-ADOrganizationalUnit -Name $dept -Path $staffDN -ErrorAction Stop
                    $deptCreated = $true
                }
            } else { $deptCreated = $true }

            if ($deptCreated) {
                Write-ADAutoXConsole -Message "Created Department OU: $deptDN" -Level Success
                Add-ADAutoXLedgerEntry -ObjectType 'OU' -DistinguishedName $deptDN -SamAccountName $dept
            }
        }

        # Users sub-OU
        if ($PSCmdlet.ShouldProcess($deptUsersDN, "Create Users OU for $dept")) {
            $usersOuCreated = $false
            if (-not $WhatIfPreference -and (Get-Command Get-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
                $existingUsersOU = Get-ADOrganizationalUnit -LDAPFilter "(ou=Users)" -SearchBase $deptDN -SearchScope OneLevel -ErrorAction SilentlyContinue
                if ($null -eq $existingUsersOU) {
                    New-ADOrganizationalUnit -Name 'Users' -Path $deptDN -ErrorAction Stop
                    $usersOuCreated = $true
                }
            } else { $usersOuCreated = $true }

            if ($usersOuCreated) {
                Add-ADAutoXLedgerEntry -ObjectType 'OU' -DistinguishedName $deptUsersDN -SamAccountName "$dept-UsersOU"
            }
        }

        # Groups sub-OU
        if ($PSCmdlet.ShouldProcess($deptGroupDN, "Create Groups OU for $dept")) {
            $groupsOuCreated = $false
            if (-not $WhatIfPreference -and (Get-Command Get-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
                $existingGroupsOU = Get-ADOrganizationalUnit -LDAPFilter "(ou=Groups)" -SearchBase $deptDN -SearchScope OneLevel -ErrorAction SilentlyContinue
                if ($null -eq $existingGroupsOU) {
                    New-ADOrganizationalUnit -Name 'Groups' -Path $deptDN -ErrorAction Stop
                    $groupsOuCreated = $true
                }
            } else { $groupsOuCreated = $true }

            if ($groupsOuCreated) {
                Add-ADAutoXLedgerEntry -ObjectType 'OU' -DistinguishedName $deptGroupDN -SamAccountName "$dept-GroupsOU"
            }
        }

        # Standard Department Security Group
        $deptUserGroupSam = "$dept-Users"
        $safeDeptUserGroupValue = ConvertTo-ADDistinguishedNameValue -Value $deptUserGroupSam
        $deptUserGroupDN  = "CN=$safeDeptUserGroupValue,$deptGroupDN"
        if ($PSCmdlet.ShouldProcess($deptUserGroupDN, "Create Security Group $deptUserGroupSam")) {
            $userGroupCreated = $false
            if (-not $WhatIfPreference -and (Get-Command New-ADGroup -ErrorAction SilentlyContinue)) {
                # Bug #Minor: use PowerShell -Filter with a variable, not LDAP-escaped value
                $existingGroup = Get-ADGroup -Filter { SamAccountName -eq $deptUserGroupSam } -ErrorAction SilentlyContinue
                if ($null -eq $existingGroup) {
                    New-ADGroup -Name $deptUserGroupSam `
                                -SamAccountName $deptUserGroupSam `
                                -GroupScope Global `
                                -GroupCategory Security `
                                -Path $deptGroupDN `
                                -Description "Security group for $dept department staff." `
                                -ErrorAction Stop
                    $userGroupCreated = $true
                }
            } else { $userGroupCreated = $true }

            if ($userGroupCreated) {
                Write-ADAutoXConsole -Message "Created Security Group: $deptUserGroupSam" -Level Success
                Add-ADAutoXLedgerEntry -ObjectType 'Group' -DistinguishedName $deptUserGroupDN -SamAccountName $deptUserGroupSam
            }
        }

        # Department Admin Group
        if ($CreateDepartmentAdministrators) {
            $deptAdminGroupSam = "$dept-Admins"
            $safeDeptAdminGroupValue = ConvertTo-ADDistinguishedNameValue -Value $deptAdminGroupSam
            $deptAdminGroupDN  = "CN=$safeDeptAdminGroupValue,$deptGroupDN"
            if ($PSCmdlet.ShouldProcess($deptAdminGroupDN, "Create Admin Security Group $deptAdminGroupSam")) {
                $adminGroupCreated = $false
                if (-not $WhatIfPreference -and (Get-Command New-ADGroup -ErrorAction SilentlyContinue)) {
                    $existingAdminGroup = Get-ADGroup -Filter { SamAccountName -eq $deptAdminGroupSam } -ErrorAction SilentlyContinue
                    if ($null -eq $existingAdminGroup) {
                        New-ADGroup -Name $deptAdminGroupSam `
                                    -SamAccountName $deptAdminGroupSam `
                                    -GroupScope Global `
                                    -GroupCategory Security `
                                    -Path $deptGroupDN `
                                    -Description "Delegated administrative group for $dept department." `
                                    -ErrorAction Stop
                        $adminGroupCreated = $true
                    }
                } else { $adminGroupCreated = $true }

                if ($adminGroupCreated) {
                    Write-ADAutoXConsole -Message "Created Department Admin Group: $deptAdminGroupSam" -Level Success
                    Add-ADAutoXLedgerEntry -ObjectType 'Group' -DistinguishedName $deptAdminGroupDN -SamAccountName $deptAdminGroupSam
                }
            }
        }
    }

    # -- 4. Users ------------------------------------------------------------------
    $deptIndex = 0
    for ($i = 0; $i -lt $AccountCount; $i++) {
        $identity   = $namePairs[$i % $namePairs.Count]
        $dept       = $Departments[$deptIndex % $Departments.Count]
        $deptIndex++

        # Append index suffix when cycling through name templates
        $cycleIndex = [Math]::Floor($i / $namePairs.Count)
        $firstName  = $identity.FirstName
        $lastName   = if ($identity.IsMononym) { '' } else {
            if ($cycleIndex -gt 0) { "$($identity.LastName)$($cycleIndex + 1)" } else { $identity.LastName }
        }

        $safeDeptValue = ConvertTo-ADDistinguishedNameValue -Value $dept
        $deptUsersDN   = "OU=Users,OU=$safeDeptValue,$staffDN"

        $baseSam = if ($identity.IsMononym) { $firstName } else { "$firstName.$lastName" }
        $samName = Get-ADSanitizedSamAccountName -BaseName $baseSam -UsedNames $usedSamNames
        $upn     = Get-ADSanitizedUserPrincipalName -SamAccountName $samName -UPNSuffix $effectiveUpnSuffix

        $fullName     = if ($identity.IsMononym) { $firstName } else { "$firstName $lastName" }
        $safeFullName = ConvertTo-ADDistinguishedNameValue -Value $fullName
        $userDN       = "CN=$safeFullName,$deptUsersDN"
        $userPassword = New-ADAutoXRandomPassword -Length 20

        if ($PSCmdlet.ShouldProcess($userDN, "Provision User $samName")) {
            $userWasCreated = $false
            if (-not $WhatIfPreference -and (Get-Command New-ADUser -ErrorAction SilentlyContinue)) {
                $existingUser = Get-ADUser -Filter { SamAccountName -eq $samName } -ErrorAction SilentlyContinue
                if ($null -eq $existingUser) {
                    $secPassword = ConvertTo-SecureString $userPassword -AsPlainText -Force

                    # Bug #20: mononyms get an empty Surname, not a duplicated first name
                    $newUserParams = @{
                        Name              = $fullName
                        GivenName         = $firstName
                        SamAccountName    = $samName
                        UserPrincipalName = $upn
                        Department        = $dept
                        Company           = $CompanyOuName
                        Path              = $deptUsersDN
                        AccountPassword   = $secPassword
                        Enabled           = $true
                        ChangePasswordAtLogon = $false
                    }
                    if (-not $identity.IsMononym) {
                        $newUserParams['Surname'] = $lastName
                    }
                    New-ADUser @newUserParams -ErrorAction Stop
                    $userWasCreated = $true

                    # Add to standard department security group (surface errors properly - Bug #6)
                    $deptUserGroupSam = "$dept-Users"
                    try {
                        if (Get-Command Add-ADGroupMember -ErrorAction SilentlyContinue) {
                            Add-ADGroupMember -Identity $deptUserGroupSam -Members $samName -ErrorAction Stop
                        }
                    }
                    catch {
                        Write-ADAutoXConsole -Message "Warning: Failed to add '$samName' to group '$deptUserGroupSam': $($_.Exception.Message)" -Level Warning
                    }

                    # Assign first user per dept to the admin group (Bug #6 - surface, not swallow errors)
                    if ($CreateDepartmentAdministrators -and -not $deptAdminAssigned.ContainsKey($dept)) {
                        $deptAdminGroupSam = "$dept-Admins"
                        try {
                            if (Get-Command Add-ADGroupMember -ErrorAction SilentlyContinue) {
                                Add-ADGroupMember -Identity $deptAdminGroupSam -Members $samName -ErrorAction Stop
                                $deptAdminAssigned[$dept] = $samName
                                Write-ADAutoXConsole -Message "Assigned '$samName' to Admin Group '$deptAdminGroupSam'" -Level Success
                            }
                        }
                        catch {
                            Write-ADAutoXConsole -Message "Warning: Failed to add '$samName' to admin group '$deptAdminGroupSam': $($_.Exception.Message)" -Level Warning
                        }
                    }
                }
            }
            else {
                # Preview / WhatIf mode - treat as created
                $userWasCreated = $true
            }

            # Bug #1 (duplicate account logs success): ONLY log/ledger/export when actually created
            if ($userWasCreated) {
                Write-ADAutoXConsole -Message "Provisioned User: $samName ($dept) -> $userDN" -Level Success
                Add-ADAutoXLedgerEntry -ObjectType 'User' -DistinguishedName $userDN -SamAccountName $samName
                $createdCredentials[$samName] = $userPassword

                Write-ADAutoXLogRecord -LogPath $AuditLogPath `
                                       -Action 'CreateUser' `
                                       -Target $userDN `
                                       -Status 'Succeeded' `
                                       -Message "Account created for $fullName" `
                                       -CorrelationId $correlationId

                $row = [ordered]@{
                    SamAccountName    = $samName
                    UserPrincipalName = $upn
                    FirstName         = $firstName
                    LastName          = $lastName
                    Department        = $dept
                    DistinguishedName = $userDN
                    Status            = 'Created'
                }
                if ($IncludePasswordInReport) { $row['Password'] = $userPassword }
                $reportRows.Add([pscustomobject]$row)
            }
            else {
                # Pre-existing user - skip, do NOT ledger, do NOT export password
                Write-ADAutoXConsole -Message "User '$samName' already exists in AD. Skipping." -Level Warning
                Write-ADAutoXLogRecord -LogPath $AuditLogPath `
                                       -Action 'CreateUser' `
                                       -Target $userDN `
                                       -Status 'Skipped' `
                                       -Message "Account '$samName' already exists - not created by this run." `
                                       -CorrelationId $correlationId

                $reportRows.Add([pscustomobject][ordered]@{
                    SamAccountName    = $samName
                    UserPrincipalName = $upn
                    FirstName         = $firstName
                    LastName          = $lastName
                    Department        = $dept
                    DistinguishedName = $userDN
                    Status            = 'Skipped (Already Exists)'
                })
            }
        }
        else {
            Write-ADAutoXLogRecord -LogPath $AuditLogPath `
                                   -Action 'CreateUser' `
                                   -Target $userDN `
                                   -Status 'Preview' `
                                   -Message "Preview: Would create account for $fullName" `
                                   -CorrelationId $correlationId
        }
    }

    # -- Phase 3: Live Verification - FAILS the run on mismatches (Bug #4) --------
    Write-ADAutoXConsole -Message "Phase 3: Post-Create State Verification" -Level Phase
    if ($WhatIfPreference) {
        Write-ADAutoXConsole -Message "[WhatIf] State verification skipped in preview mode." -Level Warning
    }
    else {
        $ledgerEntries = Get-ADAutoXLedger
        $verifiedCount = 0
        $failedCount   = 0

        if (Get-Command Get-ADUser -ErrorAction SilentlyContinue) {
            foreach ($entry in $ledgerEntries) {
                try {
                    switch ($entry.ObjectType) {
                        'User' {
                            $adObj = Get-ADUser -Identity $entry.DistinguishedName -Properties Enabled -ErrorAction Stop
                            if ($adObj -and $adObj.Enabled) { $verifiedCount++ } else { $failedCount++ }
                        }
                        'Group' {
                            $adObj = Get-ADGroup -Identity $entry.DistinguishedName -ErrorAction Stop
                            if ($adObj) { $verifiedCount++ } else { $failedCount++ }
                        }
                        'OU' {
                            $adObj = Get-ADOrganizationalUnit -Identity $entry.DistinguishedName -ErrorAction Stop
                            if ($adObj) { $verifiedCount++ } else { $failedCount++ }
                        }
                    }
                }
                catch {
                    $failedCount++
                    Write-ADAutoXConsole -Message "Verification FAILED for '$($entry.DistinguishedName)': $($_.Exception.Message)" -Level Warning
                }
            }

            if ($failedCount -gt 0) {
                # Bug #4: Phase 3 must fail (throw) so rollback is triggered
                throw "Phase 3 Verification FAILED: $verifiedCount objects verified, $failedCount could not be confirmed in Active Directory."
            }
            else {
                Write-ADAutoXConsole -Message "Verification passed: $verifiedCount objects confirmed active in the domain controller." -Level Success
            }
        }
        else {
            Write-ADAutoXConsole -Message "Skipped live verification: ActiveDirectory module cmdlets not available locally." -Level Warning
        }
    }

    # -- Phase 4: Reporting & Credential Export (Bug #5: isolated try so a report failure --
    # does NOT trigger rollback of successfully provisioned accounts)
    Write-ADAutoXConsole -Message "Phase 4: Reporting & Credential Export" -Level Phase
    try {
        if (-not $WhatIfPreference -and $createdCredentials.Count -gt 0) {
            Export-ADAutoXCredentials -CredentialMap $createdCredentials -OutputPath $PasswordFile
            Write-ADAutoXConsole -Message "Exported DPAPI-protected credentials to: $PasswordFile" -Level Success
        }

        if ($reportRows.Count -gt 0) {
            $reportRows | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8 -Force
            if ($IncludePasswordInReport) {
                Protect-ADAutoXFileAcl -Path $ReportPath
                Write-ADAutoXConsole -Message "CSV report written to: $ReportPath (Protected with User ACLs)" -Level Warning
            }
            else {
                Write-ADAutoXConsole -Message "CSV report written to: $ReportPath" -Level Success
            }
        }
    }
    catch {
        Write-ADAutoXConsole -Message "Phase 4 reporting error (provisioning was successful): $($_.Exception.Message)" -Level Warning
    }

    Write-ADAutoXConsole -Message "ADAutoX Provisioning completed successfully! Accounts created this run: $($createdCredentials.Count)" -Level Phase

}
catch {
    Write-ADAutoXConsole -Message "Error during provisioning: $($_.Exception.Message)" -Level Error
    if ($RollbackOnFailure) {
        Invoke-ADAutoXLedgerRollback -LogPath $AuditLogPath
    }
    throw
}
finally {
    if (-not $WhatIfPreference) {
        Clear-ADAutoXContext
    }
}
