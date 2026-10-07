$content = Get-Content 'Modules\ADAutoX.Provisioner.psm1' -Raw
$singleQuotes = ([regex]::Matches($content, "'")).Count
$doubleQuotes = ([regex]::Matches($content, '"')).Count
Write-Host "Single: $singleQuotes, Double: $doubleQuotes"
