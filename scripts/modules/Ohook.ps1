$m = irm https://get.activated.win; $m | Out-File -FilePath "$env:TEMP\MAS.ps1" -Encoding UTF8 -Force; & "$env:TEMP\MAS.ps1" /Ohook
