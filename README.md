# ADAutoX Framework: Next-Gen Active Directory Automation & Lifecycle Suite

**ADAutoX** is an enterprise-grade, modular PowerShell framework for Active Directory identity provisioning, transactional lifecycle management, DPAPI credential protection, structured JSONL audit analytics, and security posture scanning.

Designed as an architectural evolution over monolithic AD automation scripts, ADAutoX demonstrates modern PowerShell best practices: clean module separation (`.psd1` + `.psm1`), 4-phase execution pipelines, transactional rollback ledgers, and mock-free unit test suites.

---

## Architectural Comparison & What Was Improved

| Metric / Capability | Legacy (`AD_PS-automation`) | Modern (`ADAutoX Framework`) |
| :--- | :--- | :--- |
| **Architecture** | Monolithic 2,470-line script (`mark42.ps1`) mixing logic & UI | Modular sub-modules (`Context`, `Sanitizer`, `Security`, `Provisioner`, `Reporting`) |
| **Module Manifest** | None (`.psm1` only, no versioning or export controls) | Official Module Manifest (`ADAutoX.psd1` with versioning, exported functions, metadata) |
| **Naming Conventions** | Mixed/humorous names (`mark42.ps1`, `2_RESET_TEST_USERS.ps1`) | Standard PowerShell Verb-Noun Cmdlets (`Invoke-ADAutoXProvision`, `Reset-ADAutoXEnvironment`) |
| **Rollback & Transaction** | Basic cleanup loop on failure | In-memory Transactional Ledger (`Initialize-ADAutoXLedger`, `Invoke-ADAutoXLedgerRollback`) |
| **Unit Testing** | Syntax parser check (`validate_repo.ps1`) | Automated Pester-style Unit Test Suite (`Run-Tests.ps1`) testing sanitization, diacritics & crypto without needing AD |
| **Operator Experience** | Invoking 20+ loose standalone `.ps1` files | Interactive Control Console (`ControlConsole.ps1`) with menu-driven execution |
| **Security & ACLs** | Export-Clixml DPAPI | Dynamic ACL locking on export & sensitive CSV files to executing Windows SID |

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
│   ├── ADAutoX.Security.psm1       # Cryptographically strong RNG password generator, DPAPI Clixml exporter
│   ├── ADAutoX.Provisioner.psm1    # OU hierarchy builder, group delegation, transactional rollback ledger
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
│   └── sample-names.txt            # Sample identity templates
│
└── Tests/                          # Automated Unit Test Suite
    ├── Sanitizer.Tests.ps1         # Unit tests for LDAP/DN escaping & diacritic stripping
    ├── Security.Tests.ps1          # Unit tests for password generator & DPAPI export
    └── Run-Tests.ps1               # Test execution script
```

---

## Step-by-Step Guide: How to Build Something Similar (From Scratch)

### Step 1: Design a Proper Module Manifest (`.psd1`)
Avoid relying on loose `.ps1` or bare `.psm1` files. A module manifest (`.psd1`) provides formal metadata, versioning, GUID isolation, and explicit control over exported functions.

### Step 2: Implement Robust Input Sanitization (LDAP & DN Escaping)
Active Directory LDAP queries and Distinguished Names (DNs) are susceptible to special character injection.
- Escape LDAP filter special characters: `\`, `*`, `(`, `)`, `NUL`.
- Escape DN special characters: `,`, `=`, `+`, `<`, `>`, `#`, `;`, `\`, `"`, leading/trailing spaces.
- Normalize Unicode identities using `NormalizationForm.FormD` to strip accents/diacritics (e.g., `Renée` -> `renee`).

### Step 3: Enforce Cryptographic Password Security & DPAPI Storage
- Use `System.Security.Cryptography.RandomNumberGenerator` instead of `Get-Random` (which is predictable).
- Require at least 3 out of 4 password categories (uppercase, lowercase, numbers, symbols).
- Protect exported credential files using `Export-Clixml` (which uses DPAPI tied to the Windows identity) and explicitly restrict File ACLs using `System.Security.AccessControl.FileSystemAccessRule`.

### Step 4: Implement a Transactional Rollback Ledger
When bulk-provisioning AD objects (OUs, Groups, Users), failures halfway through leave orphaned resources.
- Record every created object in an in-memory ledger (`Add-ADAutoXLedgerEntry`).
- On failure, trigger `Invoke-ADAutoXLedgerRollback` to tear down created objects in reverse dependency order (Users -> Groups -> OUs).

### Step 5: Adopt standard PowerShell `-WhatIf` / `-Confirm` Semantics
Use `[CmdletBinding(SupportsShouldProcess)]` on all public entry points instead of creating custom flags like `-DryRun`. This ensures full compatibility with native PowerShell tooling.

### Step 6: Create an Automated Mock-Free Unit Test Suite
Write unit tests for non-AD dependent logic (sanitizers, password generators, log formatters, credential exporters). This allows continuous validation in CI/CD environments without needing a live Domain Controller.

---

## Quick Start Guide

### 1. Run Automated Unit Tests
Validate the framework logic locally:
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
.\Cmdlets\Invoke-ADAutoXProvision.ps1 -AccountCount 10 -WhatIf
```

### 4. Execute Live Provisioning
```powershell
.\Cmdlets\Invoke-ADAutoXProvision.ps1 -AccountCount 10
```

### 5. Filter Audit Logs
```powershell
.\Cmdlets\Get-ADAutoXAuditReport.ps1 -Action CreateUser -Status Succeeded
```

### 6. Reset Lab Environment
```powershell
.\Cmdlets\Reset-ADAutoXEnvironment.ps1 -AllowDestructiveOperation
```
