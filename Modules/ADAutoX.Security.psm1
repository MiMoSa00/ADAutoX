Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ADAutoXUnbiasedRandomInt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.RandomNumberGenerator]$Rng,

        [Parameter(Mandatory = $true)]
        [int]$MaxExclusive
    )

    if ($MaxExclusive -le 1) { return 0 }

    # Rejection sampling to eliminate modulo bias
    $remainder = 256 % $MaxExclusive
    $threshold = 256 - $remainder

    $buffer = New-Object byte[] 1
    do {
        $Rng.GetBytes($buffer)
    } while ($buffer[0] -ge $threshold)

    return ($buffer[0] % $MaxExclusive)
}

function New-ADAutoXRandomPassword {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [ValidateRange(12, 256)]
        [int]$Length = 24
    )

    $characterSet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*()-_=+[]{};:,.<>?'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    try {
        $requiredSets = @(
            'ABCDEFGHJKLMNPQRSTUVWXYZ',
            'abcdefghijkmnopqrstuvwxyz',
            '23456789',
            '!@#$%^&*()-_=+[]{};:,.<>?'
        )

        $passwordChars = [System.Collections.Generic.List[char]]::new()
        foreach ($set in $requiredSets) {
            $idx = Get-ADAutoXUnbiasedRandomInt -Rng $rng -MaxExclusive $set.Length
            $passwordChars.Add($set[$idx])
        }

        for ($i = $passwordChars.Count; $i -lt $Length; $i++) {
            $idx = Get-ADAutoXUnbiasedRandomInt -Rng $rng -MaxExclusive $characterSet.Length
            $passwordChars.Add($characterSet[$idx])
        }

        # Fisher-Yates shuffle using fresh, independent cryptographically secure random numbers
        for ($i = $passwordChars.Count - 1; $i -gt 0; $i--) {
            $swapIdx = Get-ADAutoXUnbiasedRandomInt -Rng $rng -MaxExclusive ($i + 1)
            $tmp = $passwordChars[$i]
            $passwordChars[$i] = $passwordChars[$swapIdx]
            $passwordChars[$swapIdx] = $tmp
        }

        return -join $passwordChars
    }
    finally {
        $rng.Dispose()
    }
}

function Test-ADAutoXPasswordComplexity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PasswordText
    )

    $categoryCount = 0
    if ($PasswordText -match '[a-z]') { $categoryCount++ }
    if ($PasswordText -match '[A-Z]') { $categoryCount++ }
    if ($PasswordText -match '\d')     { $categoryCount++ }
    if ($PasswordText -match '[^A-Za-z0-9]') { $categoryCount++ }

    return $categoryCount -ge 3
}

function Test-ADAutoXIsWindowsOS {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::Windows)
    }
    return $env:OS -like '*Windows*'
}

function Protect-ADAutoXFileAcl {
    <#
    .SYNOPSIS
        Restricts a file's ACL so only the current user has access (Windows),
        or applies chmod 600 (Linux/macOS). Returns $true if protection succeeded.

    .NOTES
        BUG-08: This function now returns a boolean so callers can detect failure.
        BUG-09: On non-Windows it applies chmod 600 instead of silently doing nothing.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $fullPath  = [System.IO.Path]::GetFullPath($Path)
    $isWindows = Test-ADAutoXIsWindowsOS

    if ($isWindows) {
        $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($null -eq $currentIdentity -or $null -eq $currentIdentity.User) {
            Write-Warning "[ADAutoX] Protect-ADAutoXFileAcl: could not retrieve current Windows identity for '$fullPath'. File is NOT protected."
            return $false
        }

        try {
            $acl = Get-Acl -LiteralPath $fullPath
            $currentUser = $currentIdentity.User
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
                $null = $acl.RemoveAccessRule($rule)
            }
            $fullControlRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $currentUser,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow)
            $acl.AddAccessRule($fullControlRule)
            Set-Acl -LiteralPath $fullPath -AclObject $acl -ErrorAction Stop
            return $true
        }
        catch {
            # Surface as a loud warning (BUG-08), not a verbose message
            Write-Warning "[ADAutoX] ACL enforcement FAILED on '${fullPath}': $($_.Exception.Message). File permissions have NOT been restricted."
            return $false
        }
    }
    else {
        # BUG-09: Apply chmod 600 on Linux/macOS instead of doing nothing
        try {
            & chmod 600 $fullPath 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                return $true
            }
            else {
                Write-Warning "[ADAutoX] chmod 600 failed on '${fullPath}'. File permissions have NOT been restricted."
                return $false
            }
        }
        catch {
            Write-Warning "[ADAutoX] Could not apply chmod 600 on '${fullPath}': $($_.Exception.Message). File permissions have NOT been restricted."
            return $false
        }
    }
}

function New-ADAutoXProtectedFile {
    <#
    .SYNOPSIS
        Creates a new empty file and immediately locks its permissions BEFORE any
        secret content is written into it.

    .NOTES
        BUG-08: Secrets must never exist in a file that has broad permissions, even
        momentarily. Create the file, lock it, then write secrets.
        Returns $true if the file was created and protected successfully.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath  = [System.IO.Path]::GetFullPath($Path)
    $isWindows = Test-ADAutoXIsWindowsOS

    if ($isWindows) {
        # Create with narrow ACL using FileStream + FileSystemSecurity before any data lands
        $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($null -eq $currentIdentity -or $null -eq $currentIdentity.User) {
            Write-Warning "[ADAutoX] New-ADAutoXProtectedFile: could not retrieve Windows identity. Creating unprotected file."
            $null = New-Item -ItemType File -Path $fullPath -Force
            return $false
        }

        $security = [System.Security.AccessControl.FileSecurity]::new()
        $security.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $currentIdentity.User,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)

        try {
            $fs = [System.IO.FileStream]::new(
                $fullPath,
                [System.IO.FileMode]::Create,
                [System.Security.AccessControl.FileSystemRights]::WriteData,
                [System.IO.FileShare]::None,
                4096,
                [System.IO.FileOptions]::None,
                $security)
            $fs.Dispose()
            return $true
        }
        catch {
            Write-Warning "[ADAutoX] Could not create pre-protected file at '${fullPath}': $($_.Exception.Message). Falling back to post-creation ACL."
            $null = New-Item -ItemType File -Path $fullPath -Force
            return (Protect-ADAutoXFileAcl -Path $fullPath)
        }
    }
    else {
        # On non-Windows, create as empty then chmod 600 immediately
        $null = New-Item -ItemType File -Path $fullPath -Force
        return (Protect-ADAutoXFileAcl -Path $fullPath)
    }
}

function Export-ADAutoXCredentials {
    <#
    .SYNOPSIS
        Exports generated account credentials to a CLIXML file protected by DPAPI (Windows)
        or with chmod 600 (Linux/macOS).

    .NOTES
        BUG-09: On non-Windows, DPAPI/Export-Clixml does NOT encrypt SecureString values.
                We warn loudly and apply chmod 600 as the minimum protection measure.
        BUG-08: The file is created with restricted permissions BEFORE any secret is written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CredentialMap,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [switch]$Overwrite
    )

    $fullPath  = [System.IO.Path]::GetFullPath($OutputPath)
    $isWindows = Test-ADAutoXIsWindowsOS

    if ((Test-Path -LiteralPath $fullPath) -and -not $Overwrite) {
        throw "Credential export file '$fullPath' already exists. Use -Overwrite to replace."
    }

    # BUG-09: Warn loudly on non-Windows where DPAPI encryption is not available
    if (-not $isWindows) {
        Write-Warning @"
[ADAutoX] SECURITY WARNING: You are running on a non-Windows OS.
Export-Clixml does NOT encrypt SecureString values on Linux/macOS — the credential
file will contain passwords in a format that can be read without the Windows DPAPI key.
File permissions will be restricted to chmod 600 as a minimum safeguard.
For team use, consider encrypting with a certificate (Protect-CmsMessage) or using a
secrets vault (e.g., HashiCorp Vault, Azure Key Vault).
"@
    }

    # BUG-08: Create the file with restricted permissions BEFORE writing any secrets
    $protected = New-ADAutoXProtectedFile -Path $fullPath
    if (-not $protected) {
        Write-Warning "[ADAutoX] Could not pre-protect credential file '${fullPath}'. Aborting credential export to avoid writing unprotected secrets."
        throw "Credential export aborted: file could not be created with restricted permissions at '$fullPath'."
    }

    # Convert hashtable to PSCredential collection for Clixml export
    $psCredList = [System.Collections.Generic.List[PSCredential]]::new()
    foreach ($username in $CredentialMap.Keys) {
        $plainPassword = $CredentialMap[$username]
        $secPassword   = ConvertTo-SecureString $plainPassword -AsPlainText -Force
        $psCredList.Add((New-Object System.Management.Automation.PSCredential($username, $secPassword)))
    }

    # Write secrets to the already-protected file
    $psCredList | Export-Clixml -Path $fullPath -Force

    # Verify protection is still in place after write (Export-Clixml uses -Force which recreates the file)
    $stillProtected = Protect-ADAutoXFileAcl -Path $fullPath
    if (-not $stillProtected) {
        Write-Warning "[ADAutoX] Post-write ACL enforcement failed on '${fullPath}'. The credential file MAY have insecure permissions."
    }
}

Export-ModuleMember -Function New-ADAutoXRandomPassword, `
                              Test-ADAutoXPasswordComplexity, `
                              Protect-ADAutoXFileAcl, `
                              New-ADAutoXProtectedFile, `
                              Export-ADAutoXCredentials, `
                              Test-ADAutoXIsWindowsOS
