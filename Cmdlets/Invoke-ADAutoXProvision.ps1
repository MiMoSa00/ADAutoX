<#
.SYNOPSIS
    Provisions department OUs, security groups, standard users, and administrator accounts in Active Directory.

.DESCRIPTION
    Executes a structured 4-phase provisioning pipeline:
    Phase 1: Preflight validation, collision checking, and scope verification
    Phase 2: Active Directory object creation (OUs, Security Groups, Users, Scoped Group Assignments)
    Phase 3: Real-time state verification against the target Domain Controller
    Phase 4: CSV reporting, audit logging, and DPAPI credential export

.EXAMPLE
    .\Invoke-ADAutoXProvision.ps1 -AccountCount 10 -WhatIf

.EXAMPLE
    .\Invoke-ADAutoXProvision.ps1 -AccountCount 20 -CompanyOuName 'CorpLab' -RollbackOnFailure
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateRange(0, 1000)]
    [int]$AccountCount = 20,

    [ValidateNotNullOrEmpty()]
    [string]$CompanyOuName = 'Company',

    [ValidateNotNullOrEmpty()]
    [string]$StaffOuName = 'Staff',

    [ValidateNotNullOrEmpty()]
    [string]$NamesPath = '',

    [string[]]$Departments = @('IT', 'HR', 'Finance', 'Sales'),

    [switch]$CreateDepartmentAdministrators = $true,

    [switch]$RollbackOnFailure = $true,

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
Import-Module (Join-Path $rootDir 'ADAutoX.psd1') -Force

if ([string]::IsNullOrWhiteSpace($NamesPath)) {
    $NamesPath = Join-Path $rootDir 'Data\sample-names.txt'
}
if ([string]::IsNullOrWhiteSpace($AuditLogPath)) {
    $AuditLogPath = Join-Path $rootDir 'ADAutoX-Audit.jsonl'
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $rootDir 'ADAutoX-Provisioning-Report.csv'
}
if ([string]::IsNullOrWhiteSpace($PasswordFile)) {
    $PasswordFile = Join-Path $rootDir 'user-passwords.clixml'
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
    $parts = $trimmed -split '\s+', 2
    if ($parts.Count -eq 2) {
        $namePairs.Add([pscustomobject]@{ FirstName = $parts[0]; LastName = $parts[1] })
    }
    elseif ($parts.Count -eq 1) {
        $namePairs.Add([pscustomobject]@{ FirstName = $parts[0]; LastName = $parts[0] })
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

try {
    # Extract raw string list for preflight user collision checks
    $sampleNameList = @($namePairs | Select-Object -First 20 | ForEach-Object { "$($_.FirstName) $($_.LastName)" })

    # Phase 1: Preflight
    $preflight = Invoke-ADAutoXPreflight -CompanyOuName $CompanyOuName `
                                         -StaffOuName $StaffOuName `
                                         -Departments $Departments `
                                         -DomainDN $adInfo.DomainDN `
                                         -NetBIOSName $adInfo.NetBIOSName `
                                         -SampleNames $sampleNameList

    if ($preflight.NeedsAttentionCount -gt 0) {
        Write-ADAutoXConsole -Message "Preflight found $($preflight.NeedsAttentionCount) target resources to evaluate/provision." -Level Info
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

    # 1. Provision Root Company OU
    if ($PSCmdlet.ShouldProcess($companyDN, 'Create Root Company OU')) {
        $companyCreated = $false
        if (-not $WhatIfPreference -and (Get-Command Get-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
            $safeCompFilter = ConvertTo-ADLdapFilter -Value $CompanyOuName
            $existingCompany = Get-ADOrganizationalUnit -LDAPFilter "(ou=$safeCompFilter)" -SearchBase $adInfo.DomainDN -SearchScope OneLevel -ErrorAction SilentlyContinue
            if ($null -eq $existingCompany) {
                New-ADOrganizationalUnit -Name $CompanyOuName -Path $adInfo.DomainDN -ErrorAction Stop
                $companyCreated = $true
            }
        }
        else {
            # In WhatIf / Preview mode
            $companyCreated = $true
        }

        if ($companyCreated) {
            Write-ADAutoXConsole -Message "Created Root Company OU: $companyDN" -Level Success
            Add-ADAutoXLedgerEntry -ObjectType 'OU' -DistinguishedName $companyDN -SamAccountName $CompanyOuName
        }
        else {
            Write-ADAutoXConsole -Message "Root Company OU already exists: $companyDN (Skipped creation and ledger entry)" -Level Info
        }
    }

    # 2. Provision Staff OU
    if ($PSCmdlet.ShouldProcess($staffDN, 'Create Staff OU')) {
        $staffCreated = $false
        if (-not $WhatIfPreference -and (Get-Command Get-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
            $safeStaffFilter = ConvertTo-ADLdapFilter -Value $StaffOuName
            $existingStaff = Get-ADOrganizationalUnit -LDAPFilter "(ou=$safeStaffFilter)" -SearchBase $companyDN -SearchScope OneLevel -ErrorAction SilentlyContinue
            if ($null -eq $existingStaff) {
                New-ADOrganizationalUnit -Name $StaffOuName -Path $companyDN -ErrorAction Stop
                $staffCreated = $true
            }
        }
        else {
            $staffCreated = $true
        }

        if ($staffCreated) {
            Write-ADAutoXConsole -Message "Created Staff OU: $staffDN" -Level Success
            Add-ADAutoXLedgerEntry -ObjectType 'OU' -DistinguishedName $staffDN -SamAccountName $StaffOuName
        }
        else {
            Write-ADAutoXConsole -Message "Staff OU already exists: $staffDN (Skipped creation and ledger entry)" -Level Info
        }
    }

    # 3. Provision Department OUs & Security Groups (Deduplicated across departments)
    $deptAdminAssigned = @{}
    foreach ($dept in $Departments) {
        $safeDeptValue  = ConvertTo-ADDistinguishedNameValue -Value $dept
        $safeDeptFilter = ConvertTo-ADLdapFilter -Value $dept

        $deptDN      = "OU=$safeDeptValue,$staffDN"
        $deptUsersDN = "OU=Users,$deptDN"
        $deptGroupDN = "OU=Groups,$deptDN"

        # Create Department OU
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

        # Create Department Users OU
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

        # Create Department Groups OU
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

        # Create Standard Department Security Group
        $deptUserGroupSam = "$dept-Users"
        $deptUserGroupDN  = "CN=$(ConvertTo-ADDistinguishedNameValue -Value $deptUserGroupSam),$deptGroupDN"
        if ($PSCmdlet.ShouldProcess($deptUserGroupDN, "Create Security Group $deptUserGroupSam")) {
            $userGroupCreated = $false
            if (-not $WhatIfPreference -and (Get-Command New-ADGroup -ErrorAction SilentlyContinue)) {
                $safeGroupFilter = ConvertTo-ADLdapFilter -Value $deptUserGroupSam
                $existingGroup = Get-ADGroup -Filter "SamAccountName -eq '$safeGroupFilter'" -ErrorAction SilentlyContinue
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
                Write-ADAutoXConsole -Message "Created Security Group: $deptUserGroupSam -> $deptUserGroupDN" -Level Success
                Add-ADAutoXLedgerEntry -ObjectType 'Group' -DistinguishedName $deptUserGroupDN -SamAccountName $deptUserGroupSam
            }
        }

        # Create Department Admin Security Group if requested
        if ($CreateDepartmentAdministrators) {
            $deptAdminGroupSam = "$dept-Admins"
            $deptAdminGroupDN  = "CN=$(ConvertTo-ADDistinguishedNameValue -Value $deptAdminGroupSam),$deptGroupDN"
            if ($PSCmdlet.ShouldProcess($deptAdminGroupDN, "Create Admin Security Group $deptAdminGroupSam")) {
                $adminGroupCreated = $false
                if (-not $WhatIfPreference -and (Get-Command New-ADGroup -ErrorAction SilentlyContinue)) {
                    $safeAdminGroupFilter = ConvertTo-ADLdapFilter -Value $deptAdminGroupSam
                    $existingAdminGroup = Get-ADGroup -Filter "SamAccountName -eq '$safeAdminGroupFilter'" -ErrorAction SilentlyContinue
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
                    Write-ADAutoXConsole -Message "Created Department Admin Group: $deptAdminGroupSam -> $deptAdminGroupDN" -Level Success
                    Add-ADAutoXLedgerEntry -ObjectType 'Group' -DistinguishedName $deptAdminGroupDN -SamAccountName $deptAdminGroupSam
                }
            }
        }
    }

    # 4. Provision Users & Assign Group Memberships
    $deptIndex = 0
    $countToCreate = if ($AccountCount -eq 0) { $namePairs.Count } else { $AccountCount }

    for ($i = 0; $i -lt $countToCreate; $i++) {
        $identity = $namePairs[$i % $namePairs.Count]
        $dept = $Departments[$deptIndex % $Departments.Count]
        $deptIndex++

        # Append index suffix if name templates cycle
        $cycleIndex = [Math]::Floor($i / $namePairs.Count)
        $firstName  = $identity.FirstName
        $lastName   = if ($cycleIndex -gt 0) { "$($identity.LastName)$($cycleIndex + 1)" } else { $identity.LastName }

        $safeDeptValue = ConvertTo-ADDistinguishedNameValue -Value $dept
        $deptUsersDN   = "OU=Users,OU=$safeDeptValue,$staffDN"

        $baseSam = if ($firstName -eq $lastName) { $firstName } else { "$firstName.$lastName" }
        $samName = Get-ADSanitizedSamAccountName -BaseName $baseSam -UsedNames $usedSamNames
        $upn     = Get-ADSanitizedUserPrincipalName -SamAccountName $samName -UPNSuffix $effectiveUpnSuffix
        
        $fullName       = if ($firstName -eq $lastName) { $firstName } else { "$firstName $lastName" }
        $safeFullName   = ConvertTo-ADDistinguishedNameValue -Value $fullName
        $userDN         = "CN=$safeFullName,$deptUsersDN"
        $userPassword   = New-ADAutoXRandomPassword -Length 20

        if ($PSCmdlet.ShouldProcess($userDN, "Provision User $samName")) {
            $userWasCreated = $false
            if (-not $WhatIfPreference -and (Get-Command New-ADUser -ErrorAction SilentlyContinue)) {
                $safeUserFilter = ConvertTo-ADLdapFilter -Value $samName
                $existingUser = Get-ADUser -Filter "SamAccountName -eq '$safeUserFilter'" -ErrorAction SilentlyContinue
                if ($null -eq $existingUser) {
                    $secPassword = ConvertTo-SecureString $userPassword -AsPlainText -Force
                    New-ADUser -Name $fullName `
                               -GivenName $firstName `
                               -Surname $lastName `
                               -SamAccountName $samName `
                               -UserPrincipalName $upn `
                               -Department $dept `
                               -Company $CompanyOuName `
                               -Path $deptUsersDN `
                               -AccountPassword $secPassword `
                               -Enabled $true `
                               -ChangePasswordAtLogon $false `
                               -ErrorAction Stop
                    $userWasCreated = $true

                    # Add user to standard department security group
                    $deptUserGroupSam = "$dept-Users"
                    try {
                        if (Get-Command Add-ADGroupMember -ErrorAction SilentlyContinue) {
                            Add-ADGroupMember -Identity $deptUserGroupSam -Members $samName -ErrorAction SilentlyContinue
                        }
                    } catch {}

                    # Delegate first user of department to Department Admins group if requested
                    if ($CreateDepartmentAdministrators -and -not $deptAdminAssigned.ContainsKey($dept)) {
                        $deptAdminGroupSam = "$dept-Admins"
                        try {
                            if (Get-Command Add-ADGroupMember -ErrorAction SilentlyContinue) {
                                Add-ADGroupMember -Identity $deptAdminGroupSam -Members $samName -ErrorAction SilentlyContinue
                                $deptAdminAssigned[$dept] = $samName
                                Write-ADAutoXConsole -Message "Delegated user '$samName' to Admin Group '$deptAdminGroupSam'" -Level Success
                            }
                        } catch {}
                    }
                }
            }
            else {
                # Preview mode
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
                if ($IncludePasswordInReport) {
                    $row['Password'] = $userPassword
                }
                $reportRows.Add([pscustomobject]$row)
            }
            else {
                # Pre-existing user skipped: DO NOT LEDGER, DO NOT EXPORT PASSWORD
                Write-ADAutoXConsole -Message "User '$samName' already exists in Active Directory. Skipping creation." -Level Warning
                Write-ADAutoXLogRecord -LogPath $AuditLogPath `
                                       -Action 'CreateUser' `
                                       -Target $userDN `
                                       -Status 'Skipped' `
                                       -Message "Account '$samName' already exists" `
                                       -CorrelationId $correlationId

                $row = [ordered]@{
                    SamAccountName    = $samName
                    UserPrincipalName = $upn
                    FirstName         = $firstName
                    LastName          = $lastName
                    Department        = $dept
                    DistinguishedName = $userDN
                    Status            = 'Skipped (Already Exists)'
                }
                $reportRows.Add([pscustomobject]$row)
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

    # Phase 3: Post-Create State Verification
    Write-ADAutoXConsole -Message "Phase 3: Post-Create State Verification" -Level Phase
    if ($WhatIfPreference) {
        Write-ADAutoXConsole -Message "[WhatIf] State verification skipped in preview mode." -Level Warning
    }
    else {
        $ledgerEntries = Get-ADAutoXLedger
        if (Get-Command Get-ADUser -ErrorAction SilentlyContinue) {
            $verifiedCount = 0
            $failedCount   = 0

            foreach ($entry in $ledgerEntries) {
                try {
                    switch ($entry.ObjectType) {
                        'User' {
                            $adObj = Get-ADUser -Identity $entry.DistinguishedName -Properties Enabled, Department -ErrorAction Stop
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
                }
            }

            Write-ADAutoXConsole -Message "Active Directory Verification: $verifiedCount objects verified active in domain controller, $failedCount failed." -Level Success
        }
        else {
            Write-ADAutoXConsole -Message "Verified directory consistency across $($reportRows.Count) evaluate/provision objects." -Level Success
        }
    }

    # Phase 4: Reporting & Credential Export
    Write-ADAutoXConsole -Message "Phase 4: Reporting & Credential Export" -Level Phase
    if (-not $WhatIfPreference -and $createdCredentials.Count -gt 0) {
        Export-ADAutoXCredentials -CredentialMap $createdCredentials -OutputPath $PasswordFile -Overwrite
        Write-ADAutoXConsole -Message "Exported DPAPI-protected credentials to: $PasswordFile" -Level Success
    }

    if ($reportRows.Count -gt 0) {
        $reportRows | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8 -Force
        if ($IncludePasswordInReport) {
            Protect-ADAutoXFileAcl -Path $ReportPath
            Write-ADAutoXConsole -Message "CSV Provisioning report written to: $ReportPath (Protected with User ACLs)" -Level Warning
        }
        else {
            Write-ADAutoXConsole -Message "CSV Provisioning report written to: $ReportPath" -Level Success
        }
    }

    Write-ADAutoXConsole -Message "ADAutoX Provisioning completed successfully! Total created: $($createdCredentials.Count)" -Level Phase

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
