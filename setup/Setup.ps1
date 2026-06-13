# URL base do seu repositório
$BaseUrl = "https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/setup"

$Scripts = @(
    "$BaseUrl/theme.ps1",
    "$BaseUrl/Bootstrap.ps1",
    "$BaseUrl/Office.ps1",
    "$BaseUrl/MAS.ps1"
)

foreach ($Script in $Scripts) {
    Write-Host "Executando: $Script" -ForegroundColor Cyan
    irm $Script | iex
}
