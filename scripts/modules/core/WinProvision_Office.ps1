# Módulo de Instalação do Office via Office Tool Plus
#
# EXECUÇÃO: este script foi desenhado para rodar de forma autônoma (sem nenhuma
# interação com o usuário) e retornar um código de saída (exit code) indicando o
# resultado. Invoque-o como um PROCESSO SEPARADO (ex.: pwsh.exe -File Install-Office.ps1
# ou Start-Process pwsh -ArgumentList '-File','Install-Office.ps1' -Wait -PassThru) e
# leia $LASTEXITCODE / $Process.ExitCode. Se este arquivo for "dot-sourced" (". .\Install-Office.ps1")
# dentro de um orquestrador maior, os `exit` abaixo vão encerrar o PROCESSO INTEIRO do
# orquestrador também — nesse caso, prefira chamá-lo sempre como processo filho.
#
# CÓDIGOS DE SAÍDA:
#   0 = OK - Office ja estava instalado, ou foi instalado com sucesso
#   1 = Falha ao consultar a API do GitHub (informacoes da release do OTP)
#   2 = Asset ZIP x64 nao encontrado no release do OTP
#   3 = Falha no download do pacote do OTP
#   4 = Falha ao extrair o pacote do OTP
#   5 = Executavel do OTP (Office Tool Plus.Console.exe) nao encontrado apos a extracao
#   6 = Timeout aguardando a confirmacao de conclusao da instalacao (chave de registro
#       do ClickToRun nao foi populada dentro do prazo)
#   7 = O OTP Console encerrou mas a instalacao nao pode ser confirmada por outro motivo
#   8 = Erro inesperado / nao tratado
#   9 = Outra instancia deste script ja esta em execucao nesta maquina (mutex ocupado)

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # evita a barra de progresso do Invoke-WebRequest/RestMethod (ganho de velocidade no download)

$OtpApiUrl       = 'https://api.github.com/repos/YerongAI/Office-Tool/releases/latest'
$TempDir         = Join-Path -Path $env:SystemRoot -ChildPath 'Temp\OTP_Provisioning'
$ZipFile         = Join-Path -Path $TempDir -ChildPath 'OTP.zip'
$ExeName         = 'Office Tool Plus.Console.exe'
$ProcessArgs     = 'deploy /add O365HomePremRetail_pt-br /channel Current /edition 64 /display False /acpteula True'
$SetupTimeoutMin = 60
$MaxRetries      = 3
$RetryDelaySec   = 5
$PollIntervalSec = 15   # intervalo de checagem da conclusao real da instalacao
$StartGraceMin   = 5    # tolerancia antes de avisar que nenhum sinal do instalador apareceu

$LogDir  = Join-Path -Path $env:TEMP -ChildPath 'WinProvision'
$LogFile = Join-Path -Path $LogDir -ChildPath 'office-install.log'

$MutexName = 'Global\WinProvision_OfficeInstall'

# ========== CÓDIGOS DE SAÍDA (variáveis, para não espalhar números mágicos pelo script) ==========
$EXIT_SUCCESS           = 0
$EXIT_API_FAILED        = 1
$EXIT_ASSET_NOT_FOUND   = 2
$EXIT_DOWNLOAD_FAILED   = 3
$EXIT_EXTRACT_FAILED    = 4
$EXIT_EXE_NOT_FOUND     = 5
$EXIT_CONFIRM_TIMEOUT   = 6
$EXIT_INSTALL_FAILED    = 7
$EXIT_UNEXPECTED        = 8
$EXIT_ALREADY_RUNNING   = 9

# ========== FUNÇÕES DE LOG ==========
# Como o script roda sem console interativo em muitos casos, TODO diagnostico relevante
# vai para o arquivo de log - o console (Write-Host) e so um complemento para quando
# alguem estiver acompanhando ao vivo.

function Write-Log([string]$Message) {
    if (-not (Test-Path $LogDir)) { $null = New-Item -ItemType Directory -Path $LogDir -Force }
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $line
}

function Write-Step([string]$Message) {
    Write-Host "`n[STEP] $Message" -ForegroundColor Cyan
    Write-Log "STEP: $Message"
}

function Write-Success([string]$Message) {
    Write-Host $Message -ForegroundColor Green
    Write-Log "OK: $Message"
}

function Write-ErrorMsg([string]$Message) {
    Write-Host $Message -ForegroundColor Red
    Write-Log "ERRO: $Message"
}

# ========== FUNÇÕES AUXILIARES ==========

function Test-OfficeInstalled {
    $OfficeRegPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration'
    )
    foreach ($RegPath in $OfficeRegPaths) {
        if (Test-Path -Path $RegPath) {
            $ProductIds = (Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue).ProductReleaseIds
            if ($ProductIds) { return $ProductIds }
        }
    }
    return $null
}

function Clear-OTPProcesses {
    $ProcessesToKill = @('Office Tool Plus.Console', 'Office Tool Plus', 'setup')
    foreach ($ProcName in $ProcessesToKill) {
        Get-Process -Name $ProcName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Set-Location -Path $env:SystemRoot
    [System.GC]::Collect()
    Start-Sleep -Seconds 1
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$OperationName = 'operação'
    )
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            return & $ScriptBlock
        } catch {
            Write-Log "Tentativa $attempt/$MaxRetries de '$OperationName' falhou: $_"
            if ($attempt -eq $MaxRetries) { throw }
            Start-Sleep -Seconds ($RetryDelaySec * $attempt)
        }
    }
}

function Get-InstallHelperProcesses {
    # Apenas para feedback/log - nenhum deles isoladamente confirma inicio/fim real da instalacao.
    Get-Process -Name 'setup', 'OfficeClickToRun', 'OfficeC2RClient' -ErrorAction SilentlyContinue
}

# ========== 0. CHECAGENS SUAVES DE AMBIENTE (nunca abortam com erro opaco) ==========
# Propositalmente NAO usamos #Requires: um #Requires nao satisfeito aborta o processo
# antes de qualquer log nosso rodar e antes de retornar um dos codigos de saida acima -
# em execucao autonoma isso e pior do que logar o alerta e tentar seguir.

try {
    $IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    Write-Log "Iniciando modulo de instalacao. PSVersion=$($PSVersionTable.PSVersion) Elevado=$IsElevated"
    if (-not $IsElevated) {
        Write-Log 'AVISO: token nao reportado como elevado. Instalacao do Office e escrita em HKLM exigem privilegios administrativos; se a instalacao falhar adiante, comece a investigar por aqui.'
    }
} catch {
    Write-Log "AVISO: nao foi possivel verificar o nivel de privilegio: $_"
}

# ========== TRAVA OPCIONAL DE EXECUÇÃO ÚNICA ==========
# Fail-soft de proposito: se por qualquer motivo (privilegio, politica do ambiente etc.)
# nao for possivel criar o mutex, seguimos sem a trava em vez de derrubar o script.
$Mutex = $null
$MutexOwned = $false
try {
    $Mutex = New-Object System.Threading.Mutex($false, $MutexName)
    try {
        $MutexOwned = $Mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $MutexOwned = $true
    }
    if (-not $MutexOwned) {
        Write-Log 'Encerrado: outra instancia ja em execucao (mutex).'
        exit $EXIT_ALREADY_RUNNING
    }
} catch {
    Write-Log "AVISO: nao foi possivel criar/obter a trava de execucao unica, seguindo sem ela: $_"
}

try {
    # ========== 1. VERIFICAÇÃO DE INSTALAÇÃO EXISTENTE (idempotência + saída rápida) ==========

    $ExistingProducts = Test-OfficeInstalled
    if ($ExistingProducts) {
        Write-Success "Office ja esta instalado nesta maquina ($ExistingProducts). Operacao cancelada."
        exit $EXIT_SUCCESS
    }

    Write-Step 'Limpando processos antigos...'
    Clear-OTPProcesses

    if (Test-Path -Path $TempDir) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $TempDir -ItemType Directory -Force | Out-Null

    $Headers = @{ 'User-Agent' = 'WinProvision' }

    # ---------- 2. Consulta a API do GitHub (com retry) ----------
    Write-Step 'Consultando API do GitHub para obter a versao mais recente...'
    try {
        $ReleaseInfo = Invoke-WithRetry -OperationName 'consulta a API do GitHub' -ScriptBlock {
            Invoke-RestMethod -Uri $OtpApiUrl -Headers $Headers -TimeoutSec 30
        }
    } catch {
        Write-ErrorMsg "Falha ao consultar a API do GitHub apos $MaxRetries tentativas: $_"
        exit $EXIT_API_FAILED
    }

    $Asset = $ReleaseInfo.assets | Where-Object { $_.name -like 'Office_Tool_with_runtime_*_x64.zip' } | Select-Object -First 1
    if (-not $Asset) {
        Write-ErrorMsg "Nao foi possivel encontrar o pacote x64 do OTP na release $($ReleaseInfo.tag_name)."
        exit $EXIT_ASSET_NOT_FOUND
    }

    # ---------- 3. Download ----------
    Write-Step "Baixando o Office Tool Plus ($($ReleaseInfo.tag_name))..."
    try {
        Invoke-WithRetry -OperationName 'download do OTP' -ScriptBlock {
            Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $ZipFile -Headers $Headers -TimeoutSec 180
        } | Out-Null

        if (-not (Test-Path -Path $ZipFile) -or (Get-Item -Path $ZipFile).Length -eq 0) {
            throw 'O arquivo ZIP baixado esta ausente ou vazio.'
        }
    } catch {
        Write-ErrorMsg "Falha no download do OTP: $_"
        exit $EXIT_DOWNLOAD_FAILED
    }

    # ---------- 4. Extração ----------
    Write-Step 'Extraindo os arquivos...'
    try {
        Expand-Archive -Path $ZipFile -DestinationPath $TempDir -Force
    } catch {
        Write-ErrorMsg "Falha ao extrair o pacote do OTP: $_"
        exit $EXIT_EXTRACT_FAILED
    }

    # ---------- 5. Localização do executável ----------
    $ExeItem = Get-ChildItem -Path $TempDir -Filter $ExeName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ExeItem) {
        Write-ErrorMsg "O executavel '$ExeName' nao foi localizado apos a extracao."
        exit $EXIT_EXE_NOT_FOUND
    }
    $ExePath       = $ExeItem.FullName
    $WorkingFolder = $ExeItem.DirectoryName

    # ---------- 6. Execução do OTP Console (log em arquivo - necessário em execução não interativa) ----------
    Write-Step 'Iniciando a instalacao do Office 365...'
    Write-Log "Executando: `"$ExePath`" $ProcessArgs"

    $StdOutLog = Join-Path -Path $WorkingFolder -ChildPath 'deploy_stdout.log'
    $StdErrLog = Join-Path -Path $WorkingFolder -ChildPath 'deploy_stderr.log'

    Set-Location -Path $WorkingFolder
    $Process = Start-Process -FilePath $ExePath -ArgumentList $ProcessArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $StdOutLog -RedirectStandardError $StdErrLog
    Set-Location -Path $env:SystemRoot
    Write-Log "OTP Console finalizado com ExitCode $($Process.ExitCode)"

    # ---------- 7. Aguarda a conclusão REAL da instalação ----------
    # O OTP Console e o instalador da Microsoft (setup.exe / OfficeClickToRun.exe) funcionam
    # de forma assincrona ("fire-and-forget"). Por isso o sinal de conclusao NAO e o ciclo de
    # vida de um processo, e sim a chave de registro do ClickToRun sendo criada - checada em
    # loop, com feedback de progresso registrado no log.
    Write-Step "Aguardando a conclusao da instalacao do Office (timeout: $SetupTimeoutMin min)..."

    $Timer                 = [System.Diagnostics.Stopwatch]::StartNew()
    $TimeoutSpan           = [TimeSpan]::FromMinutes($SetupTimeoutMin)
    $InstalledAfterDeploy  = $null
    $EverSawInstallerAlive = $false

    while ($Timer.Elapsed -lt $TimeoutSpan) {
        $InstalledAfterDeploy = Test-OfficeInstalled
        if ($InstalledAfterDeploy) { break }

        $HelperProcs = Get-InstallHelperProcesses
        if ($HelperProcs) { $EverSawInstallerAlive = $true }

        $StatusMsg = if ($HelperProcs) {
            "instalador ativo ($((($HelperProcs).ProcessName | Select-Object -Unique) -join ', '))"
        } elseif (-not $EverSawInstallerAlive -and $Timer.Elapsed.TotalMinutes -gt $StartGraceMin) {
            "nenhum sinal do instalador ainda apos $StartGraceMin min - pode ter falhado ao iniciar"
        } else {
            'aguardando confirmacao de conclusao...'
        }

        Write-Log "Aguardando instalacao... [$([int]$Timer.Elapsed.TotalMinutes) min] $StatusMsg"
        Start-Sleep -Seconds $PollIntervalSec
    }
    $Timer.Stop()

    if (-not $InstalledAfterDeploy) {
        $ErrContent = if (Test-Path $StdErrLog) { Get-Content $StdErrLog -Raw -ErrorAction SilentlyContinue } else { 'Log de erro ausente.' }
        $OutContent = if (Test-Path $StdOutLog) { Get-Content $StdOutLog -Raw -ErrorAction SilentlyContinue } else { 'Log de saida ausente.' }
        Write-Log "STDOUT do deploy:`n$OutContent"
        Write-Log "STDERR do deploy:`n$ErrContent"

        Write-ErrorMsg "Timeout de $SetupTimeoutMin minutos atingido aguardando a conclusao da instalacao (ExitCode do OTP Console: $($Process.ExitCode))."
        exit $EXIT_CONFIRM_TIMEOUT
    }

    # ---------- 8. Sucesso ----------
    Write-Success "SUCESSO: Office instalado com sucesso ($InstalledAfterDeploy)!"
    Clear-OTPProcesses
    if (Test-Path -Path $TempDir) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit $EXIT_SUCCESS
}
catch {
    Write-ErrorMsg "Erro inesperado: $($_.Exception.Message)"
    Write-Log "STACKTRACE: $($_.ScriptStackTrace)"
    exit $EXIT_UNEXPECTED
}
finally {
    # Roda mesmo quando um dos `exit` acima e disparado de dentro do try:
    # garante que nenhum processo do OTP/setup fique pendurado e libera o mutex.
    Clear-OTPProcesses
    if ($MutexOwned -and $Mutex) {
        try { $Mutex.ReleaseMutex() } catch { }
    }
    if ($Mutex) { $Mutex.Dispose() }
}
