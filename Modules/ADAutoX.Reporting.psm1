Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ADAutoXAuditReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,

        [string]$Identity = '',
        [string]$Action = '',
        [string]$Status = '',
        [string]$Actor = '',
        [string]$OutputPath = ''
    )

    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        Write-ADAutoXConsole -Message "Log file '$LogPath' does not exist." -Level Warning
        return @()
    }

    $lines = Get-Content -LiteralPath $LogPath -Encoding UTF8
    $records = [System.Collections.Generic.List[psobject]]::new()

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json
            $records.Add($obj)
        }
        catch {
            # Ignore malformed JSON lines
        }
    }

    $filtered = @($records | Where-Object {
        ($null -eq $Identity -or [string]::IsNullOrWhiteSpace($Identity) -or $_.Target -like "*$Identity*" -or $_.Details -like "*$Identity*") -and
        ($null -eq $Action   -or [string]::IsNullOrWhiteSpace($Action)   -or $_.Action -ieq $Action) -and
        ($null -eq $Status   -or [string]::IsNullOrWhiteSpace($Status)   -or $_.Status -ieq $Status) -and
        ($null -eq $Actor    -or [string]::IsNullOrWhiteSpace($Actor)    -or $_.Actor  -like "*$Actor*")
    })

    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        # BUG-40: sanitize all string cell values to prevent CSV formula injection
        $sanitized = $filtered | ForEach-Object {
            $row = [ordered]@{}
            foreach ($prop in $_.PSObject.Properties) {
                $val = $prop.Value
                if ($val -is [string]) {
                    $val = Protect-ADAutoXCsvCell -Value $val
                }
                $row[$prop.Name] = $val
            }
            [pscustomobject]$row
        }
        $sanitized | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 -Force
        Write-ADAutoXConsole -Message "Audit report exported to '$OutputPath' ($($filtered.Count) entries)." -Level Success
    }

    return $filtered
}

function Get-ADAutoXSecurityScan {
    [CmdletBinding()]
    param(
        [string]$SearchBase = '',
        [int]$InactiveDays = 90
    )

    $params = @{}
    if ($SearchBase) { $params.SearchBase = $SearchBase }

    Write-ADAutoXConsole -Message 'Executing AD Security & Posture Scan...' -Level Info

    # BUG-27: LockedOut is a computed attribute — 'LockedOut -eq $true' LDAP filter is unreliable.
    # Microsoft's correct approach is Search-ADAccount -LockedOut.
    $lockedUsers = @()
    if (Get-Command Search-ADAccount -ErrorAction SilentlyContinue) {
        try {
            $searchParams = @{}
            if ($SearchBase) { $searchParams.SearchBase = $SearchBase }
            $lockedUsers = @(Search-ADAccount -LockedOut @searchParams |
                             Get-ADUser -Properties LockedOut, AccountExpirationDate, LastLogonDate, Department -ErrorAction SilentlyContinue)
        }
        catch {
            Write-ADAutoXConsole -Message "Could not query locked accounts via Search-ADAccount: $($_.Exception.Message)" -Level Warning
        }
    }
    else {
        Write-ADAutoXConsole -Message "Search-ADAccount is not available; locked account count will not be reported." -Level Warning
    }

    # Password never expires
    $neverExpires = @()
    try {
        $neverExpires = @(Get-ADUser @params -Filter 'PasswordNeverExpires -eq $true' -Properties PasswordNeverExpires, Enabled, Department -ErrorAction Stop)
    }
    catch {
        Write-ADAutoXConsole -Message "Could not query password-never-expires accounts: $($_.Exception.Message)" -Level Warning
    }

    # Inactive users
    $inactiveUsers = @()
    try {
        $threshold = (Get-Date).AddDays(-$InactiveDays)
        $inactiveUsers = @(Get-ADUser @params -Filter 'Enabled -eq $true' -Properties LastLogonDate, Department -ErrorAction Stop | Where-Object {
            $null -ne $_.LastLogonDate -and $_.LastLogonDate -lt $threshold
        })
    }
    catch {
        Write-ADAutoXConsole -Message "Could not query inactive accounts: $($_.Exception.Message)" -Level Warning
    }

    $result = [pscustomobject]@{
        Timestamp                 = (Get-Date).ToUniversalTime().ToString('o')
        LockedOutAccountsCount    = $lockedUsers.Count
        PasswordNeverExpiresCount = $neverExpires.Count
        InactiveAccountsCount     = $inactiveUsers.Count
        LockedUsers               = $lockedUsers
        NeverExpiresUsers         = $neverExpires
        InactiveUsers             = $inactiveUsers
    }

    Write-ADAutoXConsole -Message "Security Scan Completed: $($lockedUsers.Count) locked accounts, $($neverExpires.Count) password-never-expires, $($inactiveUsers.Count) inactive accounts (> $InactiveDays days)." -Level Success
    return $result
}

Export-ModuleMember -Function Get-ADAutoXAuditReport, `
                              Get-ADAutoXSecurityScan
