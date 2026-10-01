Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-ADLdapFilter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Value
    )
    process {
        if ([string]::IsNullOrEmpty($Value)) { return $Value }
        $builder = [System.Text.StringBuilder]::new()
        foreach ($char in $Value.ToCharArray()) {
            switch ([int][char]$char) {
                0  { [void]$builder.Append('\00') }
                40 { [void]$builder.Append('\28') } # (
                41 { [void]$builder.Append('\29') } # )
                42 { [void]$builder.Append('\2a') } # *
                92 { [void]$builder.Append('\5c') } # \
                default { [void]$builder.Append($char) }
            }
        }
        return $builder.ToString()
    }
}

function ConvertTo-ADDistinguishedNameValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Value
    )
    process {
        if ([string]::IsNullOrEmpty($Value)) { return $Value }
        $escaped = $Value -replace '\\', '\5c' `
                          -replace ([char]0), '\00' `
                          -replace ',', '\2c' `
                          -replace '\+', '\2b' `
                          -replace '"', '\22' `
                          -replace '<', '\3c' `
                          -replace '>', '\3e' `
                          -replace ';', '\3b' `
                          -replace '=', '\3d'

        if ($escaped.StartsWith(' ')) { $escaped = '\20' + $escaped.Substring(1) }
        elseif ($escaped.StartsWith('#')) { $escaped = '\23' + $escaped.Substring(1) }
        if ($escaped.EndsWith(' ')) { $escaped = $escaped.Substring(0, $escaped.Length - 1) + '\20' }
        
        return $escaped
    }
}

function Get-ADSanitizedSamAccountName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseName,

        [System.Collections.Generic.HashSet[string]]$UsedNames
    )

    if ([string]::IsNullOrWhiteSpace($BaseName)) {
        throw 'BaseName parameter cannot be null or whitespace.'
    }

    # Normalize unicode to FormD and strip diacritics / non-spacing marks
    $decomposed = $BaseName.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($char in $decomposed.ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
        if ($category -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($char)
        }
    }
    $withoutDiacritics = $sb.ToString()

    # Sanitize: allow alphanumeric and dot only
    $sanitized = ($withoutDiacritics -replace '[^a-zA-Z0-9.]', '').ToLowerInvariant().TrimEnd('.')

    if ([string]::IsNullOrWhiteSpace($sanitized) -or $sanitized -notmatch '[a-z]') {
        throw "Cannot derive a valid SAM account name from '$BaseName'. Must contain at least one ASCII letter."
    }

    $candidate = $sanitized
    if ($candidate.Length -gt 20) {
        $candidate = $candidate.Substring(0, 20).TrimEnd('.')
    }

    $suffix = 1
    $uniqueName = $candidate

    while ($true) {
        $alreadyUsed = $null -ne $UsedNames -and $UsedNames.Contains($uniqueName)
        if (-not $alreadyUsed) { break }

        $suffix++
        $suffixStr = [string]$suffix
        $maxBaseLen = [Math]::Max(1, 20 - $suffixStr.Length)
        $uniqueName = "$($candidate.Substring(0, [Math]::Min($candidate.Length, $maxBaseLen)))$suffixStr".TrimEnd('.')
    }

    if ($null -ne $UsedNames) {
        [void]$UsedNames.Add($uniqueName)
    }

    return $uniqueName
}

function Get-ADSanitizedUserPrincipalName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SamAccountName,

        [Parameter(Mandatory = $true)]
        [string]$UPNSuffix
    )

    $cleanSuffix = $UPNSuffix.Trim().TrimStart('@')
    return "$SamAccountName@$cleanSuffix"
}

Export-ModuleMember -Function ConvertTo-ADLdapFilter, `
                              ConvertTo-ADDistinguishedNameValue, `
                              Get-ADSanitizedSamAccountName, `
                              Get-ADSanitizedUserPrincipalName
