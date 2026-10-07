$content = Get-Content 'Modules\ADAutoX.Provisioner.psm1' -Raw
$openP = ([regex]::Matches($content, '\(')).Count
$closeP = ([regex]::Matches($content, '\)')).Count
Write-Host "Open: $openP, Close: $closeP"
