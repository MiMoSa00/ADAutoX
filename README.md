# ADAutoX Framework: Next-Gen Active Directory Automation & Lifecycle Suite

**ADAutoX** is an enterprise-grade, modular PowerShell framework for Active Directory identity provisioning, transactional lifecycle management, DPAPI credential protection, structured JSONL audit analytics, and security posture scanning.

Designed as an architectural evolution over monolithic AD automation scripts, ADAutoX demonstrates modern PowerShell best practices: clean module separation (`.psd1` + `.psm1`), 4-phase execution pipelines, persistent transactional rollback ledgers, unbiased cryptographic security, and standalone unit test suites that run without a live AD domain controller.

---

## Architectural Comparison & What Was Improved

| Metric / Capability | Legacy (`AD_PS-automation`) | Modern (`ADAutoX Framework`) |
| :--- | :--- | :--- |
| **Architecture** | Monolithic script mixing logic & UI | Modular sub-modules (`Context`, `Sanitizer`, `Security`, `Provisioner`, `Reporting`) |
| **Module Manifest** | None (`.psm1` only, no versioning or export controls) | Official Module Manifest (`ADAutoX.psd1` v2.1.0, exported functions, private variables locked) |
| **Naming Conventions** | Mixed/humorous names | Standard PowerShell Verb-Noun Cmdlets (`Invoke-ADAutoXProvision`, `Reset-ADAutoXEnvironment`) |
| **Rollback & Transaction** | Basic cleanup loop on failure | Per-process disk-backed ledger (`Invoke-ADAutoXLedgerRollback`). **Only ledgers objects actually created this run.** Pre-existing AD objects survive rollback intact. OUs deleted deepest-first to prevent spurious "already deleted" errors. |
| **Group Provisioning** | None | Automated creation of Department Security Groups (`<Dept>-Users`), Delegated Admin Groups (`<Dept>-Admins`), and automatic group membership assignment. |
| **Cryptographic Security** | Predictable RNG or modulo bias | Unbiased Rejection Sampling (`Get-ADAutoXUnbiasedRandomInt`) + independent Fisher-Yates shuffle. |
| **Unit Testing** | Syntax parser check | Standalone Automated Unit Test Harness (`Run-Tests.ps1`) — no live AD required. |
| **Operator Experience** | Invoking loose standalone `.ps1` files | Interactive Control Console (`ControlConsole.ps1`) exposing all filter options for audit logs and security scans. |
| **Security & ACLs** | Basic exports | Per-run timestamped DPAPI credential exports (no silent overwrite). Dynamic ACL enforcement (cross-platform safe). |

---

## Repository & Module Layout

```text
ADAutoX/
├── ADAutoX.psd1                    # Module Manifest (Version 2.1.0, VariablesToExport = @())
├── ADAutoX.psm1                    # Root Module Loader (load-order documented, missing files throw immediately)
├── ControlConsole.ps1              # Interactive CLI Menu & Operator Dashboard
│
├── Modules/                        # Sub-Modules (Core Engine) — load order is significant
│   ├── ADAutoX.Sanitizer.psm1      # Level 0: LDAP filter & DN escaping, FormD diacritic stripping
│   ├── ADAutoX.Logging.psm1        # Level 0: Structured JSONL logger, cross-platform identity, fault-tolerant
│   ├── ADAutoX.Security.psm1       # Level 0: Unbiased crypto RNG passwords, DPAPI Clixml exporter
│   ├── ADAutoX.Context.psm1        # Level 1: DC discovery, PSDefaultParameterValues, AD: drive lifecycle
│   ├── ADAutoX.Provisioner.psm1    # Level 2: OU/group builder, per-PID crash-safe rollback ledger
│   └── ADAutoX.Reporting.psm1      # Level 2: JSONL log parser & security posture scanner
│
├── Cmdlets/                        # Standard Verb-Noun CLI Tools
│   ├── Invoke-ADAutoXProvision.ps1 # 4-Phase Provisioning (Preflight→Provision→Verify→Report)
│   ├── Reset-ADAutoXEnvironment.ps1# Controlled Lab Teardown (real WhatIf preview, sanitized DN, clear error handling)
│   ├── Get-ADAutoXAuditReport.ps1  # Audit Log Viewer (-Full flag shows all fields incl. Message/Details)
│   └── Manage-ADAutoXUser.ps1      # Lifecycle Management (all 6 actions; WhatIf validates user first)
│
├── Data/                           # Data Sources
│   └── sample-names.txt            # Sample identity templates (35+ names)
│
└── Tests/                          # Automated Unit Test Suite
    ├── Sanitizer.Tests.ps1         # Unit tests for LDAP/DN escaping & diacritic stripping
    ├── Security.Tests.ps1          # Unit tests for password generator & DPAPI export
    └── Run-Tests.ps1               # Standalone test runner harness
```

---

## Key Technical Features & Designs

### 1. Strict Idempotent Ledger & Safe Rollback
- **Only objects created during this specific run** are added to the ledger. Pre-existing OUs, groups, and users are detected, skipped, and never ledgered.
- Rollback deletes OUs **deepest-first** (sorted by DN depth) so children are never deleted twice.
- The ledger is persisted to a **per-process temp file** (`ADAutoX-Ledger-<PID>.json`) — two concurrent runs never clobber each other, and a hard process kill preserves the state for recovery.

### 2. Full Security Group Provisioning
- Creates Department Security Groups (`<Dept>-Users`) under a dedicated `Groups` sub-OU per department.
- Creates Delegated Admin Groups (`<Dept>-Admins`) when `-CreateDepartmentAdministrators` is enabled.
- Automatically adds provisioned users to their department group; assigns the first user per department to the admin group.

### 3. Real 4-Phase Pipeline
- **Phase 1 (Preflight)**: Queries AD for existing OUs, security groups, and SAM account collisions **for all target accounts** (not just first 20). Uses proper PowerShell `-Filter` variables (not LDAP-escaped values) for group lookups. Surfaces real connectivity errors instead of silently treating them as "nothing found."
- **Phase 2 (Provisioning)**: Creates OUs, Groups, and Users. Duplicate accounts are logged as `Skipped` and excluded from the ledger and password export.
- **Phase 3 (Verification)**: Queries the target DC to confirm every ledgered object exists. **Throws and triggers rollback** if any verification fails.
- **Phase 4 (Reporting)**: Isolated in its own try/catch — a locked CSV or full disk does **not** trigger rollback of successfully provisioned accounts.

### 4. Cross-Platform Safety
- `Write-ADAutoXLogRecord` uses `[WindowsIdentity]::GetCurrent()` on Windows and falls back to `$env:USER`/`$env:COMPUTERNAME` on Linux/macOS.
- `Protect-ADAutoXFileAcl` OS-checks before applying NTFS ACLs.
- `Logging.psm1` uses a try/catch on `Add-Content` — a disk-full or locked-file error issues a warning instead of aborting an already-completed AD operation.

### 5. Timestamped Credential Exports
- Each run writes to a unique `user-passwords-<YYYY-MM-DD-HHmmss>.clixml` file by default, so no run silently overwrites another run's passwords.

---

## Quick Start Guide

### 1. Run Automated Unit Tests (no AD required)
```powershell
powershell -ExecutionPolicy Bypass -File .\Tests\Run-Tests.ps1
```

### 2. Launch the Interactive Control Console
```powershell
powershell -ExecutionPolicy Bypass -File .\ControlConsole.ps1
```

### 3. Preview Provisioning (`-WhatIf`, no AD writes)
```powershell
.\Cmdlets\Invoke-ADAutoXProvision.ps1 -AccountCount 10 -WhatIf
```

### 4. Live Provisioning (rollback on failure enabled by default)
```powershell
.\Cmdlets\Invoke-ADAutoXProvision.ps1 -AccountCount 20
```

### 5. Filter Audit Logs
```powershell
# Summary view
.\Cmdlets\Get-ADAutoXAuditReport.ps1 -Action CreateUser -Status Succeeded
# Full detail view with Message and Details fields
.\Cmdlets\Get-ADAutoXAuditReport.ps1 -Status Failed -Full
```

### 6. Preview Teardown (shows real object counts)
```powershell
.\Cmdlets\Reset-ADAutoXEnvironment.ps1 -CompanyOuName 'Company' -WhatIf
```

### 7. Perform Teardown
```powershell
.\Cmdlets\Reset-ADAutoXEnvironment.ps1 -CompanyOuName 'Company' -AllowDestructiveOperation
```
