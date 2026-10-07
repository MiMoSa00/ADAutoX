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

# ---------------------------------------------------------------------------
# BUG-47 — Transliteration map for characters that survive Unicode NFD
#           decomposition intact (they have no separate base + combining mark).
#           Without this table, ø→(nothing), ł→(nothing), ß→(nothing), etc.
# ---------------------------------------------------------------------------
$script:TransliterationMap = [ordered]@{
    # Latin Extended-A / B characters without decomposable accents
    [char]0x00DF = 'ss'  # ß → ss
    [char]0x00E6 = 'ae'  # æ → ae
    [char]0x00C6 = 'Ae'  # Æ → Ae
    [char]0x00F8 = 'o'   # ø → o
    [char]0x00D8 = 'O'   # Ø → O
    [char]0x0142 = 'l'   # ł → l
    [char]0x0141 = 'L'   # Ł → L
    [char]0x0111 = 'd'   # đ → d
    [char]0x0110 = 'D'   # Đ → D
    [char]0x00FE = 'th'  # þ → th
    [char]0x00DE = 'Th'  # Þ → Th
    [char]0x00F0 = 'd'   # ð → d
    [char]0x00D0 = 'D'   # Ð → D
    [char]0x0131 = 'i'   # ı → i  (dotless i)
    [char]0x0138 = 'k'   # ĸ → k  (kra)
    [char]0x014B = 'n'   # ŋ → n  (eng)
    [char]0x014A = 'N'   # Ŋ → N
    [char]0x0153 = 'oe'  # œ → oe
    [char]0x0152 = 'Oe'  # Œ → Oe
}

function Invoke-ADAutoXTransliterate {
    <#
    .SYNOPSIS
        Replaces characters that Unicode NFD normalization cannot decompose
        with their closest ASCII equivalents before diacritic stripping.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)

    $sb = [System.Text.StringBuilder]::new($Text.Length * 2)
    foreach ($char in $Text.ToCharArray()) {
        if ($script:TransliterationMap.Contains($char)) {
            [void]$sb.Append($script:TransliterationMap[$char])
        }
        else {
            [void]$sb.Append($char)
        }
    }
    return $sb.ToString()
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

    # BUG-47: Step 1 — transliterate characters that NFD cannot decompose
    $transliterated = Invoke-ADAutoXTransliterate -Text $BaseName

    # Step 2 — Normalize unicode to FormD and strip diacritics / non-spacing marks
    $decomposed = $transliterated.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($char in $decomposed.ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
        if ($category -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($char)
        }
    }
    $withoutDiacritics = $sb.ToString()

    # Step 3 — Keep alphanumeric and dot only
    $sanitized = ($withoutDiacritics -replace '[^a-zA-Z0-9.]', '').ToLowerInvariant().TrimEnd('.')

    if ([string]::IsNullOrWhiteSpace($sanitized) -or $sanitized -notmatch '[a-z]') {
        throw "Cannot derive a valid SAM account name from '$BaseName'. Must contain at least one ASCII letter after transliteration."
    }

    $candidate = $sanitized
    if ($candidate.Length -gt 20) {
        $candidate = $candidate.Substring(0, 20).TrimEnd('.')
    }

    $suffix     = 1
    $uniqueName = $candidate

    while ($true) {
        $alreadyUsed = $null -ne $UsedNames -and $UsedNames.Contains($uniqueName)
        if (-not $alreadyUsed) { break }

        $suffix++
        $suffixStr  = [string]$suffix
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

# BUG-40 — CSV formula injection protection
function Protect-ADAutoXCsvCell {
    <#
    .SYNOPSIS
        Prefixes a CSV cell value with a single quote if it begins with a formula-triggering
        character (=, +, -, @, tab, carriage return) to prevent Excel formula injection.
    #>
    [CmdletBinding()]
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    # Characters that Excel treats as formula starters
    if ($Value[0] -in '=', '+', '-', '@', "`t", "`r") {
        return "'" + $Value
    }
    return $Value
}

Export-ModuleMember -Function ConvertTo-ADLdapFilter, `
                              ConvertTo-ADDistinguishedNameValue, `
                              Get-ADSanitizedSamAccountName, `
                              Get-ADSanitizedUserPrincipalName, `
                              Protect-ADAutoXCsvCell, `
                              Invoke-ADAutoXTransliterate
