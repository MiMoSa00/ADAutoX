Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SavedDefaultParams = $null
$script:CreatedPSDrive     = $false

# BUG-26: expose a module-level hashtable for AD parameter splatting so callers
# can splat it into every AD call rather than relying on global PSDefaultParameterValues.
# This is narrower and safer than the wildcard '*-AD*' approach.
$script:ADSplatParams = @{}

function Get-ADAutoXSplatParams {
    <#
    .SYNOPSIS
        Returns the hashtable that should be splatted into every AD cmdlet call.
        Contains Server (always) and Credential (if supplied), matching exactly what
        Initialize-ADAutoXContext was given.
    #>
    [CmdletBinding()]
    param()
    return $script:ADSplatParams.Clone()
}

function Test-ADAutoXDomainReachability {
    [CmdletBinding()]
    param(
        [string]$Server,
        [PSCredential]$Credential
    )

    $params = @{}
    if ($Server)     { $params.Server     = $Server }
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

        # BUG-26: Save existing parameter defaults so we can restore them on cleanup
        $script:SavedDefaultParams = @{
            Server     = if ($global:PSDefaultParameterValues.ContainsKey('*-AD*:Server'))     { $global:PSDefaultParameterValues['*-AD*:Server'] }     else { $null }
            Credential = if ($global:PSDefaultParameterValues.ContainsKey('*-AD*:Credential')) { $global:PSDefaultParameterValues['*-AD*:Credential'] } else { $null }
        }

        # BUG-26: Clear global defaults before we set our own
        [void]$global:PSDefaultParameterValues.Remove('*-AD*:Server')
        [void]$global:PSDefaultParameterValues.Remove('*-AD*:Credential')

        $credentialContext = @{}
        if ($Credential) {
            $credentialContext.Credential = $Credential
        }

        $resolvedServer = $Server
        if ([string]::IsNullOrWhiteSpace($resolvedServer)) {
            $dc = Get-ADDomainController @credentialContext -Discover -Writable -ErrorAction Stop
            $resolvedServer = [string]$dc.HostName
        }

        # Set narrow global defaults (used only as a fallback; callers should splat $script:ADSplatParams)
        $global:PSDefaultParameterValues['*-AD*:Server'] = $resolvedServer
        if ($Credential) {
            $global:PSDefaultParameterValues['*-AD*:Credential'] = $Credential
        }

        # BUG-26: Build the explicit splat hashtable for callers to use
        $script:ADSplatParams = @{ Server = $resolvedServer }
        if ($Credential) { $script:ADSplatParams.Credential = $Credential }

        # Remove and recreate the AD: drive to avoid reusing a stale drive from a crashed run
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

        # BUG-41: Record the effective AD credential user in the logging module
        $adCredUserName = if ($Credential) { $Credential.UserName } else { '' }
        Set-ADAutoXEffectiveCredentialUser -UserName $adCredUserName

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
    $script:CreatedPSDrive     = $false
    $script:ADSplatParams      = @{}

    # Clear the stored credential user from the logging module
    try { Set-ADAutoXEffectiveCredentialUser -UserName '' } catch {}
}

Export-ModuleMember -Function Test-ADAutoXDomainReachability, `
                              Initialize-ADAutoXContext, `
                              Clear-ADAutoXContext, `
                              Get-ADAutoXSplatParams
