@{
    # PSScriptAnalyzer settings for ADAutoX project
    # Docs: https://github.com/PowerShell/PSScriptAnalyzer/blob/master/docs/markdown/Invoke-ScriptAnalyzer.md

    Rules = @{
        # ControlConsole.ps1 is a deliberate interactive terminal dashboard.
        # Write-Host is the correct and only appropriate cmdlet for colorized operator UIs.
        PSAvoidUsingWriteHost = @{
            Enable = $true
            # The Write-ADAutoXConsole wrapper in ADAutoX.Logging.psm1 already carries
            # [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
            # ControlConsole.ps1 is excluded at project level here.
        }
    }

    ExcludeRules = @()

    # Per-file exclusions — exclude PSAvoidUsingWriteHost for ControlConsole.ps1 only
    IncludeDefaultRules = $true
}
