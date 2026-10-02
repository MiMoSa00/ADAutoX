$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile('Modules\ADAutoX.Provisioner.psm1', [ref]$tokens, [ref]$errors)
if ($errors) {
    foreach ($err in $errors) {
        Write-Host "Error at line $($err.Extent.StartLineNumber): $($err.Message)"
    }
} else {
    Write-Host "No syntax errors."
}
