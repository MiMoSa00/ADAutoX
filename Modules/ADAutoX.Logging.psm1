Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CurrentCorrelationId = [System.Guid]::NewGuid().ToString()
# BUG-41: store the effective AD credential user so the audit log reflects who AD actually used
$script:EffectiveADCredentialUser = ''

function New-ADAutoXCorrelationId {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()
    $script:CurrentCorrelationId = [System.Guid]::NewGuid().ToString()
    return $script:CurrentCorrelationId
}

function Get-ADAutoXCorrelationId {
    [CmdletBinding()]
    param()
    return $script:CurrentCorrelationId
}

function Set-ADAutoXEffectiveCredentialUser {
    <#
    .SYNOPSIS
        Stores the AD credential user name that is actually used for AD operations,
        so audit log records can distinguish the local operator from the AD account.
    .NOTES
        BUG-41: Call this immediately after initializing the AD context when -Credential is supplied.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([string]$UserName)
    $script:EffectiveADCredentialUser = $UserName
}

function Get-ADAutoXEffectiveCredentialUser {
    [CmdletBinding()]
    param()
    return $script:EffectiveADCredentialUser
}

function Write-ADAutoXConsole {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Verbose', 'Phase')]
        [string]$Level = 'Info'
    )

    $time = (Get-Date).ToString('HH:mm:ss')
    switch ($Level) {
        'Success' { Write-Host "[$time] [+] $Message" -ForegroundColor Green }
        'Warning' { Write-Host "[$time] [!] $Message" -ForegroundColor Yellow }
        'Error'   { Write-Host "[$time] [-] $Message" -ForegroundColor Red }
        'Phase'   { Write-Host "`n[$time] === $Message ===" -ForegroundColor Cyan }
        'Verbose' { Write-Verbose "[$time] [*] $Message" }
        default   { Write-Host "[$time] [*] $Message" -ForegroundColor Gray }
    }
}

function Write-ADAutoXLogRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Target,

        [ValidateSet('Started', 'Succeeded', 'Failed', 'Skipped', 'Preview', 'CompletedWithErrors')]
        [string]$Status = 'Succeeded',

        [string]$Message = '',

        [string]$TargetType = 'User',

        [string]$Details = '',

        [string]$Source = 'ADAutoX',

        [string]$CorrelationId = ''
    )

    if ([string]::IsNullOrWhiteSpace($LogPath)) { return }

    $parentDir = Split-Path -Path ([System.IO.Path]::GetFullPath($LogPath)) -Parent
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    # Cross-platform identity resolution
    $computerName = [Environment]::MachineName
    $userName     = [Environment]::UserName
    $actorName    = "$computerName\$userName"

    try {
        $onWindows = $false
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $onWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
                [System.Runtime.InteropServices.OSPlatform]::Windows)
        } else {
            $onWindows = $env:OS -like '*Windows*'
        }

        if ($onWindows) {
            try {
                $winIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
                if (-not [string]::IsNullOrWhiteSpace($winIdentity)) {
                    $actorName = $winIdentity
                }
            } catch {
                Write-Verbose "[ADAutoX.Logging] WindowsIdentity unavailable; using Environment fallback for actor name."
            }
        }
    }
    catch {
        Write-Verbose "[ADAutoX.Logging] OS platform detection failed; using Environment fallback for actor name."
    }

    $effectiveCorrelationId = if (-not [string]::IsNullOrWhiteSpace($CorrelationId)) { $CorrelationId } else { $script:CurrentCorrelationId }

    # BUG-41: If an AD credential was supplied, record it alongside the local operator
    $adCredUser = $script:EffectiveADCredentialUser
    $effectiveActor = if (-not [string]::IsNullOrWhiteSpace($adCredUser)) { $adCredUser } else { $actorName }

    $record = [ordered]@{
        Timestamp       = (Get-Date).ToUniversalTime().ToString('o')
        LocalOperator   = $actorName    # who ran the script (local Windows identity)
        ADCredential    = $adCredUser   # AD account used for directory operations (may differ)
        Actor           = $effectiveActor  # primary actor for SIEM/correlation (AD cred if supplied)
        Computer        = $computerName
        Action          = $Action
        Target          = $Target
        TargetType      = $TargetType
        Status          = $Status
        Message         = $Message
        Details         = if ([string]::IsNullOrWhiteSpace($Details)) { $Message } else { $Details }
        Source          = $Source
        CorrelationId   = $effectiveCorrelationId
    }

    $jsonLine = $record | ConvertTo-Json -Compress

    # BUG-30: A logging failure must NOT abort an operation that already succeeded.
    # Retry once with a short sleep before degrading to a warning.
    $written = $false
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $jsonLine | Add-Content -LiteralPath $LogPath -Encoding UTF8
            $written = $true
            break
        }
        catch {
            if ($attempt -lt 2) {
                Start-Sleep -Milliseconds 150
            }
        }
    }
    if (-not $written) {
        Write-ADAutoXConsole -Message "WARNING: Failed to write audit log entry to '$LogPath' after retry. Action '$Action' on '$Target' was NOT recorded." -Level Warning
    }
}

Export-ModuleMember -Function New-ADAutoXCorrelationId, `
                              Get-ADAutoXCorrelationId, `
                              Set-ADAutoXEffectiveCredentialUser, `
                              Get-ADAutoXEffectiveCredentialUser, `
                              Write-ADAutoXConsole, `
                              Write-ADAutoXLogRecord
