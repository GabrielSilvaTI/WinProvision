# WinProvision Orquestrador Master (Serializado)
$BaseUrl = "https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/setup"

$Scripts = @(
    "theme.ps1",
    "Bootstrap.ps1",
    "Office.ps1",
    "MAS.ps1"
)

foreach ($Script in $Scripts) {
    $FullUrl = "$BaseUrl/$Script"
    Write-Host "--- Executando: $Script ---" -ForegroundColor Cyan
    
    # Inicia um novo processo PowerShell para cada script e AGUARDA a conclusão
    $process = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm '$FullUrl' | iex`"" -Wait -NoNewWindow -PassThru
    
    # Verifica se houve erro no processo
    if ($process.ExitCode -ne 0) {
        Write-Host "Atenção: O script $Script terminou com erros (Código: $($process.ExitCode))." -ForegroundColor Yellow
    }
}

Write-Host "--- Provisionamento concluído com sucesso! ---" -ForegroundColor Green
