$content = Get-Content 'Modules\ADAutoX.Provisioner.psm1' -Raw
$openBraces = ([regex]::Matches($content, '\{')).Count
$closeBraces = ([regex]::Matches($content, '\}')).Count
Write-Host "Open: $openBraces, Close: $closeBraces"
