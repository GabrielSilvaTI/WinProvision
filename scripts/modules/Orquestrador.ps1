# Configurações
$LogFile = "C:\Windows\Temp\WinProvision_Log.txt"
$MaxRetries = 3

# Função para registrar logs
function Write-Log {
    param([string]$Message)
    $Timestamp = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
    "[$Timestamp] $Message" | Out-File -FilePath $LogFile -Append
}

# Função de verificação de rede
function Test-InternetConnection {
    return (Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet)
}

# Início do processo
Write-Host "Iniciando WinProvision Orchestrator..." -ForegroundColor Cyan
Write-Log "Iniciando orquestrador. Ordem: Bootstrap, Office, MAS."

# Lista de tarefas
$Tasks = @(
    @{ Name = "Bootstrap"; URL = "https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/Bootstrap.ps1" },
    @{ Name = "Office";    URL = "https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/office.ps1" },
    @{ Name = "MAS";       URL = "https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/Ohook.ps1" }
)

# Configura segurança global para TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Execução com Retry
foreach ($Task in $Tasks) {
    $attempt = 0
    $success = $false

    while ($attempt -lt $MaxRetries -and -not $success) {
        $attempt++
        Write-Log "Executando $($Task.Name) (Tentativa $attempt)..."
        
        if (Test-InternetConnection) {
            try {
                $scriptContent = Invoke-RestMethod -Uri $Task.URL
                Invoke-Expression $scriptContent
                $success = $true
                Write-Log "$($Task.Name) concluído com sucesso."
                Write-Host "$($Task.Name) concluído com sucesso." -ForegroundColor Green
            }
            catch {
                $errMsg = $($_.Exception.Message)
                Write-Log "ERRO no $($Task.Name) (Tentativa $attempt): $errMsg"
                Write-Host "Erro ao executar $($Task.Name). Tentando novamente..." -ForegroundColor Yellow
                Start-Sleep -Seconds 5
            }
        } else {
            Write-Log "Sem conexão para $($Task.Name). Aguardando..."
            Start-Sleep -Seconds 10
        }
    }
    
    if (-not $success) {
        Write-Log "Falha crítica ao executar $($Task.Name) após $MaxRetries tentativas."
    }
}

Write-Log "Orquestrador finalizado."
Write-Host "Processo concluído. Confira o log em $LogFile" -ForegroundColor Green

# Finaliza o processo do PowerShell
exit
