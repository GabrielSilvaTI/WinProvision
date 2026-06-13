# WinProvision Orquestrador Master
# Ordem: Tema > Bootstrap > Office > MAS

$BaseUrl = "https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/setup"

$Scripts = @(
    "$BaseUrl/theme.ps1",
    "$BaseUrl/Bootstrap.ps1",
    "$BaseUrl/Office.ps1",
    "$BaseUrl/MAS.ps1"
)

foreach ($Script in $Scripts) {
    Write-Host "Iniciando processo: $Script" -ForegroundColor Cyan
    try {
        Invoke-RestMethod -Uri $Script | Invoke-Expression
    } catch {
        Write-Host "Falha ao executar $Script : $_" -ForegroundColor Red
    }
}
