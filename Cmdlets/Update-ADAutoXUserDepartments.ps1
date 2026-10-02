<#
.SYNOPSIS
    Updates Department and Company attributes on existing ADAutoX user accounts.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [string]$SearchBase = 'OU=Company,DC=corp,DC=local'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-ADUser -ErrorAction SilentlyContinue)) {
    throw "Active Directory PowerShell module is not available on this system."
}

$users = @(Get-ADUser -Filter * -SearchBase $SearchBase)
Write-Host "Found $($users.Count) users under search base: $SearchBase" -ForegroundColor Cyan

foreach ($user in $users) {
    $dnSegments = @($user.DistinguishedName -split ',')
    $dept = $null
    foreach ($segment in $dnSegments) {
        if ($segment -match '^OU=') {
            $candidate = $segment.Substring(3)
            if ($candidate -notin @('Company', 'Staff', 'Users', 'Groups', 'Root')) {
                $dept = $candidate
                break
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($dept)) {
        if ($PSCmdlet.ShouldProcess($user.DistinguishedName, "Update department/company attributes for $($user.SamAccountName)")) {
            Set-ADUser -Identity $user.DistinguishedName -Department $dept -Company 'Company'
            Write-Host "[+] Updated $($user.SamAccountName) -> Department: $dept, Company: Company" -ForegroundColor Green
        }
    }
    else {
        Write-Host "[!] Skipping $($user.SamAccountName): DN structure did not match expected department OU hierarchy." -ForegroundColor Yellow
    }
}

Write-Host "Successfully updated department attributes on $($users.Count) accounts!" -ForegroundColor Green
