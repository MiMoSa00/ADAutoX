Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $rootDir 'ADAutoX.psd1') -Force

function Assert-True {
    param($Condition, $TestName)
    if ($Condition) {
        Write-Host "  [PASS] ${TestName}" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] ${TestName}: Condition evaluated to false." -ForegroundColor Red
        $global:TestFailures++
    }
}

Write-Host "`n=== Running ADAutoX.Security Unit Tests ===" -ForegroundColor Cyan

# Test Random Password Generator
$testPassword = New-ADAutoXRandomPassword -Length 24
Assert-True ($testPassword.Length -eq 24) 'Random password matches requested length of 24'
Assert-True (Test-ADAutoXPasswordComplexity -PasswordText $testPassword) 'Generated random password passes complexity requirements'

# Test Password Complexity Checker
Assert-True (Test-ADAutoXPasswordComplexity -PasswordText 'Password123!') 'Complex password evaluates to true'
Assert-True (-not (Test-ADAutoXPasswordComplexity -PasswordText 'simple')) 'Simple lowercase password evaluates to false'

# Test Cross-Platform ACL Protection
$testAclFile = Join-Path $PSScriptRoot 'test-acl-file.txt'
"test content" | Set-Content -Path $testAclFile -Encoding UTF8
try {
    Protect-ADAutoXFileAcl -Path $testAclFile
    Assert-True (Test-Path -LiteralPath $testAclFile) 'Protect-ADAutoXFileAcl completes safely cross-platform without exception'
}
finally {
    if (Test-Path -LiteralPath $testAclFile) { Remove-Item -LiteralPath $testAclFile -Force }
}

# Test DPAPI Credential Export
$testExportPath = Join-Path $PSScriptRoot 'test-creds.clixml'
if (Test-Path -LiteralPath $testExportPath) { Remove-Item -LiteralPath $testExportPath -Force }

try {
    $map = @{ 'testuser' = 'P@ssw0rd12345!' }
    Export-ADAutoXCredentials -CredentialMap $map -OutputPath $testExportPath -Overwrite
    Assert-True (Test-Path -LiteralPath $testExportPath) 'Credential export file created successfully'
}
finally {
    if (Test-Path -LiteralPath $testExportPath) { Remove-Item -LiteralPath $testExportPath -Force }
}
