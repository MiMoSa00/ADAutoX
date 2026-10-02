# ADAutoX Framework: Next-Gen Active Directory Automation & Lifecycle Suite

**ADAutoX** is an enterprise-grade, modular PowerShell framework for Active Directory identity provisioning, transactional lifecycle management, DPAPI credential protection, structured JSONL audit analytics, and security posture scanning.

Designed as an architectural evolution over monolithic AD automation scripts, ADAutoX demonstrates modern PowerShell best practices: clean module separation (`.psd1` + `.psm1`), 4-phase execution pipelines, persistent transactional rollback ledgers, unbiased cryptographic security, and standalone unit test suites.

---

## Architectural Comparison & What Was Improved

| Metric / Capability | Legacy (`AD_PS-automation`) | Modern (`ADAutoX Framework`) |
| :--- | :--- | :--- |
| **Architecture** | Monolithic script mixing logic & UI | Modular sub-modules (`Context`, `Sanitizer`, `Security`, `Provisioner`, `Reporting`) |
| **Module Manifest** | None (`.psm1` only, no versioning or export controls) | Official Module Manifest (`ADAutoX.psd1` with versioning, exported functions, metadata) |
| **Naming Conventions** | Mixed/humorous names | Standard PowerShell Verb-Noun Cmdlets (`Invoke-ADAutoXProvision`, `Reset-ADAutoXEnvironment`) |
| **Rollback & Transaction** | Basic cleanup loop on failure | Persistent & In-memory Transactional Ledger (`Initialize-ADAutoXLedger`, `Invoke-ADAutoXLedgerRollback` with LocalAppData persistence). A new run refuses to start if a previous ledger is still pending unless you explicitly discard it. Only objects created during the current run are eligible for rollback. |
| **Group Provisioning** | Manual or missing | Automated creation of Department Security Groups (`<Dept>-Users`), plus `<Dept>-Admins` when the switch is enabled and the first provisioned user is assigned to it. |
| **Cryptographic Security** | Predictable RNG or modulo bias | Unbiased Rejection Sampling RNG (`Get-ADAutoXUnbiasedRandomInt`) and independent Fisher-Yates shuffle. |
| **Unit Testing** | Syntax parser check | Standalone Automated Unit Test Harness (`Run-Tests.ps1`) testing sanitization, diacritics, crypto & cross-platform ACL safety. |
| **Operator Experience** | Invoking loose standalone `.ps1` files | Interactive Control Console (`ControlConsole.ps1`) with menu-driven execution |
| **Security & ACLs** | Basic exports | Dynamic ACL locking on export & sensitive CSV files to executing Windows SID (cross-platform safe). |

---

## Repository & Module Layout

```text
ADAutoX/
├── ADAutoX.psd1                    # Module Manifest (Version 2.0.0, GUID, Function Exports)
├── ADAutoX.psm1                    # Root Module Loader
├── ControlConsole.ps1              # Interactive CLI Menu & Operator Dashboard
│
├── Modules/                        # Sub-Modules (Core Engine)
│   ├── ADAutoX.Context.psm1        # Domain Controller discovery & PSDefaultParameterValues manager
│   ├── ADAutoX.Sanitizer.psm1      # LDAP filter escaping, DN escaping, FormD unicode diacritic stripper
│   ├── ADAutoX.Security.psm1       # Unbiased cryptographic RNG password generator, DPAPI Clixml exporter
│   ├── ADAutoX.Provisioner.psm1    # OU hierarchy builder, security groups, persistent rollback ledger
│   ├── ADAutoX.Logging.psm1        # Structured JSONL logger & correlation ID generator
│   └── ADAutoX.Reporting.psm1      # JSONL log parser, CSV exporter & security posture scanner
│
├── Cmdlets/                        # Standard Verb-Noun CLI Tools
│   ├── Invoke-ADAutoXProvision.ps1 # 4-Phase Provisioning Controller (Preflight, Provision, Verify, Report)
│   ├── Reset-ADAutoXEnvironment.ps1# Controlled Lab Teardown Tool (-AllowDestructiveOperation)
│   ├── Get-ADAutoXAuditReport.ps1  # Audit Log Filtering & Analytics CLI
│   └── Manage-ADAutoXUser.ps1      # Lifecycle Management (Enable, Disable, Unlock, ResetPassword, Terminate)
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

## Key Technical Features & Enhancements

### 1. Strict Ledger Scoping & Safe Rollback
- Objects that already exist in Active Directory (OUs, Groups, Users) are detected and skipped.
- Only objects **actually created during the current execution** are added to the transaction ledger (`Add-ADAutoXLedgerEntry`).
- Rollback only removes created objects, protecting pre-existing production OUs and users from accidental deletion.
- The ledger persists under LocalAppData and blocks a new run until an unresolved prior ledger is either rolled back or explicitly discarded.

### 2. Full Security Group Provisioning
- Automatically creates Department Security Groups (`<Dept>-Users`) and places provisioned users inside.
- Creates Delegated Admin Groups (`<Dept>-Admins`) when `-CreateDepartmentAdministrators` is set, and the first provisioned user in that department is assigned to it.

### 3. Real Multi-Phase Pipeline
- **Phase 1 (Preflight)**: Actively queries Active Directory to check for existing OUs, security groups, and potential SAM account collisions before mutating state.
- **Phase 2 (Provisioning)**: Creates OUs, Groups, and Users with full LDAP/DN sanitization (`ConvertTo-ADLdapFilter`, `ConvertTo-ADDistinguishedNameValue`).
- **Phase 3 (Verification)**: Actively queries the target Domain Controller (`Get-ADUser`, `Get-ADGroup`, `Get-ADOrganizationalUnit`) to confirm object existence and properties.
- **Phase 4 (Reporting)**: Generates audit logs (`ADAutoX-Audit.jsonl`), CSV reports, and DPAPI-encrypted credential backups (`user-passwords.clixml`).

### 4. Cryptographically Unbiased Security
- Uses rejection sampling (`Get-ADAutoXUnbiasedRandomInt`) to eliminate modulo bias.
- Uses independent calls to `RandomNumberGenerator` for Fisher-Yates shuffling to ensure cryptographically strong, uniform password generation.
- Cross-platform safe ACL enforcement (`Protect-ADAutoXFileAcl`).

---

## Quick Start Guide

### 1. Run Automated Unit Tests
Validate framework logic locally:
```powershell
powershell -ExecutionPolicy Bypass -File .\Tests\Run-Tests.ps1
```

### 2. Launch the Interactive Control Console
For a guided menu experience:
```powershell
powershell -ExecutionPolicy Bypass -File .\ControlConsole.ps1
```

### 3. Preview Provisioning via CLI (`-WhatIf`)
```powershell
.\Cmdlets\Invoke-ADAutoXProvision.ps1 -AccountCount 20 -WhatIf
```

### 4. Execute Live Provisioning (Rollback Enabled by Default)
```powershell
.\Cmdlets\Invoke-ADAutoXProvision.ps1 -AccountCount 20 -RollbackOnFailure
```

### 5. Filter Audit Logs
```powershell
.\Cmdlets\Get-ADAutoXAuditReport.ps1 -Action CreateUser -Status Succeeded
```

### 6. Reset Lab Environment
```powershell
.\Cmdlets\Reset-ADAutoXEnvironment.ps1 -AllowDestructiveOperation
```
