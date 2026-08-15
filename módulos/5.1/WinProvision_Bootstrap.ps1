# Roda no Windows PowerShell 5.1 (Administrador)
Set-Location -Path "C:\Users\Gabriel\Downloads\Testes"

# Importa e instala o PS7
Import-Module .\Install-PowerShell7.psd1 -Force
Install-PowerShell7

# Uma vez instalado, chama o PowerShell 7 para rodar o restante dos seus módulos!
pwsh.exe -NoProfile -Command "& { Set-Location 'C:\Users\Gabriel\Downloads\Testes'; Get-ChildItem -Filter *.psd1 | Import-Module -Force; Install-Winget; Install-Office; Invoke-WinProvision }"
