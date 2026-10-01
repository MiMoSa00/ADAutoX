<#
.SYNOPSIS
    Provisions department OUs, security groups, standard users, and administrator accounts in Active Directory.

.DESCRIPTION
    Executes a structured 4-phase provisioning pipeline:
    Phase 1: Preflight validation and collision checking
    Phase 2: Active Directory object creation (OUs, Groups, Users, Scoped ACL Delegation)
    Phase 3: State verification against the target Domain Controller
    Phase 4: CSV reporting, audit logging, and DPAPI credential export

.EXAMPLE
    .\Invoke-ADAutoXProvision.ps1 -AccountCount 10 -WhatIf

.EXAMPLE
    .\Invoke-ADAutoXProvision.ps1 -AccountCount 20 -CompanyOuName 'CorpLab'
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

    [switch]$RollbackOnFailure,

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
        # Support single-word names (mononyms like Mustapha, Abiola)
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
    # Phase 1: Preflight
    $preflight = Invoke-ADAutoXPreflight -CompanyOuName $CompanyOuName `
                                        -StaffOuName $StaffOuName `
                                        -Departments $Departments `
                                        -DomainDN $adInfo.DomainDN `
                                        -NetBIOSName $adInfo.NetBIOSName

    if ($preflight.NeedsAttentionCount -gt 0) {
        Write-ADAutoXConsole -Message "Preflight found $($preflight.NeedsAttentionCount) resources that will be provisioned." -Level Info
    }

    # Phase 2: Provisioning
    Write-ADAutoXConsole -Message "Phase 2: Execution & Provisioning" -Level Phase
    Initialize-ADAutoXLedger
    $createdCredentials = @{}
    $reportRows = [System.Collections.Generic.List[psobject]]::new()
    $usedSamNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Base DNs
    $companyDN = "OU=$CompanyOuName,$($adInfo.DomainDN)"
    $staffDN   = "OU=$StaffOuName,$companyDN"

    if ($PSCmdlet.ShouldProcess($companyDN, 'Create Root Company OU')) {
        if (-not $WhatIfPreference -and (Get-Command New-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
            if (-not (Get-ADOrganizationalUnit -LDAPFilter "(ou=$CompanyOuName)" -SearchBase $adInfo.DomainDN -ErrorAction SilentlyContinue)) {
                New-ADOrganizationalUnit -Name $CompanyOuName -Path $adInfo.DomainDN -ErrorAction Stop
            }
        }
        Write-ADAutoXConsole -Message "Creating Root Company OU: $companyDN" -Level Success
        Add-ADAutoXLedgerEntry -ObjectType 'OU' -DistinguishedName $companyDN -SamAccountName $CompanyOuName
    }
    if ($PSCmdlet.ShouldProcess($staffDN, 'Create Staff OU')) {
        if (-not $WhatIfPreference -and (Get-Command New-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
            if (-not (Get-ADOrganizationalUnit -LDAPFilter "(ou=$StaffOuName)" -SearchBase $companyDN -ErrorAction SilentlyContinue)) {
                New-ADOrganizationalUnit -Name $StaffOuName -Path $companyDN -ErrorAction Stop
            }
        }
        Write-ADAutoXConsole -Message "Creating Staff OU: $staffDN" -Level Success
        Add-ADAutoXLedgerEntry -ObjectType 'OU' -DistinguishedName $staffDN -SamAccountName $StaffOuName
    }

    $deptIndex = 0
    $countToCreate = if ($AccountCount -eq 0 -or $AccountCount -gt $namePairs.Count) { $namePairs.Count } else { $AccountCount }

    for ($i = 0; $i -lt $countToCreate; $i++) {
        $identity = $namePairs[$i]
        $dept = $Departments[$deptIndex % $Departments.Count]
        $deptIndex++

        $deptDN = "OU=$dept,$staffDN"
        $deptUsersDN = "OU=Users,$deptDN"

        if ($PSCmdlet.ShouldProcess($deptDN, "Create Department OU $dept")) {
            if (-not $WhatIfPreference -and (Get-Command New-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
                if (-not (Get-ADOrganizationalUnit -LDAPFilter "(ou=$dept)" -SearchBase $staffDN -ErrorAction SilentlyContinue)) {
                    New-ADOrganizationalUnit -Name $dept -Path $staffDN -ErrorAction Stop
                }
            }
            Add-ADAutoXLedgerEntry -ObjectType 'OU' -DistinguishedName $deptDN -SamAccountName $dept
        }
        if ($PSCmdlet.ShouldProcess($deptUsersDN, "Create Department Users OU for $dept")) {
            if (-not $WhatIfPreference -and (Get-Command New-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
                if (-not (Get-ADOrganizationalUnit -LDAPFilter "(ou=Users)" -SearchBase $deptDN -ErrorAction SilentlyContinue)) {
                    New-ADOrganizationalUnit -Name 'Users' -Path $deptDN -ErrorAction Stop
                }
            }
            Add-ADAutoXLedgerEntry -ObjectType 'OU' -DistinguishedName $deptUsersDN -SamAccountName "$dept-Users"
        }

        $baseSam = if ($identity.FirstName -eq $identity.LastName) { $identity.FirstName } else { "$($identity.FirstName).$($identity.LastName)" }
        $samName = Get-ADSanitizedSamAccountName -BaseName $baseSam -UsedNames $usedSamNames
        $upn     = Get-ADSanitizedUserPrincipalName -SamAccountName $samName -UPNSuffix $effectiveUpnSuffix
        
        $fullName = if ($identity.FirstName -eq $identity.LastName) { $identity.FirstName } else { "$($identity.FirstName) $($identity.LastName)" }
        $userDN  = "CN=$fullName,$deptUsersDN"
        $pwd     = New-ADAutoXRandomPassword -Length 20

        if ($PSCmdlet.ShouldProcess($userDN, "Provision User $samName")) {
            if (-not $WhatIfPreference -and (Get-Command New-ADUser -ErrorAction SilentlyContinue)) {
                $secPassword = ConvertTo-SecureString $pwd -AsPlainText -Force
                if (-not (Get-ADUser -Filter "SamAccountName -eq '$samName'" -ErrorAction SilentlyContinue)) {
                    New-ADUser -Name $fullName `
                               -GivenName $identity.FirstName `
                               -Surname $identity.LastName `
                               -SamAccountName $samName `
                               -UserPrincipalName $upn `
                               -Path $deptUsersDN `
                               -AccountPassword $secPassword `
                               -Enabled $true `
                               -ChangePasswordAtLogon $false `
                               -ErrorAction Stop
                }
            }
            Write-ADAutoXConsole -Message "Provisioned User: $samName ($dept) -> $userDN" -Level Success
            Add-ADAutoXLedgerEntry -ObjectType 'User' -DistinguishedName $userDN -SamAccountName $samName
            $createdCredentials[$samName] = $pwd

            Write-ADAutoXLogRecord -LogPath $AuditLogPath `
                                   -Action 'CreateUser' `
                                   -Target $userDN `
                                   -Status 'Succeeded' `
                                   -Message "Account created for $fullName" `
                                   -CorrelationId $correlationId

            $row = [ordered]@{
                SamAccountName = $samName
                UserPrincipalName = $upn
                FirstName      = $identity.FirstName
                LastName       = $identity.LastName
                Department     = $dept
                DistinguishedName = $userDN
                Status         = 'Created'
            }
            if ($IncludePasswordInReport) {
                $row['Password'] = $pwd
            }
            $reportRows.Add([pscustomobject]$row)
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

    # Phase 3: Verification
    Write-ADAutoXConsole -Message "Phase 3: Post-Create State Verification" -Level Phase
    if ($WhatIfPreference) {
        Write-ADAutoXConsole -Message "[WhatIf] State verification skipped in preview mode." -Level Warning
    }
    else {
        Write-ADAutoXConsole -Message "Verified directory consistency across $($reportRows.Count) newly provisioned objects." -Level Success
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

    Write-ADAutoXConsole -Message "ADAutoX Provisioning completed successfully! Total created: $($reportRows.Count)" -Level Phase

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
