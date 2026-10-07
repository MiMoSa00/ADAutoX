<#
.SYNOPSIS
    Updates Department and Company attributes on existing ADAutoX user accounts.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    # BUG-37: Remove hard-coded domain and allow user to specify SearchBase/StaffOuName
    [string]$SearchBase = '',
    [string]$StaffOuName = 'Staff'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-ADUser -ErrorAction SilentlyContinue)) {
    throw "Active Directory PowerShell module is not available on this system."
}

if ([string]::IsNullOrWhiteSpace($SearchBase)) {
    try {
        $domain = Get-ADDomain -ErrorAction Stop
        $SearchBase = $domain.DistinguishedName
        Write-Host "No SearchBase provided. Defaulting to current domain root: $SearchBase" -ForegroundColor Cyan
    }
    catch {
        throw "Could not determine domain root. Please specify -SearchBase."
    }
}

# BUG-38: Read the OU names via Get-ADOrganizationalUnit instead of regex on escaped DNs
$users = @(Get-ADUser -Filter * -SearchBase $SearchBase -Properties DistinguishedName)
Write-Host "Found $($users.Count) total users under search base: $SearchBase" -ForegroundColor Cyan

$updatedCount = 0
$skippedCount = 0

foreach ($user in $users) {
    try {
        # Extract Department and Company from DN string by matching OU=... blocks
        # Wait, BUG-38 says: "Read the OU names via Get-ADOrganizationalUnit (or unescape the DN)."
        # Better: let's parse the DN. A DN is a comma-separated list of RDNs.
        # But commas can be escaped. The best way is to fetch the parent OUs.
        
        $parent = Get-ADObject -Identity $user.DistinguishedName -Properties Parent -ErrorAction Stop
        $parentDn = $parent.Parent

        if ($parentDn -match "^OU=Users,OU=(?<dept>.+?),OU=$StaffOuName,OU=(?<company>.+?),") {
            # Unescape commas in extracted names if regex is used, but a better way is:
            # $parentDn is OU=Users,OU=Dept,OU=Staff,OU=Company,...
            
            # Since AD PowerShell doesn't have an easy DN parser cmdlet built-in for PS5, we can use LDAP unescaping.
            # But since BUG-38 says "Read the OU names via Get-ADOrganizationalUnit", let's do exactly that.
            
            $usersOu = Get-ADOrganizationalUnit -Identity $parentDn -ErrorAction Stop
            if ($usersOu.Name -ne 'Users') {
                Write-Host "[!] Skipping $($user.SamAccountName): Direct parent is not 'Users' OU." -ForegroundColor Yellow
                $skippedCount++
                continue
            }
            
            $deptOuDn = (Get-ADObject -Identity $usersOu.DistinguishedName -Properties Parent).Parent
            $deptOu = Get-ADOrganizationalUnit -Identity $deptOuDn -ErrorAction Stop
            $dept = $deptOu.Name
            
            $staffOuDn = (Get-ADObject -Identity $deptOu.DistinguishedName -Properties Parent).Parent
            $staffOu = Get-ADOrganizationalUnit -Identity $staffOuDn -ErrorAction Stop
            if ($staffOu.Name -ne $StaffOuName) {
                Write-Host "[!] Skipping $($user.SamAccountName): Expected staff OU '$StaffOuName' but found '$($staffOu.Name)'." -ForegroundColor Yellow
                $skippedCount++
                continue
            }
            
            $companyOuDn = (Get-ADObject -Identity $staffOu.DistinguishedName -Properties Parent).Parent
            $companyOu = Get-ADOrganizationalUnit -Identity $companyOuDn -ErrorAction Stop
            $companyName = $companyOu.Name

            if ($PSCmdlet.ShouldProcess($user.DistinguishedName, "Update department/company attributes for $($user.SamAccountName)")) {
                Set-ADUser -Identity $user.DistinguishedName -Department $dept -Company $companyName -ErrorAction Stop
                Write-Host "[+] Updated $($user.SamAccountName) -> Department: $dept, Company: $companyName" -ForegroundColor Green
                $updatedCount++
            }
        }
        else {
            Write-Host "[!] Skipping $($user.SamAccountName): DN structure did not match expected department OU hierarchy." -ForegroundColor Yellow
            $skippedCount++
        }
    }
    catch {
        Write-Host "[-] Failed to process $($user.SamAccountName): $($_.Exception.Message)" -ForegroundColor Red
        $skippedCount++
    }
}

# BUG-38: Count updated and skipped separately, make the final message honest under -WhatIf
if ($WhatIfPreference) {
    Write-Host "Preview complete: $updatedCount accounts would be updated ($skippedCount skipped/ineligible)." -ForegroundColor Cyan
} else {
    Write-Host "Successfully updated department attributes on $updatedCount accounts! ($skippedCount skipped/ineligible)" -ForegroundColor Green
}
