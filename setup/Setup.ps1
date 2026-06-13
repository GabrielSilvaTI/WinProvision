# WinProvision Orquestrador Master - Modo Robusto
$BaseUrl = "https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/setup"

$Scripts = @(
    "theme.ps1",
    "Bootstrap.ps1",
    "Office.ps1",
    "MAS.ps1"
)

foreach ($ScriptName in $Scripts) {
    $Url = "$BaseUrl/$ScriptName"
    Write-Host "--- Baixando e executando: $ScriptName ---" -ForegroundColor Cyan
    
    try {
        # 1. Baixa o conteúdo do script
        $code = Invoke-RestMethod -Uri $Url
        
        # 2. Executa o código baixado no escopo atual, mas garantindo término
        # O '&' (call operator) é mais seguro para rodar scripts baixados
        Invoke-Expression $code
        
        Write-Host "--- $ScriptName finalizado. ---" -ForegroundColor Green
    } catch {
        Write-Host "Falha crítica em $ScriptName : $_" -ForegroundColor Red
    }
}

Write-Host "--- Todos os processos finalizados. ---" -ForegroundColor Green
