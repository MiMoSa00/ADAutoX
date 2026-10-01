Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $rootDir 'ADAutoX.psd1') -Force

function Assert-Equal {
    param($Actual, $Expected, $TestName)
    if ($Actual -eq $Expected) {
        Write-Host "  [PASS] ${TestName}" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] ${TestName}: Expected '${Expected}', got '${Actual}'" -ForegroundColor Red
        $global:TestFailures++
    }
}

Write-Host "`n=== Running ADAutoX.Sanitizer Unit Tests ===" -ForegroundColor Cyan

# Test LDAP Filter Escaping
Assert-Equal (ConvertTo-ADLdapFilter -Value 'John (Admin)*') 'John \28Admin\29\2a' 'Escapes parenthesis and asterisk in LDAP filter'
Assert-Equal (ConvertTo-ADLdapFilter -Value 'Domain\User') 'Domain\5cUser' 'Escapes backslash in LDAP filter'

# Test DN Value Escaping
Assert-Equal (ConvertTo-ADDistinguishedNameValue -Value 'Smith, John') 'Smith\2c John' 'Escapes comma in DN'
Assert-Equal (ConvertTo-ADDistinguishedNameValue -Value 'O+Connor') 'O\2bConnor' 'Escapes plus in DN'

# Test SAM Account Name Sanitization & Diacritics
$diacriticName = "Ren$([char]0x00E9)e.M$([char]0x00FC)ller"
Assert-Equal (Get-ADSanitizedSamAccountName -BaseName $diacriticName) 'renee.muller' 'Strips diacritics and converts to lowercase'
Assert-Equal (Get-ADSanitizedSamAccountName -BaseName 'Jean-Luc Picard') 'jeanlucpicard' 'Strips hyphens and spaces'

# Test Collision Handling
$usedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$first  = Get-ADSanitizedSamAccountName -BaseName 'chinedu.okafor' -UsedNames $usedSet
$second = Get-ADSanitizedSamAccountName -BaseName 'chinedu.okafor' -UsedNames $usedSet
$third  = Get-ADSanitizedSamAccountName -BaseName 'chinedu.okafor' -UsedNames $usedSet

Assert-Equal $first 'chinedu.okafor' 'First SAM account name generated without suffix'
Assert-Equal $second 'chinedu.okafor2' 'Second duplicate SAM account name receives 2 suffix'
Assert-Equal $third 'chinedu.okafor3' 'Third duplicate SAM account name receives 3 suffix'
