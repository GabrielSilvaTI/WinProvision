#Requires -Version 5.1
<#
.SYNOPSIS
    WinProvision Orchestrator - Execucao robusta de modulos externos.
#>

[CmdletBinding()]
param()

# Configuracoes
$script:LogFile         = Join-Path -Path $env:SystemRoot -ChildPath 'Temp\WinProvision_Log.txt'
$script:MaxRetries      = 3
$script:RetryDelaySec   = 5
$script:NetworkDelaySec = 10

# Funcao de Log
function Write-Log {
    param([Parameter(Mandatory=$true)][string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $entry = "[$(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')][$Level] $Message"
    try { $entry | Out-File -FilePath $script:LogFile -Append -Encoding UTF8 } catch { }
    Write-Host $entry -ForegroundColor $(switch($Level){'INFO'{'Cyan'};'WARN'{'Yellow'};'ERROR'{'Red'}})
}

# Funcao de Execucao Isolada
function Invoke-Module {
    param([string]$Name, [string]$Url)

    $attempt = 0
    while ($attempt -lt $script:MaxRetries) {
        $attempt++
        Write-Log -Message "Iniciando modulo '$Name' (Tentativa $attempt)..."

        try {
            # Baixa o script temporariamente
            $tempScript = [System.IO.Path]::GetTempFileName() + ".ps1"
            $content = Invoke-RestMethod -Uri $Url -UseBasicParsing -ErrorAction Stop
            $content | Out-File -FilePath $tempScript -Encoding UTF8

            # EXECUTA EM PROCESSO FILHO (Isolado)
            # O exit do script filho nao afetara o Orquestrador
            $proc = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`"" -Wait -PassThru
            
            Remove-Item $tempScript -Force -ErrorAction SilentlyContinue

            if ($proc.ExitCode -eq 0) {
                Write-Log -Message "Modulo '$Name' concluido com sucesso."
                return $true
            } else {
                Write-Log -Level "ERROR" -Message "Modulo '$Name' falhou com ExitCode: $($proc.ExitCode)"
            }
        } catch {
            Write-Log -Level "ERROR" -Message "Erro ao processar '$Name': $($_.Exception.Message)"
        }

        if ($attempt -lt $script:MaxRetries) { Start-Sleep -Seconds $script:RetryDelaySec }
    }
    return $false
}

# Inicializacao
$logDir = Split-Path $script:LogFile -Parent
if (-not (Test-Path $logDir)) { New-Item $logDir -ItemType Directory -Force | Out-Null }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Lista de Tarefas (Ordem sequencial garantida)
$tasks = @(
    @{Name='Wallpaper'; Url='https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/Wallpaper.ps1'},
    @{Name='Bootstrap'; Url='https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/Bootstrap.ps1'},
    @{Name='Office';    Url='https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/office.ps1'},
    @{Name='MAS';       Url='https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/Ohook.ps1'}
)

# Execucao
$results = @()
foreach ($task in $tasks) {
    $status = Invoke-Module -Name $task.Name -Url $task.Url
    $results += [PSCustomObject]@{ Task = $task.Name; Success = $status }
}

# Resumo
Write-Host "`n=== Resumo do Provisionamento ===" -ForegroundColor Cyan
$results | ForEach-Object { Write-Host "$($_.Task): $(if($_.Success){'OK'}else{'FALHA'})" -ForegroundColor $(if($_.Success){'Green'}else{'Red'}) }
exit 0
