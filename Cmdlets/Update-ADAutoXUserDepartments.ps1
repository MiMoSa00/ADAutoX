<#
.SYNOPSIS
    Updates Department and Company attributes on existing ADAutoX user accounts.
#>
[CmdletBinding()]
param(
    [string]$SearchBase = 'OU=Company,DC=corp,DC=local'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-ADUser -ErrorAction SilentlyContinue)) {
    throw "Active Directory PowerShell module is not available on this system."
}

$users = Get-ADUser -Filter * -SearchBase $SearchBase
Write-Host "Found $($users.Count) users under search base: $SearchBase" -ForegroundColor Cyan

foreach ($user in $users) {
    # Extract department from DN (e.g. CN=...,OU=Users,OU=IT,OU=Staff,OU=Company,DC=corp,DC=local)
    $dnParts = $user.DistinguishedName -split ',OU='
    if ($dnParts.Count -ge 3) {
        $dept = $dnParts[2]
        Set-ADUser -Identity $user.DistinguishedName -Department $dept -Company 'Company'
        Write-Host "[+] Updated $($user.SamAccountName) -> Department: $dept, Company: Company" -ForegroundColor Green
    }
    else {
        Write-Host "[!] Skipping $($user.SamAccountName): DN structure did not match expected department OU hierarchy." -ForegroundColor Yellow
    }
}

Write-Host "Successfully updated department attributes on $($users.Count) accounts!" -ForegroundColor Green
