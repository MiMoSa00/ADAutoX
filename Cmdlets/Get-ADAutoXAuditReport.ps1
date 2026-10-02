<#
.SYNOPSIS
    Parses and filters ADAutoX JSONL audit logs.

.EXAMPLE
    .\Get-ADAutoXAuditReport.ps1 -Status Failed

.EXAMPLE
    .\Get-ADAutoXAuditReport.ps1 -Action CreateUser -OutputPath '.\Filtered-User-Audit.csv'

.EXAMPLE
    .\Get-ADAutoXAuditReport.ps1 -Full
#>
[CmdletBinding()]
param(
    [string]$AuditLogPath = '',

    [string]$Identity = '',

    [string]$Action = '',

    [string]$Status = '',

    [string]$Actor = '',

    [string]$OutputPath = '',

    # Bug #26: show all fields including Message/Details
    [switch]$Full
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$rootDir   = Split-Path -Parent $scriptDir

# Load Module
Import-Module (Join-Path -Path $rootDir -ChildPath 'ADAutoX.psd1') -Force

if ([string]::IsNullOrWhiteSpace($AuditLogPath)) {
    $AuditLogPath = Join-Path -Path $rootDir -ChildPath 'ADAutoX-Audit.jsonl'
}

$results = @(Get-ADAutoXAuditReport -LogPath $AuditLogPath `
                                    -Identity $Identity `
                                    -Action $Action `
                                    -Status $Status `
                                    -Actor $Actor `
                                    -OutputPath $OutputPath)

if ($results.Count -gt 0) {
    Write-ADAutoXConsole -Message "Displaying $($results.Count) matching audit entries:" -Level Phase
    if ($Full) {
        # Bug #26: show all fields including Message and Details
        $results | Format-List *
    }
    else {
        $results | Format-Table -Property Timestamp, Action, Target, Status, Actor, Message, CorrelationId -AutoSize
    }
}
else {
    Write-ADAutoXConsole -Message "No matching audit log entries found." -Level Warning
}
