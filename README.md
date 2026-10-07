# ADAutoX — Enterprise Active Directory Automation Framework

> **A modular PowerShell framework for bulk identity provisioning, transactional rollback, DPAPI credential protection, structured audit logging, and security posture scanning — no live AD domain controller required to evaluate or test.**

---

## What Is ADAutoX?

ADAutoX is a PowerShell framework built to solve a real problem: **enterprise-scale Active Directory automation is hard to do safely**. Most scripts are monolithic, have no rollback capability, and rely on brittle side effects. ADAutoX fixes that by introducing:

- A **4-phase execution pipeline** (Preflight → Provision → Verify → Report)
- A **persistent transactional rollback ledger** — if provisioning crashes midway, the state is recovered from a secure per-user disk file and the partially created objects are cleaned up automatically (with full integrity checks and validation against the expected company OU).
- **Modular architecture** with clean separation of concerns (6 sub-modules, each independently testable)
- A **standalone unit test suite** that runs without a live domain controller

---

## Architecture at a Glance

```
ADAutoX/
├── ADAutoX.psd1                    ← Module Manifest (v2.1.0, locked exports)
├── ADAutoX.psm1                    ← Root module loader (load-order enforced)
├── ControlConsole.ps1              ← Interactive CLI operator dashboard
│
├── Modules/                        ← Core engine sub-modules
│   ├── ADAutoX.Sanitizer.psm1      ← LDAP/DN escaping, diacritic stripping, custom transliteration
│   ├── ADAutoX.Logging.psm1        ← Structured JSONL audit logger with retry and effective AD actor logging
│   ├── ADAutoX.Security.psm1       ← Cryptographic password generation, DPAPI export, pre-write ACL locking
│   ├── ADAutoX.Context.psm1        ← DC discovery, AD: drive lifecycle, safe splatting
│   ├── ADAutoX.Provisioner.psm1    ← OU/Group builder, crash-safe HMAC-verified rollback ledger
│   └── ADAutoX.Reporting.psm1      ← Audit log parser & security posture scanner
│
├── Cmdlets/                        ← Standard Verb-Noun PowerShell tools
│   ├── Invoke-ADAutoXProvision.ps1 ← Main provisioner (4-phase pipeline)
│   ├── Reset-ADAutoXEnvironment.ps1← Controlled lab teardown
│   ├── Get-ADAutoXAuditReport.ps1  ← Audit log viewer with filtering
│   ├── Manage-ADAutoXUser.ps1      ← User lifecycle (Enable/Disable/Unlock/Reset/Move/Terminate)
│   └── Update-ADAutoXUserDepartments.ps1 ← Backfill script to populate Company/Department attributes
│
├── Data/
│   └── sample-names.txt            ← 35+ identity templates for bulk provisioning
│
└── Tests/
    ├── Sanitizer.Tests.ps1         ← 9 unit tests: LDAP escaping, diacritics, SAM names
    ├── Security.Tests.ps1          ← 6 unit tests: password length, complexity, DPAPI export
    └── Run-Tests.ps1               ← Standalone test runner (no AD needed)
```

---

## Comparison: Legacy Script vs ADAutoX

| Capability | Legacy `AD_PS-automation` | ADAutoX Framework |
| :--- | :--- | :--- |
| **Architecture** | Single monolithic `.ps1` | 6 sub-modules with enforced load order |
| **Module Manifest** | None | `ADAutoX.psd1` v2.1.0 (locked exports, versioning) |
| **Rollback / Crash Recovery** | None | Disk-backed, HMAC-protected ledger per process — crash-safe |
| **Group Provisioning** | None | `<Dept>-Users` + `<Dept>-Admins` groups auto-created |
| **Security: Password RNG** | Predictable modulo bias | Unbiased rejection-sampling + Fisher-Yates shuffle |
| **Unit Testing** | None | 22 automated tests, zero AD dependency |
| **Cross-Platform** | Windows-only | Runs on Windows, Linux, macOS (PowerShell 7+) |
| **Audit Trail** | None | Structured JSONL log with CorrelationID per run |
| **Operator UX** | Run scripts manually | Interactive Control Console (`ControlConsole.ps1`) |
| **Credential Export** | None / plaintext risk | Timestamped DPAPI `.clixml` (Windows) or `chmod 600` (macOS/Linux). Restricted permissions applied *before* secrets are written. |

---

## Key Technical Features

### 1. Idempotent Transactional Rollback Ledger
- **Only objects created in this run** are ledgered — pre-existing AD objects survive any rollback intact.
- The ledger is persisted to a protected, per-user directory (`~/.adautox/ledgers/`) with a per-run filename (`ADAutoX-Ledger-<ID>.json`).
- If the PowerShell process is killed mid-run, the next run detects the orphaned file and offers recovery.
- The ledger is **HMAC-verified** and ensures every object's DN sits underneath the target company OU.
- Rollback failures are properly caught and kept in the ledger for future retry.
- OUs are deleted **deepest-first** (sorted by comma-count in DN) so parent OUs are never deleted before their children.

### 2. Full Security Group Provisioning
- Auto-creates `<Dept>-Users` (member group) and `<Dept>-Admins` (delegated admin group) in a dedicated `Groups` sub-OU per department.
- Uses exact DN lookups to prevent accidentally adopting pre-existing domain-wide groups unless explicitly requested via `-AdoptExistingGroups`.
- Provisioned users are automatically added to their department group.
- First user per department is optionally assigned to the Admins group.

### 3. 4-Phase Execution Pipeline
| Phase | Name | What It Does |
| :--- | :--- | :--- |
| **1** | Preflight | Queries AD for existing OUs, groups, and SAM account collisions using shared parsing logic — no writes |
| **2** | Provisioning | Creates OUs, Security Groups, User accounts; skips duplicates; logs everything |
| **3** | Verification | Re-queries the DC to confirm every ledgered object was actually created (including group memberships) — rolls back if anything is missing |
| **4** | Reporting | Exports CSV report and timestamped credential file. Protects files before writing to avoid TOCTOU races, and sanitizes CSV fields against formula injection. A failure to export credentials halts execution so passwords are not silently lost. |

### 4. Unbiased Cryptographic Password Generation
Standard `Get-Random` has modulo bias when the character pool size doesn't divide evenly into `[int]::MaxValue`. ADAutoX uses a **rejection-sampling loop** over `[System.Security.Cryptography.RandomNumberGenerator]` to eliminate this bias, followed by an independent Fisher-Yates shuffle. All accounts force password change at logon.

### 5. Cross-Platform Identity & Logging
- `[WindowsIdentity]::GetCurrent()` is guarded behind an OS check — on Linux/macOS it falls back to `[Environment]::UserName` / `[Environment]::MachineName`.
- AD context separates local operator identity from AD operational credentials, so you know exactly who authorized the script vs who it connected to AD as.
- `Add-Content` failures in the logger retry, falling back gracefully so a full disk never aborts an already-completed provisioning operation.

---

## Quick Start (No AD Domain Controller Required)

### Step 1 — Run the Automated Unit Tests
```powershell
powershell -ExecutionPolicy Bypass -File .\Tests\Run-Tests.ps1
```
Expected: **22/22 tests pass**.

### Step 2 — Dry-Run the Provisioner (safe, zero AD writes)
```powershell
Import-Module .\ADAutoX.psd1 -Force
.\Cmdlets\Invoke-ADAutoXProvision.ps1 -AccountCount 5 -WhatIf
```
All 4 phases run. Every AD operation is printed as `What if: ...` — nothing is written.

### Step 3 — Launch the Interactive Console
```powershell
.\ControlConsole.ps1
```

### Step 4 — Live Provisioning (requires AD / RSAT)
```powershell
.\Cmdlets\Invoke-ADAutoXProvision.ps1 -AccountCount 20 -RollbackOnFailure
```

### Step 5 — Filter Audit Logs
```powershell
.\Cmdlets\Get-ADAutoXAuditReport.ps1 -Action CreateUser -Status Succeeded
.\Cmdlets\Get-ADAutoXAuditReport.ps1 -Status Failed -Full
```

### Step 6 — Preview Teardown
```powershell
.\Cmdlets\Reset-ADAutoXEnvironment.ps1 -CompanyOuName 'Company' -WhatIf
```

---

## Cloning & Running

```powershell
# Clone the repository
git clone https://github.com/MiMoSa00/ADAutoX.git
cd ADAutoX

# Run unit tests (no admin, no AD, no RSAT required)
powershell -ExecutionPolicy Bypass -File .\Tests\Run-Tests.ps1

# Preview provisioning
powershell -ExecutionPolicy Bypass -Command "Import-Module .\ADAutoX.psd1 -Force; .\Cmdlets\Invoke-ADAutoXProvision.ps1 -AccountCount 5 -WhatIf"
```

---

## Requirements

| Requirement | Details |
| :--- | :--- |
| **PowerShell** | 5.1 (Windows) or 7.x (cross-platform) |
| **Active Directory** | Only needed for live provisioning (`Invoke-ADAutoXProvision.ps1` without `-WhatIf`) |
| **RSAT** | Required on client machines for AD cmdlets (`Install-WindowsFeature RSAT-AD-PowerShell`) |
| **Unit Tests** | No AD, no admin rights required |

---

## Demo Script

A ready-to-run class demo is included:
```powershell
powershell -ExecutionPolicy Bypass -File .\Demo-ADAutoX.ps1
```
This runs the full test suite, then demonstrates the 4-phase dry-run provisioner with narrated output.
