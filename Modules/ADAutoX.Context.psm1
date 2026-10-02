Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SavedDefaultParams = $null
$script:CreatedPSDrive = $false

function Test-ADAutoXDomainReachability {
    [CmdletBinding()]
    param(
        [string]$Server,
        [PSCredential]$Credential
    )

    $params = @{}
    if ($Server) { $params.Server = $Server }
    if ($Credential) { $params.Credential = $Credential }

    try {
        $domain = Get-ADDomain @params -ErrorAction Stop
        return [pscustomobject]@{
            IsReachable = $true
            DomainName  = $domain.DNSRoot
            Forest      = $domain.Forest
            DomainDN    = $domain.DistinguishedName
            NetBIOSName = $domain.NetBIOSName
            Server      = $Server
        }
    }
    catch {
        return [pscustomobject]@{
            IsReachable = $false
            Error       = $_.Exception.Message
            Server      = $Server
        }
    }
}

function Initialize-ADAutoXContext {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
    param(
        [string]$Server,
        [PSCredential]$Credential
    )

    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        if (-not (Get-Command Get-ADDomain -ErrorAction SilentlyContinue)) {
            throw 'The Active Directory PowerShell module is not available on this machine.'
        }

        # Save existing parameter defaults
        $script:SavedDefaultParams = @{
            Server     = if ($global:PSDefaultParameterValues.ContainsKey('*-AD*:Server')) { $global:PSDefaultParameterValues['*-AD*:Server'] } else { $null }
            Credential = if ($global:PSDefaultParameterValues.ContainsKey('*-AD*:Credential')) { $global:PSDefaultParameterValues['*-AD*:Credential'] } else { $null }
        }

        [void]$global:PSDefaultParameterValues.Remove('*-AD*:Server')
        [void]$global:PSDefaultParameterValues.Remove('*-AD*:Credential')

        $credentialContext = @{}
        if ($Credential) {
            $global:PSDefaultParameterValues['*-AD*:Credential'] = $Credential
            $credentialContext.Credential = $Credential
        }

        $resolvedServer = $Server
        if ([string]::IsNullOrWhiteSpace($resolvedServer)) {
            $dc = Get-ADDomainController @credentialContext -Discover -Writable -ErrorAction Stop
            $resolvedServer = [string]$dc.HostName
        }

        $global:PSDefaultParameterValues['*-AD*:Server'] = $resolvedServer

        # Bug #23: always remove and recreate the AD: drive to avoid reusing a stale drive
        # from a crashed previous run that was pointed at a different server.
        if (Get-PSDrive -Name AD -ErrorAction SilentlyContinue) {
            Remove-PSDrive -Name AD -Force -ErrorAction SilentlyContinue
        }

        $driveParams = @{
            Name       = 'AD'
            PSProvider = 'ActiveDirectory'
            Root       = '//RootDSE/'
            Server     = $resolvedServer
        }
        if ($Credential) { $driveParams.Credential = $Credential }
        $null = New-PSDrive @driveParams -ErrorAction Stop
        $script:CreatedPSDrive = $true

        $domainInfo = Get-ADDomain -Server $resolvedServer -ErrorAction Stop
        return [pscustomobject]@{
            Server      = $resolvedServer
            DomainName  = $domainInfo.DNSRoot
            Forest      = $domainInfo.Forest
            DomainDN    = $domainInfo.DistinguishedName
            NetBIOSName = $domainInfo.NetBIOSName
            UPNSuffixes = $domainInfo.UPNSuffixes
        }
    }
    catch {
        Clear-ADAutoXContext
        throw
    }
}

function Clear-ADAutoXContext {
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
    param()

    if ($script:CreatedPSDrive -and (Get-PSDrive -Name AD -ErrorAction SilentlyContinue)) {
        Remove-PSDrive -Name AD -Force -ErrorAction SilentlyContinue
    }

    [void]$global:PSDefaultParameterValues.Remove('*-AD*:Server')
    [void]$global:PSDefaultParameterValues.Remove('*-AD*:Credential')

    if ($script:SavedDefaultParams) {
        if ($null -ne $script:SavedDefaultParams.Server) {
            $global:PSDefaultParameterValues['*-AD*:Server'] = $script:SavedDefaultParams.Server
        }
        if ($null -ne $script:SavedDefaultParams.Credential) {
            $global:PSDefaultParameterValues['*-AD*:Credential'] = $script:SavedDefaultParams.Credential
        }
    }

    $script:SavedDefaultParams = $null
    $script:CreatedPSDrive = $false
}

Export-ModuleMember -Function Test-ADAutoXDomainReachability, `
                              Initialize-ADAutoXContext, `
                              Clear-ADAutoXContext
