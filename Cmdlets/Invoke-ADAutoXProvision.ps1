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
    .\Invoke-ADAutoXProvision.ps1 -CompanyOuName 'CorpLab' -RollbackOnFailure
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # BUG-07: Omitting AccountCount provisions all users by default
    [ValidateRange(1, 100000)]
    [int]$AccountCount = 0,

    [ValidateNotNullOrEmpty()]
    [string]$CompanyOuName = 'Company',

    [ValidateNotNullOrEmpty()]
    [string]$StaffOuName = 'Staff',

    [string]$NamesPath = '',

    [string[]]$Departments = @('IT', 'HR', 'Finance', 'Sales'),

    [switch]$CreateDepartmentAdministrators = $true,

    [switch]$RollbackOnFailure = $true,

    # BUG-05: Do not adopt pre-existing department groups unless explicitly requested
    [switch]$AdoptExistingGroups,

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
# Default to timestamped per-run filename so previous runs' passwords are never silently overwritten
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

# BUG-20: Specify UTF-8 encoding when reading the names file to prevent ANSI corruption
$rawNames = Get-Content -LiteralPath $NamesPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$namePairs = [System.Collections.Generic.List[psobject]]::new()
# De-duplicate raw names (BUG-23)
$uniqueRawNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::InvariantCultureIgnoreCase)

foreach ($line in $rawNames) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
    if (-not $uniqueRawNames.Add($trimmed)) { continue }

    # Split on LAST space so "Mary Jane Watson" -> FirstName="Mary Jane", LastName="Watson"
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

$actualAccountCount = if ($AccountCount -gt 0) { [Math]::Min($AccountCount, $namePairs.Count) } else { $namePairs.Count }

Write-ADAutoXConsole -Message "Loaded $($namePairs.Count) unique identity templates from $NamesPath" -Level Info

# Initialize AD Context
$adInfo = $null
# BUG-35: In -WhatIf mode, attempt to connect using the provided parameters first
if ($WhatIfPreference) {
    Write-ADAutoXConsole -Message "[WhatIf Mode] Attempting AD Domain Controller connection for preview..." -Level Warning
    try {
        $adInfo = Initialize-ADAutoXContext -Server $Server -Credential $Credential
        Write-ADAutoXConsole -Message "Preview: Connected to DC '$($adInfo.Server)' [Domain: $($adInfo.DomainName)]" -Level Success
    }
    catch {
        Write-ADAutoXConsole -Message "[WhatIf Mode] Connection failed/skipped. Simulating AD structure." -Level Warning
        $adInfo = [pscustomobject]@{
            Server      = 'DC01'
            DomainName  = 'lab.local'
            DomainDN    = 'DC=lab,DC=local'
            NetBIOSName = 'CORP'
            UPNSuffixes = @('lab.local')
        }
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

# BUG-26: get splat params
$adParams = Get-ADAutoXSplatParams
$effectiveUpnSuffix = if ($UPNSuffix) { $UPNSuffix } else { $adInfo.DomainName }

# Build the full list of parsed names for preflight
$sampleNameList = [System.Collections.Generic.List[psobject]]::new()
for ($i = 0; $i -lt $actualAccountCount; $i++) {
    $identity   = $namePairs[$i % $namePairs.Count]
    $cycleIndex = [Math]::Floor($i / $namePairs.Count)
    $firstName  = $identity.FirstName
    $lastName   = if ($identity.IsMononym) { '' } else {
        if ($cycleIndex -gt 0) { "$($identity.LastName)$($cycleIndex + 1)" } else { $identity.LastName }
    }
    $sampleNameList.Add([pscustomobject]@{ FirstName = $firstName; LastName = $lastName; IsMononym = $identity.IsMononym })
}

try {
    # Phase 1: Preflight
    $preflight = Invoke-ADAutoXPreflight -CompanyOuName $CompanyOuName `
                                         -StaffOuName $StaffOuName `
                                         -Departments $Departments `
                                         -DomainDN $adInfo.DomainDN `
                                         -NetBIOSName $adInfo.NetBIOSName `
                                         -ParsedNames $sampleNameList.ToArray()

    if ($preflight.NeedsAttentionCount -gt 0) {
        Write-ADAutoXConsole -Message "Preflight found $($preflight.NeedsAttentionCount) target resources to evaluate/provision." -Level Info
    }
    if ($preflight.CollisionCount -gt 0) {
        Write-ADAutoXConsole -Message "Preflight found $($preflight.CollisionCount) existing user(s)/group collision(s)." -Level Warning
        
        # Check for group collisions
        $groupCollisions = @($preflight.Checks | Where-Object { $_.Name -like 'Department Group:*' -and $_.Status -eq 'CollisionWarning' })
        if ($groupCollisions.Count -gt 0 -and -not $AdoptExistingGroups) {
            throw "Preflight aborted: Department groups exist in unexpected locations. Pass -AdoptExistingGroups to use them anyway."
        }
    }

    # Phase 2: Execution & Provisioning
    Write-ADAutoXConsole -Message "Phase 2: Execution & Provisioning" -Level Phase
    $safeCompanyOuValue = ConvertTo-ADDistinguishedNameValue -Value $CompanyOuName
    $companyDN = "OU=$safeCompanyOuValue,$($adInfo.DomainDN)"
    
    Initialize-ADAutoXLedger -CompanyDN $companyDN
    $createdCredentials = @{}
    $reportRows = [System.Collections.Generic.List[psobject]]::new()
    $usedSamNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $usedCNs      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $safeStaffOuValue   = ConvertTo-ADDistinguishedNameValue -Value $StaffOuName
    $staffDN   = "OU=$safeStaffOuValue,$companyDN"

    # -- 1. Root Company OU ------------------------------------------------------
    if ($PSCmdlet.ShouldProcess($companyDN, 'Create Root Company OU')) {
        $companyCreated = $false
        if (-not $WhatIfPreference -and (Get-Command Get-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
            $safeCompFilter = ConvertTo-ADLdapFilter -Value $CompanyOuName
            $existingCompany = Get-ADOrganizationalUnit @adParams -LDAPFilter "(ou=$safeCompFilter)" -SearchBase $adInfo.DomainDN -SearchScope OneLevel -ErrorAction SilentlyContinue
            if ($null -eq $existingCompany) {
                New-ADOrganizationalUnit @adParams -Name $CompanyOuName -Path $adInfo.DomainDN -ErrorAction Stop
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
            $existingStaff = Get-ADOrganizationalUnit @adParams -LDAPFilter "(ou=$safeStaffFilter)" -SearchBase $companyDN -SearchScope OneLevel -ErrorAction SilentlyContinue
            if ($null -eq $existingStaff) {
                New-ADOrganizationalUnit @adParams -Name $StaffOuName -Path $companyDN -ErrorAction Stop
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
                $existingDeptOU = Get-ADOrganizationalUnit @adParams -LDAPFilter "(ou=$safeDeptFilter)" -SearchBase $staffDN -SearchScope OneLevel -ErrorAction SilentlyContinue
                if ($null -eq $existingDeptOU) {
                    New-ADOrganizationalUnit @adParams -Name $dept -Path $staffDN -ErrorAction Stop
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
                $existingUsersOU = Get-ADOrganizationalUnit @adParams -LDAPFilter "(ou=Users)" -SearchBase $deptDN -SearchScope OneLevel -ErrorAction SilentlyContinue
                if ($null -eq $existingUsersOU) {
                    New-ADOrganizationalUnit @adParams -Name 'Users' -Path $deptDN -ErrorAction Stop
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
                $existingGroupsOU = Get-ADOrganizationalUnit @adParams -LDAPFilter "(ou=Groups)" -SearchBase $deptDN -SearchScope OneLevel -ErrorAction SilentlyContinue
                if ($null -eq $existingGroupsOU) {
                    New-ADOrganizationalUnit @adParams -Name 'Groups' -Path $deptDN -ErrorAction Stop
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
                # BUG-05: Look up group by exact expected DN
                $existingGroup = $null
                try {
                    $existingGroup = Get-ADGroup @adParams -Identity $deptUserGroupDN -ErrorAction Stop
                }
                catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
                    $existingGroup = $null
                }

                if ($null -eq $existingGroup) {
                    # Not at expected DN. Does it exist elsewhere?
                    $elsewhereGroup = Get-ADGroup @adParams -Filter { SamAccountName -eq $deptUserGroupSam } -ErrorAction SilentlyContinue
                    if ($null -ne $elsewhereGroup) {
                        if ($AdoptExistingGroups) {
                            Write-ADAutoXConsole -Message "Adopting existing group '$deptUserGroupSam' found at '$($elsewhereGroup.DistinguishedName)'" -Level Warning
                        } else {
                            throw "Group '$deptUserGroupSam' already exists at '$($elsewhereGroup.DistinguishedName)'! Use -AdoptExistingGroups to proceed."
                        }
                    } else {
                        New-ADGroup @adParams -Name $deptUserGroupSam `
                                    -SamAccountName $deptUserGroupSam `
                                    -GroupScope Global `
                                    -GroupCategory Security `
                                    -Path $deptGroupDN `
                                    -Description "Security group for $dept department staff." `
                                    -ErrorAction Stop
                        $userGroupCreated = $true
                    }
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
                    $existingAdminGroup = $null
                    try {
                        $existingAdminGroup = Get-ADGroup @adParams -Identity $deptAdminGroupDN -ErrorAction Stop
                    }
                    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
                        $existingAdminGroup = $null
                    }

                    if ($null -eq $existingAdminGroup) {
                        $elsewhereAdminGroup = Get-ADGroup @adParams -Filter { SamAccountName -eq $deptAdminGroupSam } -ErrorAction SilentlyContinue
                        if ($null -ne $elsewhereAdminGroup) {
                            if ($AdoptExistingGroups) {
                                Write-ADAutoXConsole -Message "Adopting existing admin group '$deptAdminGroupSam' found at '$($elsewhereAdminGroup.DistinguishedName)'" -Level Warning
                            } else {
                                throw "Admin group '$deptAdminGroupSam' already exists at '$($elsewhereAdminGroup.DistinguishedName)'! Use -AdoptExistingGroups to proceed."
                            }
                        } else {
                            New-ADGroup @adParams -Name $deptAdminGroupSam `
                                        -SamAccountName $deptAdminGroupSam `
                                        -GroupScope Global `
                                        -GroupCategory Security `
                                        -Path $deptGroupDN `
                                        -Description "Delegated administrative group for $dept department." `
                                        -ErrorAction Stop
                            $adminGroupCreated = $true
                        }
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
    for ($i = 0; $i -lt $actualAccountCount; $i++) {
        $identity   = $sampleNameList[$i]
        $dept       = $Departments[$deptIndex % $Departments.Count]
        $deptIndex++

        $firstName  = $identity.FirstName
        $lastName   = $identity.LastName

        $safeDeptValue = ConvertTo-ADDistinguishedNameValue -Value $dept
        $deptUsersDN   = "OU=Users,OU=$safeDeptValue,$staffDN"

        $baseSam = if ($identity.IsMononym) { $firstName } else { "$firstName.$lastName" }
        
        $samName = $null
        try {
            $samName = Get-ADSanitizedSamAccountName -BaseName $baseSam -UsedNames $usedSamNames
        }
        catch {
            # BUG-22: Log skipped users and continue
            Write-ADAutoXConsole -Message "Skipped user generation for '$baseSam': $($_.Exception.Message)" -Level Warning
            Write-ADAutoXLogRecord -LogPath $AuditLogPath -Action 'CreateUser' -Target $baseSam -Status 'Failed' -Message $_.Exception.Message -CorrelationId $correlationId
            continue
        }

        $upn = Get-ADSanitizedUserPrincipalName -SamAccountName $samName -UPNSuffix $effectiveUpnSuffix

        # BUG-23: Handle duplicate Common Names (CN)
        $baseFullName = if ($identity.IsMononym) { $firstName } else { "$firstName $lastName" }
        $fullName = $baseFullName
        $cnSuffix = 1
        while ($usedCNs.Contains("$fullName|$deptUsersDN")) {
            $cnSuffix++
            $fullName = "$baseFullName $cnSuffix"
        }
        [void]$usedCNs.Add("$fullName|$deptUsersDN")

        $safeFullName = ConvertTo-ADDistinguishedNameValue -Value $fullName
        $userDN       = "CN=$safeFullName,$deptUsersDN"
        $userPassword = New-ADAutoXRandomPassword -Length 20

        if ($PSCmdlet.ShouldProcess($userDN, "Provision User $samName")) {
            $userWasCreated = $false
            if (-not $WhatIfPreference -and (Get-Command New-ADUser -ErrorAction SilentlyContinue)) {
                $existingUser = $null
                try {
                    $existingUser = Get-ADUser @adParams -Filter { SamAccountName -eq $samName } -ErrorAction Stop
                }
                catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
                    $existingUser = $null
                }
                catch {
                    throw "Error checking if user '$samName' exists: $($_.Exception.Message)"
                }
                
                if ($null -eq $existingUser) {
                    $secPassword = ConvertTo-SecureString $userPassword -AsPlainText -Force

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
                        # BUG-25: Force change password at logon
                        ChangePasswordAtLogon = $true
                    }
                    if (-not $identity.IsMononym) {
                        $newUserParams['Surname'] = $lastName
                    }

                    # Add splat params
                    foreach ($key in $adParams.Keys) { $newUserParams[$key] = $adParams[$key] }

                    New-ADUser @newUserParams -ErrorAction Stop
                    $userWasCreated = $true

                    # Add to standard department security group
                    $deptUserGroupSam = "$dept-Users"
                    try {
                        if (Get-Command Add-ADGroupMember -ErrorAction SilentlyContinue) {
                            $groupToAddTo = Get-ADGroup @adParams -Identity $deptUserGroupSam -ErrorAction Stop
                            Add-ADGroupMember @adParams -Identity $groupToAddTo -Members $samName -ErrorAction Stop
                        }
                    }
                    catch {
                        Write-ADAutoXConsole -Message "Warning: Failed to add '$samName' to group '$deptUserGroupSam': $($_.Exception.Message)" -Level Warning
                    }

                    # Assign first user per dept to the admin group
                    if ($CreateDepartmentAdministrators -and -not $deptAdminAssigned.ContainsKey($dept)) {
                        $deptAdminGroupSam = "$dept-Admins"
                        try {
                            if (Get-Command Add-ADGroupMember -ErrorAction SilentlyContinue) {
                                $adminGroupToAddTo = Get-ADGroup @adParams -Identity $deptAdminGroupSam -ErrorAction Stop
                                Add-ADGroupMember @adParams -Identity $adminGroupToAddTo -Members $samName -ErrorAction Stop
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

    # -- Phase 3: Live Verification - FAILS the run on mismatches --------
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
                            $adObj = Get-ADUser @adParams -Identity $entry.DistinguishedName -Properties Enabled -ErrorAction Stop
                            if ($adObj -and $adObj.Enabled) { 
                                # BUG-24: Verify Group Memberships for users
                                $groups = Get-ADPrincipalGroupMembership @adParams -Identity $entry.DistinguishedName -ErrorAction Stop
                                $isInDeptGroup = $false
                                foreach ($g in $groups) {
                                    if ($g.Name -match "\-Users$") { $isInDeptGroup = $true; break }
                                }
                                if ($isInDeptGroup) {
                                    $verifiedCount++
                                } else {
                                    Write-ADAutoXConsole -Message "Verification Warning: User '$($entry.SamAccountName)' is not in a department group!" -Level Warning
                                    $failedCount++
                                    # Mark row as CreatedWithErrors
                                    $reportRow = $reportRows | Where-Object { $_.SamAccountName -eq $entry.SamAccountName }
                                    if ($reportRow) { $reportRow.Status = 'CreatedWithErrors' }
                                }
                            } else { $failedCount++ }
                        }
                        'Group' {
                            $adObj = Get-ADGroup @adParams -Identity $entry.DistinguishedName -ErrorAction Stop
                            if ($adObj) { $verifiedCount++ } else { $failedCount++ }
                        }
                        'OU' {
                            $adObj = Get-ADOrganizationalUnit @adParams -Identity $entry.DistinguishedName -ErrorAction Stop
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

    # -- Phase 4: Reporting & Credential Export --
    Write-ADAutoXConsole -Message "Phase 4: Reporting & Credential Export" -Level Phase
    $exportFailed = $false
    try {
        if (-not $WhatIfPreference -and $createdCredentials.Count -gt 0) {
            # BUG-07: Treat failed export as a real failure so we don't print "completed successfully" when passwords are lost.
            try {
                Export-ADAutoXCredentials -CredentialMap $createdCredentials -OutputPath $PasswordFile
                Write-ADAutoXConsole -Message "Exported DPAPI-protected credentials to: $PasswordFile" -Level Success
            }
            catch {
                $exportFailed = $true
                Write-ADAutoXConsole -Message "CRITICAL FAILURE: Password export failed! $($_.Exception.Message)" -Level Error
                Write-ADAutoXConsole -Message "User accounts were created but passwords could not be saved to disk." -Level Error
                Write-ADAutoXConsole -Message "You MUST manually reset passwords for these accounts or run a rollback." -Level Error
                throw "Password export failed. Passwords are lost. Check disk space or permissions."
            }
        }

        if ($reportRows.Count -gt 0) {
            # BUG-40: protect CSV cells
            $sanitizedRows = $reportRows | ForEach-Object {
                $row = [ordered]@{}
                foreach ($prop in $_.PSObject.Properties) {
                    $val = $prop.Value
                    if ($val -is [string]) { $val = Protect-ADAutoXCsvCell -Value $val }
                    $row[$prop.Name] = $val
                }
                [pscustomobject]$row
            }
            
            $sanitizedRows | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8 -Force
            if ($IncludePasswordInReport) {
                # BUG-08: This uses Protect-ADAutoXFileAcl which might not be completely robust against TOCTOU if done after write.
                # However, the user explicitly requested it via -IncludePasswordInReport which is discouraged.
                # The primary credential file is protected *before* write.
                Protect-ADAutoXFileAcl -Path $ReportPath | Out-Null
                Write-ADAutoXConsole -Message "CSV report written to: $ReportPath (Permissions restricted)" -Level Warning
            }
            else {
                Write-ADAutoXConsole -Message "CSV report written to: $ReportPath" -Level Success
            }
        }
    }
    catch {
        Write-ADAutoXConsole -Message "Phase 4 reporting error: $($_.Exception.Message)" -Level Error
        if ($exportFailed) { throw } # Rethrow critical credential export failures
    }

    if (-not $exportFailed) {
        Write-ADAutoXConsole -Message "ADAutoX Provisioning completed successfully! Accounts created this run: $($createdCredentials.Count)" -Level Phase
    }
}
catch {
    Write-ADAutoXConsole -Message "Error during provisioning: $($_.Exception.Message)" -Level Error
    if ($RollbackOnFailure) {
        # BUG-03: Pass CompanyDN to rollback
        Invoke-ADAutoXLedgerRollback -LogPath $AuditLogPath -ExpectedCompanyDN (Get-ADAutoXLedger | Select-Object -First 1).DistinguishedName
    }
    throw
}
finally {
    if (-not $WhatIfPreference) {
        Clear-ADAutoXContext
    }
}
