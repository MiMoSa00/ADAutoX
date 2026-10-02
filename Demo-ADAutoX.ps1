<#
.SYNOPSIS
    ADAutoX Class Demo Script - runs the unit test suite then the 4-phase dry-run provisioner.

.DESCRIPTION
    Safe to run anywhere. No Active Directory, no admin rights, no RSAT required.
    Every provisioning action runs in -WhatIf mode (zero writes to any directory).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Demo-ADAutoX.ps1
#>

$ErrorActionPreference = 'Stop'
$rootDir = $PSScriptRoot

function Write-Banner {
    param([string]$Text, [ConsoleColor]$Color = 'Cyan')
    $line = '=' * 70
    Write-Host ""
    Write-Host $line -ForegroundColor $Color
    Write-Host "  $Text" -ForegroundColor $Color
    Write-Host "$line"  -ForegroundColor $Color
    Write-Host ""
}

function Write-Step {
    param([string]$Number, [string]$Title)
    Write-Host ""
    Write-Host "  [ STEP $Number ] $Title" -ForegroundColor Yellow
    Write-Host "  $('-' * 60)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
Write-Banner "ADAutoX Framework - Class Demo" -Color Cyan
Write-Host "  GitHub: https://github.com/MiMoSa00/ADAutoX" -ForegroundColor Gray
Write-Host "  This demo is 100% safe - no AD writes, no admin rights needed." -ForegroundColor Gray
Write-Host ""
Start-Sleep -Seconds 2

# ---------------------------------------------------------------------------
Write-Step "1" "UNIT TEST SUITE (22 tests - no Active Directory required)"
Write-Host "  Testing: LDAP escaping, DN sanitization, diacritic stripping," -ForegroundColor Gray
Write-Host "           SAM account deduplication, password complexity," -ForegroundColor Gray
Write-Host "           DPAPI credential export, and manifest integrity." -ForegroundColor Gray
Write-Host ""
Start-Sleep -Seconds 1

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $rootDir 'Tests\Run-Tests.ps1')

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "  [FAIL] Unit tests failed - stopping demo." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
Write-Step "2" "4-PHASE DRY-RUN PROVISIONER (-WhatIf, zero writes)"
Write-Host "  This shows what ADAutoX WOULD do against a real domain:" -ForegroundColor Gray
Write-Host "  Phase 1: Preflight  - query existing OUs, groups, SAM collisions" -ForegroundColor Gray
Write-Host "  Phase 2: Provision  - OUs, Security Groups, User Accounts" -ForegroundColor Gray
Write-Host "  Phase 3: Verify     - confirm every created object exists in AD" -ForegroundColor Gray
Write-Host "  Phase 4: Report     - CSV report and timestamped credential export" -ForegroundColor Gray
Write-Host ""
Write-Host "  Target: 5 accounts across IT, HR, Finance, Sales departments" -ForegroundColor Gray
Write-Host "  Domain: lab.local (simulated - no live DC required)" -ForegroundColor Gray
Write-Host ""
Start-Sleep -Seconds 2

& powershell -NoProfile -ExecutionPolicy Bypass -Command "
    `$ErrorActionPreference = 'Stop'
    Import-Module '$rootDir\ADAutoX.psd1' -Force
    & '$rootDir\Cmdlets\Invoke-ADAutoXProvision.ps1' -AccountCount 5 -WhatIf
"

# ---------------------------------------------------------------------------
Write-Step "3" "ARCHITECTURE SUMMARY"
Write-Host ""
Write-Host "  MODULE LAYOUT:" -ForegroundColor White
Write-Host "  +-- ADAutoX.Sanitizer    - LDAP/DN escaping, diacritic normalization" -ForegroundColor Gray
Write-Host "  +-- ADAutoX.Logging      - JSONL audit trail, cross-platform identity" -ForegroundColor Gray
Write-Host "  +-- ADAutoX.Security     - Unbiased crypto RNG, DPAPI credential export" -ForegroundColor Gray
Write-Host "  +-- ADAutoX.Context      - DC discovery, AD: drive lifecycle" -ForegroundColor Gray
Write-Host "  +-- ADAutoX.Provisioner  - OU/Group builder, crash-safe rollback ledger" -ForegroundColor Gray
Write-Host "  +-- ADAutoX.Reporting    - Audit log parser, security posture scanner" -ForegroundColor Gray
Write-Host ""
Write-Host "  KEY IMPROVEMENTS OVER LEGACY SCRIPTS:" -ForegroundColor White
Write-Host "  [+] Transactional rollback  - partial failures are auto-reversed" -ForegroundColor Green
Write-Host "  [+] Crash recovery ledger   - survives hard process kills" -ForegroundColor Green
Write-Host "  [+] Unbiased password RNG   - rejection sampling, no modulo bias" -ForegroundColor Green
Write-Host "  [+] 22 automated unit tests - runs in CI with no AD dependency" -ForegroundColor Green
Write-Host "  [+] Cross-platform (Windows / Linux / macOS)" -ForegroundColor Green
Write-Host "  [+] Structured JSONL audit log with CorrelationID per run" -ForegroundColor Green

# ---------------------------------------------------------------------------
Write-Banner "Demo Complete!" -Color Green
Write-Host "  To explore further, launch the interactive console:" -ForegroundColor White
Write-Host "    powershell -ExecutionPolicy Bypass -File .\ControlConsole.ps1" -ForegroundColor Yellow
Write-Host ""
Write-Host "  GitHub repo:" -ForegroundColor White
Write-Host "    https://github.com/MiMoSa00/ADAutoX" -ForegroundColor Yellow
Write-Host ""
