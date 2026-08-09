# Módulo de Instalação do Office via Office Tool Plus
# Garantir encoding UTF-8 com BOM ao salvar este arquivo

[CmdletBinding()]
param(
    # Quando informado pelo Orchestrator, o modulo escreve no mesmo log compartilhado
    [string]$LogPath
)

$ErrorActionPreference = "Stop"

# Forca TLS 1.2/1.3, alinhado aos demais modulos
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

$OtpApiUrl   = "https://api.github.com/repos/YerongAI/Office-Tool/releases/latest"
$FallbackUrl = "https://github.com/GabrielSilvaTI/WinProvision/releases/download/V1/OTP.zip"

# Alterado para SystemRoot\Temp para garantir total compatibilidade com contextos SYSTEM/MDM/SCCM
$TempDir = Join-Path -Path $env:SystemRoot -ChildPath "Temp\OTP_Provisioning"
$ZipFile = Join-Path -Path $TempDir -ChildPath "OTP.zip"
$ExePath = Join-Path -Path $TempDir -ChildPath "Office Tool Plus.Console.exe"

$MaxRetries         = 3
$RetryDelaySec      = 5
$DownloadTimeoutSec = 60

# ==============================================================================
#  LOGGING (compartilhado com o Orchestrator quando -LogPath e informado)
# ==============================================================================
$LogFile = if ($LogPath) { $LogPath } else { Join-Path -Path $TempDir -ChildPath "Office_$(Get-Date -Format 'yyyyMMdd_HHmmss').log" }
$LogFileDir = Split-Path -Path $LogFile -Parent
if ($LogFileDir -and -not (Test-Path $LogFileDir)) {
    New-Item -ItemType Directory -Path $LogFileDir -Force -ErrorAction SilentlyContinue | Out-Null
}

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts [$Level] $Msg"
    try {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        Write-Verbose "Falha ao gravar log no arquivo: $($_.Exception.Message)"
    }
    if ($Level -eq "ERROR") { Write-Host "[$Level] $Msg" -ForegroundColor Red }
    else { Write-Host "[$Level] $Msg" }
}

function Write-ModuleProgress {
    param([int]$Percent, [string]$Status)
    Write-Log "$Percent% - $Status" "PROGRESS"
}

# ==============================================================================
#  DOWNLOAD COM RETRY E VALIDACAO DE ZIP
# ==============================================================================
function Get-OtpAsset {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            Write-Log "Baixando de '$Uri' (tentativa $attempt/$MaxRetries)..." "INFO"
            Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing -TimeoutSec $DownloadTimeoutSec -Headers @{"User-Agent" = "WinProvision"} -ErrorAction Stop

            if (-not (Test-Path $Destination) -or (Get-Item $Destination).Length -eq 0) {
                throw "Arquivo baixado esta vazio ou ausente."
            }

            $TestZip = $null
            try {
                $TestZip = [System.IO.Compression.ZipFile]::OpenRead($Destination)
            } catch {
                throw "Arquivo ZIP corrompido: $($_.Exception.Message)"
            } finally {
                if ($TestZip) { $TestZip.Dispose() }
            }

            return $true
        } catch {
            Write-Log "Falha no download/validacao (tentativa $attempt/$MaxRetries): $($_.Exception.Message)" "WARN"
            Remove-Item $Destination -Force -ErrorAction SilentlyContinue
            if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds $RetryDelaySec }
        }
    }
    return $false
}

function Get-OtpDownloadUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        Write-Log "Consultando release mais recente do OTP..." "INFO"
        $ReleaseInfo = Invoke-RestMethod -Uri $OtpApiUrl -UseBasicParsing -TimeoutSec $DownloadTimeoutSec -Headers @{"User-Agent" = "WinProvision"} -ErrorAction Stop
        $Asset = $ReleaseInfo.assets | Where-Object { $_.name -like "Office_Tool_with_runtime_*_x64.zip" } | Select-Object -First 1
        if (-not $Asset) {
            throw "Nao foi possivel localizar o asset x64 com runtime no release $($ReleaseInfo.tag_name)."
        }
        return $Asset.browser_download_url
    } catch {
        Write-Log "Falha ao consultar a API do GitHub: $($_.Exception.Message)" "WARN"
        return $null
    }
}

# ==============================================================================
#  EXECUCAO PRINCIPAL
# ==============================================================================
Write-Log "Iniciando modulo Office" "INFO"
Write-ModuleProgress -Percent 0 -Status "Iniciando"

# Verificar se o Office já está instalado
$OfficeInstalled = $false
$OfficeRegPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration"
)
foreach ($RegPath in $OfficeRegPaths) {
    if (Test-Path -Path $RegPath) {
        $ProductIds = (Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue).ProductReleaseIds
        if ($ProductIds) {
            $OfficeInstalled = $true
            Write-Log "Office ja esta instalado nesta maquina (ProductReleaseIds: $ProductIds). Instalacao ignorada." "OK"
            break
        }
    }
}

if ($OfficeInstalled) {
    Write-ModuleProgress -Percent 100 -Status "Office ja instalado"
    exit 0
}

Write-ModuleProgress -Percent 10 -Status "Verificacao concluida, preparando instalacao"

try {
    if (Test-Path -Path $TempDir) { Remove-Item -Path $TempDir -Recurse -Force }
    $null = New-Item -Path $TempDir -ItemType Directory

    Write-ModuleProgress -Percent 20 -Status "Resolvendo pacote do OTP"
    $ResolvedUrl = Get-OtpDownloadUrl
    if (-not $ResolvedUrl) { $ResolvedUrl = $FallbackUrl }

    Write-ModuleProgress -Percent 30 -Status "Baixando Office Tool Plus"
    $DownloadOk = Get-OtpAsset -Uri $ResolvedUrl -Destination $ZipFile

    if (-not $DownloadOk -and $ResolvedUrl -ne $FallbackUrl) {
        Write-Log "Tentando fallback fixo apos falha na URL resolvida..." "WARN"
        $DownloadOk = Get-OtpAsset -Uri $FallbackUrl -Destination $ZipFile
    }

    if (-not $DownloadOk) {
        throw "Falha ao baixar o pacote do OTP apos $MaxRetries tentativas (release e fallback)."
    }

    Write-ModuleProgress -Percent 45 -Status "Extraindo pacote"
    Write-Log "Extraindo OTP..." "INFO"
    Expand-Archive -Path $ZipFile -DestinationPath $TempDir -Force

    # Descobrir a pasta real onde o executável está trabalhando
    $WorkingFolder = $TempDir
    if (-not (Test-Path -Path $ExePath)) {
        $Found = Get-ChildItem -Path $TempDir -Filter "Office Tool Plus.Console.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $Found) {
            throw "Executavel do OTP nao encontrado apos extracao em $TempDir."
        }
        $ExePath = $Found.FullName
        $WorkingFolder = $Found.DirectoryName
    }

    Write-ModuleProgress -Percent 55 -Status "Iniciando deployment do Office 365"
    Write-Log "Iniciando deployment do Office 365 (pode levar de 15 a 60 minutos)..." "INFO"
    $ProcessArgs = "deploy /add O365HomePremRetail_pt-br /channel Current /edition 64 /display false /enableupdates true"

    # Logs apontando dinamicamente para a pasta de execução ativa
    $StdOutLog = Join-Path -Path $WorkingFolder -ChildPath "deploy_stdout.log"
    $StdErrLog = Join-Path -Path $WorkingFolder -ChildPath "deploy_stderr.log"

    $Process = Start-Process -FilePath $ExePath -ArgumentList $ProcessArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $StdOutLog -RedirectStandardError $StdErrLog

    if ($Process.ExitCode -eq 0) {
        Write-Log "Office instalado com sucesso." "OK"
        Write-ModuleProgress -Percent 100 -Status "Concluido"
        if (Test-Path -Path $TempDir) { Remove-Item -Path $TempDir -Recurse -Force }
        exit 0
    } else {
        throw "Falha na instalacao do Office. Exit Code: $($Process.ExitCode). Logs salvos em $WorkingFolder."
    }
} catch {
    Write-Log "Erro no modulo Office: $($_.Exception.Message)" "ERROR"
    Write-Log "Arquivos de diagnostico preservados em $TempDir" "WARN"
    exit 1
}
