$bytes = [System.IO.File]::ReadAllBytes('Modules\ADAutoX.Provisioner.psm1')
$nonAscii = @()
for ($i=0; $i -lt $bytes.Length; $i++) {
    if ($bytes[$i] -gt 127) {
        $nonAscii += "Byte ${i}: $($bytes[$i])"
    }
}
if ($nonAscii.Count -gt 0) {
    $nonAscii | Select-Object -First 10 | Write-Host
} else {
    Write-Host "All ASCII"
}
