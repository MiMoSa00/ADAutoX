Import-Module PSScriptAnalyzer

Write-Host "`n=== Modules\ADAutoX.Provisioner.psm1 ===" -ForegroundColor Cyan
$r = Invoke-ScriptAnalyzer -Path 'Modules\ADAutoX.Provisioner.psm1' -Severity Error,Warning
if ($r) { $r | Select-Object RuleName,Severity,Line,Message | Format-Table -AutoSize -Wrap }
else { Write-Host "  No issues found." -ForegroundColor Green }

Write-Host "`n=== Modules\ADAutoX.Logging.psm1 ===" -ForegroundColor Cyan
$r = Invoke-ScriptAnalyzer -Path 'Modules\ADAutoX.Logging.psm1' -Severity Error,Warning
if ($r) { $r | Select-Object RuleName,Severity,Line,Message | Format-Table -AutoSize -Wrap }
else { Write-Host "  No issues found." -ForegroundColor Green }

Write-Host "`n=== ControlConsole.ps1 (excluding PSAvoidUsingWriteHost - intentional UI) ===" -ForegroundColor Cyan
$r = Invoke-ScriptAnalyzer -Path 'ControlConsole.ps1' -Severity Error,Warning -ExcludeRule PSAvoidUsingWriteHost
if ($r) { $r | Select-Object RuleName,Severity,Line,Message | Format-Table -AutoSize -Wrap }
else { Write-Host "  No issues found." -ForegroundColor Green }
