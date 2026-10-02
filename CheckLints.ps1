Import-Module PSScriptAnalyzer
$r = Invoke-ScriptAnalyzer -Path 'Modules\ADAutoX.Provisioner.psm1' -Severity Error,Warning
if ($r) {
    $r | Select-Object RuleName,Severity,Line,Message | ConvertTo-Json
} else {
    Write-Host "CLEAN"
}
