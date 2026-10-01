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

function Protect-ADAutoXFileAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    # Cross-platform check: Windows ACL enforcement requires Windows OS
    $isWindowsOS = $false
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $isWindowsOS = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
    } else {
        $isWindowsOS = $env:OS -like '*Windows*'
    }

    if (-not $isWindowsOS) {
        Write-Verbose "Protect-ADAutoXFileAcl: ACL enforcement is skipped on non-Windows OS."
        return
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $currentIdentity -or $null -eq $currentIdentity.User) {
        return
    }

    try {
        $acl = Get-Acl -LiteralPath $fullPath
        $currentUser = $currentIdentity.User

        # Protect ACL (disable inheritance and purge existing rules)
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
            $null = $acl.RemoveAccessRule($rule)
        }

        # Grant Full Control only to the executing Windows identity
        $fullControlRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $currentUser,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        )

        $acl.AddAccessRule($fullControlRule)
        Set-Acl -LiteralPath $fullPath -AclObject $acl -ErrorAction Stop
    }
    catch {
        # Mapped VirtualBox VBOXSF / Network shares do not support Windows NTFS ACL operations
        Write-Verbose "ACL enforcement skipped on '${fullPath}': $($_.Exception.Message)"
    }
}

function Export-ADAutoXCredentials {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CredentialMap,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [switch]$Overwrite
    )

    $fullPath = [System.IO.Path]::GetFullPath($OutputPath)
    if ((Test-Path -LiteralPath $fullPath) -and -not $Overwrite) {
        throw "Credential export file '$fullPath' already exists. Use -Overwrite to replace."
    }

    # Convert hashtable to PSCredential collection for Clixml export
    $psCredList = [System.Collections.Generic.List[PSCredential]]::new()
    foreach ($username in $CredentialMap.Keys) {
        $plainPassword = $CredentialMap[$username]
        $secPassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
        $psCredList.Add((New-Object System.Management.Automation.PSCredential($username, $secPassword)))
    }

    $psCredList | Export-Clixml -Path $fullPath -Force
    Protect-ADAutoXFileAcl -Path $fullPath
}

Export-ModuleMember -Function New-ADAutoXRandomPassword, `
                              Test-ADAutoXPasswordComplexity, `
                              Protect-ADAutoXFileAcl, `
                              Export-ADAutoXCredentials
