<#
.SYNOPSIS
    Parses and filters ADAutoX JSONL audit logs.

.EXAMPLE
    .\Get-ADAutoXAuditReport.ps1 -Status Failed

.EXAMPLE
    .\Get-ADAutoXAuditReport.ps1 -Action CreateUser -OutputPath '.\Filtered-User-Audit.csv'
#>
[CmdletBinding()]
param(
    [string]$AuditLogPath = '',

    [string]$Identity = '',

    [string]$Action = '',

    [string]$Status = '',

    [string]$Actor = '',

    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$rootDir   = Split-Path -Parent $scriptDir

# Load Module
Import-Module (Join-Path $rootDir 'ADAutoX.psd1') -Force

if ([string]::IsNullOrWhiteSpace($AuditLogPath)) {
    $AuditLogPath = Join-Path $rootDir 'ADAutoX-Audit.jsonl'
}

$results = @(Get-ADAutoXAuditReport -LogPath $AuditLogPath `
                                    -Identity $Identity `
                                    -Action $Action `
                                    -Status $Status `
                                    -Actor $Actor `
                                    -OutputPath $OutputPath)

if ($results.Count -gt 0) {
    Write-ADAutoXConsole -Message "Displaying $($results.Count) matching audit entries:" -Level Phase
    $results | Format-Table -Property Timestamp, Action, Target, Status, Actor, CorrelationId -AutoSize
}
else {
    Write-ADAutoXConsole -Message "No matching audit log entries found." -Level Warning
}
