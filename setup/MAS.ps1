<#
.SYNOPSIS
    Script autônomo para ativação do Office via MAS (Ohook).
    
.DESCRIPTION
    1. Cria diretório de trabalho seguro.
    2. Aplica exclusão no Windows Defender para evitar bloqueios.
    3. Baixa o MAS AIO via WebClient (resiliente).
    4. Executa ativação silenciosa via Ohook.
    5. Remove arquivos temporários ao finalizar.
#>

$Script:WorkDir = "C:\Temp\MAS_Provisioning"
$Script:LogFile = "$env:SystemRoot\Logs\CloudProvisioning\MAS_Activation.log"

function Write-Log {
    param([string]$Msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $Script:LogFile -Value "$ts - $Msg" -ErrorAction SilentlyContinue
    Write-Host "[MAS] $Msg"
}

# 1. Preparação de ambiente
Write-Log "Iniciando processo de ativação..."
try {
    if (-not (Test-Path $Script:WorkDir)) {
        New-Item -ItemType Directory -Path $Script:WorkDir -Force | Out-Null
    }
    
    # Adiciona exclusão ao Defender para a pasta (Requer Admin)
    Write-Log "Adicionando exclusão ao Windows Defender..."
    Add-MpPreference -ExclusionPath $Script:WorkDir -ErrorAction SilentlyContinue
} catch {
    Write-Log "Aviso: Não foi possível configurar exclusões do Defender (pode exigir permissões superiores)."
}

# 2. Download do MAS_AIO
$MAS_Url  = "https://dev.azure.com/massgrave/Microsoft-Activation-Scripts/_apis/git/repositories/Microsoft-Activation-Scripts/items?path=/MAS/All-In-One-Version-KL/MAS_AIO.cmd&download=true"
$MAS_Path = "$Script:WorkDir\MAS_AIO.cmd"

Write-Log "Baixando MAS AIO..."
try {
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($MAS_Url, $MAS_Path)
    Write-Log "Download concluído."
} catch {
    Write-Log "Erro crítico no download: $_"
    exit 1
}

# 3. Execução Silenciosa
Write-Log "Executando ativação via Ohook..."
try {
    # /Ohook: Método de ativação permanente em memória
    # /S: Modo silencioso
    $proc = Start-Process -FilePath $MAS_Path -ArgumentList "/Ohook /S" -Wait -PassThru
    
    if ($proc.ExitCode -eq 0) {
        Write-Log "Ativação concluída com sucesso."
    } else {
        Write-Log "Ativação finalizada com código: $($proc.ExitCode)"
    }
} catch {
    Write-Log "Erro ao executar o MAS: $_"
} finally {
    # 4. Limpeza
    Write-Log "Limpando diretório temporário..."
    Remove-Item -Path $Script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Log "Processo finalizado."
