Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CurrentCorrelationId = [System.Guid]::NewGuid().ToString()

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

    # Cross-platform identity resolution (Bug #25 / Claude finding):
    # [WindowsIdentity]::GetCurrent() throws on Linux/macOS. Fall back to env variables.
    $computerName = [Environment]::MachineName
    $userName     = [Environment]::UserName
    $actorName    = "$computerName\$userName"

    # PSAvoidAssignmentToAutomaticVariable: use $onWindows (not $isWindows which is a PS6+ readonly automatic variable)
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

    $record = [ordered]@{
        Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
        Actor         = $actorName
        Operator      = $actorName
        Computer      = $computerName
        Action        = $Action
        Target        = $Target
        TargetType    = $TargetType
        Status        = $Status
        Message       = $Message
        Details       = if ([string]::IsNullOrWhiteSpace($Details)) { $Message } else { $Details }
        Source        = $Source
        CorrelationId = $effectiveCorrelationId
    }

    $jsonLine = $record | ConvertTo-Json -Compress

    # Bug #25: A logging failure must NOT abort an operation that already succeeded.
    # Wrap Add-Content and downgrade failures to warnings.
    try {
        $jsonLine | Add-Content -LiteralPath $LogPath -Encoding UTF8
    }
    catch {
        Write-ADAutoXConsole -Message "WARNING: Failed to write audit log entry to '$LogPath': $($_.Exception.Message)" -Level Warning
    }
}

Export-ModuleMember -Function New-ADAutoXCorrelationId, `
                              Get-ADAutoXCorrelationId, `
                              Write-ADAutoXConsole, `
                              Write-ADAutoXLogRecord
