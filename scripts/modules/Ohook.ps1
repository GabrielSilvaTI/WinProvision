#Requires -Version 5.1
<#
.SYNOPSIS
    WinProvision - Ativação do Microsoft Office via MAS (Ohook).
.DESCRIPTION
    Módulo autônomo e integrado ao WinProvision Orchestrator. Baixa e executa
    o Microsoft Activation Scripts em modo não-interativo (/Ohook).
.NOTES
    Versão : 1.9.0 (Invoke-WebRequest, TLS Strict, Progress Tracking & Clean Error Logging)
#>
[CmdletBinding()]
param(
    [string]$LogPath = "C:\ProgramData\WinProvision\Logs\WinProvision_Orchestrator.log",
    [string]$Mode    = "Ohook"
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

if ($PSVersionTable.PSVersion.Major -lt 5) { exit 2 }

# Restringe comunicação estritamente para TLS 1.2 e TLS 1.3
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

# ==============================================================================
# CONFIGURAÇÃO DE CAMINHOS E URLs
# ==============================================================================
$PrimaryUrl  = "https://dev.azure.com/massgrave/Microsoft-Activation-Scripts/_apis/git/repositories/Microsoft-Activation-Scripts/items?path=/MAS/All-In-One-Version-KL/MAS_AIO.cmd&download=true"
$FallbackUrl = "https://raw.githubusercontent.com/massgravel/Microsoft-Activation-Scripts/master/MAS/All-In-One-Version-KL/MAS_AIO.cmd"

$WorkingDir  = Join-Path -Path $env:SystemRoot -ChildPath "Temp\WinProvision_MAS"
$CmdFile     = Join-Path -Path $WorkingDir -ChildPath "MAS_AIO.cmd"

# ==============================================================================
# LOGGING UNIFICADO
# ==============================================================================
$logDir = Split-Path $LogPath -Parent
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null }

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] [MAS/$Mode] $Msg"
    try {
        Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
    Write-Host $line
}

function Manage-DefenderExclusion {
    param([bool]$Add)
    try {
        if ($Add) {
            Write-Log "Aplicando exclusão temporária no Windows Defender..." "INFO"
            Add-MpPreference -ExclusionPath $WorkingDir -ErrorAction Stop
        } else {
            Write-Log "Removendo exclusão do Windows Defender..." "INFO"
            Remove-MpPreference -ExclusionPath $WorkingDir -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log "Aviso ao manipular exclusão do Defender: $($_.Exception.Message)" "WARN"
    }
}

# ==============================================================================
# EXECUÇÃO PRINCIPAL
# ==============================================================================
try {
    Write-Log "[PROGRESS] 10%" "INFO"
    Write-Log "Iniciando módulo de ativação via MAS ($Mode)..." "INFO"

    if (Test-Path -Path $WorkingDir) { Remove-Item -Path $WorkingDir -Recurse -Force -ErrorAction SilentlyContinue }
    $null = New-Item -Path $WorkingDir -ItemType Directory -Force

    Manage-DefenderExclusion -Add $true

    Write-Log "[PROGRESS] 30%" "INFO"
    
    $DownloadSuccess = $false
    $Headers = @{
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) WinProvision"
    }

    # Download via Invoke-WebRequest (Servidor Principal)
    try {
        Write-Log "Baixando script do MAS via Invoke-WebRequest do servidor principal..." "INFO"
        Invoke-WebRequest -Uri $PrimaryUrl -OutFile $CmdFile -Headers $Headers -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        $DownloadSuccess = $true
    } catch {
        Write-Log "Falha ao baixar do servidor principal ($($_.Exception.Message)). Tentando fallback..." "WARN"
    }

    # Download via Invoke-WebRequest (Fallback)
    if (-not $DownloadSuccess) {
        try {
            Write-Log "Baixando script do MAS via Invoke-WebRequest do repositório secundário (GitHub)..." "INFO"
            Invoke-WebRequest -Uri $FallbackUrl -OutFile $CmdFile -Headers $Headers -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            $DownloadSuccess = $true
        } catch {
            Write-Log "Falha crítica no download do MAS em ambas as fontes: $($_.Exception.Message)" "ERROR"
            exit 1
        }
    }

    if (-not (Test-Path -Path $CmdFile)) {
        Write-Log "Arquivo do script 'MAS_AIO.cmd' não foi localizado após o download." "ERROR"
        exit 1
    }

    Write-Log "[PROGRESS] 60%" "INFO"
    Write-Log "Script MAS obtido com sucesso. Preparando execução em modo /$Mode..." "INFO"

    $StdOutLog = Join-Path -Path $WorkingDir -ChildPath "mas_stdout.log"
    $StdErrLog = Join-Path -Path $WorkingDir -ChildPath "mas_stderr.log"

    Write-Log "[PROGRESS] 80%" "INFO"
    $CmdArgs = "/c `"$CmdFile`" /$Mode"
    $Process = Start-Process -FilePath "cmd.exe" -ArgumentList $CmdArgs -PassThru -NoNewWindow -RedirectStandardOutput $StdOutLog -RedirectStandardError $StdErrLog

    # Loop de monitoramento do processo
    $ElapsedSeconds = 0
    while (-not $Process.HasExited) {
        Start-Sleep -Seconds 5
        $ElapsedSeconds += 5
        if ($ElapsedSeconds % 15 -eq 0) {
            Write-Log "Aguardando conclusão da ativação ($ElapsedSeconds s decorridos)..." "INFO"
        }
    }

    if ($Process.ExitCode -eq 0) {
        Write-Log "[PROGRESS] 100%" "INFO"
        Write-Log "Ativação via MAS ($Mode) concluída com sucesso." "INFO"
        exit 0
    } else {
        $ErrContent = ""
        if (Test-Path $StdErrLog) { $ErrContent = Get-Content $StdErrLog -Raw -ErrorAction SilentlyContinue }
        Write-Log "O script do MAS encerrou com ExitCode $($Process.ExitCode). Detalhes: $ErrContent" "ERROR"
        exit 1
    }

} catch {
    Write-Log "Exceção não tratada durante a ativação: $($_.Exception.Message)" "ERROR"
    exit 1
} finally {
    # Garante a limpeza do ambiente e exclusões do Defender independentemente de exceções
    Manage-DefenderExclusion -Add $false
    if (Test-Path -Path $WorkingDir) {
        Remove-Item -Path $WorkingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
