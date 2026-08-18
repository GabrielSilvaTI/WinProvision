#Requires -Version 7.0

using namespace System.Security.Principal
using namespace System.Threading
using namespace System.Diagnostics
using namespace System.IO

Set-StrictMode -Version Latest

# Funções dentro de um módulo (.psm1) não herdam $ErrorActionPreference /
# $ProgressPreference do escopo do script chamador (Orquestrador) — usam o
# escopo do próprio módulo, que por padrão é 'Continue'. Definidas aqui,
# valem para todo o módulo, consistente com Install-Winget/Install-Programas.
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

<#
.SYNOPSIS
    Módulo para instalação autônoma e gerenciamento do Microsoft Office via Office Tool Plus (OTP).
#>

#region Funções privadas (internas)

function Write-OfficeInstallLog {
    <#
    .SYNOPSIS
        Grava uma linha de log em arquivo e a exibe no console, conforme o nível informado.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogDir,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogFile,

        [ValidateSet('STEP', 'OK', 'ERRO', 'INFO')]
        [string]$Level = 'INFO'
    )

    if (-not (Test-Path -Path $LogDir)) {
        $null = New-Item -ItemType Directory -Path $LogDir -Force
    }

    $line = "[$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue

    switch ($Level) {
        'STEP' { Write-Host "`n[STEP] $Message" -ForegroundColor Cyan }
        'OK' { Write-Host $Message -ForegroundColor Green }
        'ERRO' { Write-Host $Message -ForegroundColor Red }
        'INFO' { Write-Verbose $Message }
    }
}

function Test-OfficeInstalled {
    <#
    .SYNOPSIS
        Verifica, via registro, se algum produto do Office (Click-to-Run) já está instalado.
    .OUTPUTS
        System.String. Os IDs dos produtos instalados, ou $null caso nenhum seja encontrado.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $officeRegPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration'
    )

    foreach ($regPath in $officeRegPaths) {
        if (Test-Path -Path $regPath) {
            try {
                $productIds = Get-ItemPropertyValue -Path $regPath -Name 'ProductReleaseIds' -ErrorAction Stop
                if ($productIds) { return $productIds }
            }
            catch {
                # Ignora a ausência da propriedade/valor e prossegue com o fluxo
            }
        }
    }

    return $null
}

function Clear-OTPProcess {
    <#
    .SYNOPSIS
        Encerra processos residuais do Office Tool Plus e do setup do Office.
    #>
    [CmdletBinding()]
    param()

    $processesToKill = @('Office Tool Plus.Console', 'Office Tool Plus', 'setup')
    foreach ($procName in $processesToKill) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Set-Location -Path $env:SystemRoot
    [System.GC]::Collect()
    Start-Sleep -Seconds 1
}

function Get-InstallHelperProcess {
    <#
    .SYNOPSIS
        Retorna os processos ativos relacionados à instalação do Office (setup / Click-to-Run).
    #>
    [CmdletBinding()]
    param()

    Get-Process -Name 'setup', 'OfficeClickToRun', 'OfficeC2RClient' -ErrorAction SilentlyContinue
}

#endregion

#region Funções públicas (exportadas)

function Install-Office {
    <#
    .SYNOPSIS
        Instala o Microsoft Office de forma autônoma utilizando o Office Tool Plus.
    .DESCRIPTION
        Consulta a versão mais recente do OTP no GitHub, realiza o download da versão x64,
        extrai o instalador e executa a instalação do Office 365 de forma idempotente.
    .PARAMETER ProductId
        Identificador do produto a ser instalado.
    .PARAMETER Channel
        Canal de atualização do Office.
    .PARAMETER Architecture
        Arquitetura do Office (32 ou 64).
    .PARAMETER SetupTimeoutMin
        Tempo máximo em minutos para aguardar a conclusão da instalação do Office
        (após o OTP Console ter sido iniciado).
    .PARAMETER MaxRetries
        Número máximo de tentativas para cada requisição HTTP (consulta à API e download).
    .PARAMETER TimeoutSec
        Timeout, em segundos, para a consulta à API do GitHub.
    .PARAMETER DownloadTimeoutSec
        Timeout, em segundos, para o download do pacote do Office Tool Plus.
    .EXAMPLE
        Import-Module .\Install-Office.psd1
        Install-Office
    .EXAMPLE
        Install-Office -ProductId 'O365ProPlusRetail_pt-br' -Channel 'MonthlyEnterprise' -Verbose
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ProductId = 'O365HomePremRetail_pt-br',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Channel = 'Current',

        [Parameter()]
        [ValidateSet('32', '64')]
        [string]$Architecture = '64',

        [Parameter()]
        [ValidateRange(1, 1440)]
        [int]$SetupTimeoutMin = 60,

        [Parameter()]
        [ValidateRange(1, 10)]
        [int]$MaxRetries = 3,

        [Parameter()]
        [ValidateRange(5, 300)]
        [int]$TimeoutSec = 30,

        [Parameter()]
        [ValidateRange(30, 900)]
        [int]$DownloadTimeoutSec = 180
    )

    $otpApiUrl = 'https://api.github.com/repos/YerongAI/Office-Tool/releases/latest'
    $tempDir = Join-Path -Path $env:SystemRoot -ChildPath 'Temp\OTP_Provisioning'
    $zipFile = Join-Path -Path $tempDir -ChildPath 'OTP.zip'
    $exeName = 'Office Tool Plus.Console.exe'
    $processArgs = @(
        'deploy', '/add', $ProductId,
        '/channel', $Channel,
        '/edition', $Architecture,
        '/display', 'False',
        '/acpteula', 'True'
    )
    $pollIntervalSec = 15
    $startGraceMin = 5

    $logDir = Join-Path -Path $env:TEMP -ChildPath 'WinProvision'
    $logFile = Join-Path -Path $logDir -ChildPath 'office-install.log'
    $mutexName = 'Global\WinProvision_OfficeInstall'

    # Splat com os parâmetros fixos de log, reutilizado em todas as chamadas
    $logParams = @{ LogDir = $logDir; LogFile = $logFile }

    # Checagem de privilégio
    try {
        $isElevated = [WindowsPrincipal]::new([WindowsIdentity]::GetCurrent()).IsInRole([WindowsBuiltInRole]::Administrator)
        Write-OfficeInstallLog @logParams -Message "Iniciando módulo de instalação do Office. PSVersion=$($PSVersionTable.PSVersion) Elevado=$isElevated" -Level INFO
        if (-not $isElevated) {
            Write-OfficeInstallLog @logParams -Message 'AVISO: Token não reportado como elevado. A instalação do Office exige privilégios administrativos.' -Level INFO
        }
    }
    catch {
        Write-OfficeInstallLog @logParams -Message "AVISO: Não foi possível verificar nível de privilégio: $_" -Level INFO
    }

    # Trava de execução única (mutex)
    $mutex = $null
    $mutexOwned = $false
    try {
        $mutex = [Mutex]::new($false, $mutexName)
        try {
            $mutexOwned = $mutex.WaitOne(0)
        }
        catch [AbandonedMutexException] {
            $mutexOwned = $true
        }

        if (-not $mutexOwned) {
            Write-OfficeInstallLog @logParams -Message 'Encerrado: Outra instância já está em execução (mutex ocupado).' -Level ERRO
            throw [System.InvalidOperationException]::new('Outra instância deste instalador já está em execução nesta máquina.')
        }
    }
    catch [System.InvalidOperationException] {
        throw
    }
    catch {
        Write-OfficeInstallLog @logParams -Message "AVISO: Não foi possível obter a trava de execução única: $_" -Level INFO
    }

    try {
        # 1. Verificação de idempotência
        $existingProducts = Test-OfficeInstalled
        if ($existingProducts) {
            Write-OfficeInstallLog @logParams -Message "Office já está instalado nesta máquina ($existingProducts). Operação concluída." -Level OK
            return $true
        }

        Write-OfficeInstallLog @logParams -Message 'Limpando processos antigos...' -Level STEP
        Clear-OTPProcess

        if (Test-Path -Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $null = New-Item -Path $tempDir -ItemType Directory -Force

        $headers = @{ 'User-Agent' = 'WinProvision' }

        # 2. Consulta à API do GitHub
        Write-OfficeInstallLog @logParams -Message 'Consultando API do GitHub para obter a versão mais recente...' -Level STEP
        try {
            $releaseInfo = Invoke-RestMethod -Uri $otpApiUrl -Headers $headers `
                -TimeoutSec $TimeoutSec `
                -MaximumRetryCount $MaxRetries `
                -RetryIntervalSec 2
        }
        catch {
            Write-OfficeInstallLog @logParams -Message "Falha ao consultar API do GitHub: $_" -Level ERRO
            throw [System.Net.WebException]::new("Falha ao consultar a API do GitHub: $_", $_.Exception)
        }

        $asset = $releaseInfo.assets | Where-Object name -like 'Office_Tool_with_runtime_*_x64.zip' | Select-Object -First 1
        if (-not $asset) {
            Write-OfficeInstallLog @logParams -Message "Pacote x64 não encontrado no release $($releaseInfo.tag_name)." -Level ERRO
            throw [FileNotFoundException]::new("Não foi possível encontrar o pacote x64 do OTP na release $($releaseInfo.tag_name).")
        }

        # 3. Download
        Write-OfficeInstallLog @logParams -Message "Baixando Office Tool Plus ($($releaseInfo.tag_name))..." -Level STEP
        try {
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipFile -Headers $headers `
                -TimeoutSec $DownloadTimeoutSec `
                -MaximumRetryCount $MaxRetries `
                -RetryIntervalSec 2

            $downloadedFile = Get-Item -Path $zipFile -ErrorAction SilentlyContinue
            if (-not $downloadedFile -or $downloadedFile.Length -eq 0) {
                throw 'O arquivo ZIP baixado está ausente ou vazio.'
            }
        }
        catch {
            Write-OfficeInstallLog @logParams -Message "Falha no download do OTP: $_" -Level ERRO
            throw
        }

        # 4. Extração
        Write-OfficeInstallLog @logParams -Message 'Extraindo arquivos do OTP...' -Level STEP
        try {
            Expand-Archive -Path $zipFile -DestinationPath $tempDir -Force
        }
        catch {
            Write-OfficeInstallLog @logParams -Message "Falha ao extrair pacote do OTP: $_" -Level ERRO
            throw
        }

        # 5. Localização do executável
        $exeItem = Get-ChildItem -Path $tempDir -Filter $exeName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $exeItem) {
            Write-OfficeInstallLog @logParams -Message "Executável '$exeName' não localizado." -Level ERRO
            throw [FileNotFoundException]::new("O executável '$exeName' não foi localizado após a extração.")
        }
        $exePath = $exeItem.FullName
        $workingFolder = $exeItem.DirectoryName

        # 6. Execução do OTP Console
        Write-OfficeInstallLog @logParams -Message 'Iniciando a instalação do Office...' -Level STEP
        Write-OfficeInstallLog @logParams -Message "Executando: `"$exePath`" $($processArgs -join ' ')" -Level INFO

        if ($PSCmdlet.ShouldProcess("Microsoft Office ($ProductId)", 'Instalar via Office Tool Plus')) {
            $stdOutLog = Join-Path -Path $workingFolder -ChildPath 'deploy_stdout.log'
            $stdErrLog = Join-Path -Path $workingFolder -ChildPath 'deploy_stderr.log'

            Set-Location -Path $workingFolder
            $process = Start-Process -FilePath $exePath -ArgumentList $processArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdOutLog -RedirectStandardError $stdErrLog
            Set-Location -Path $env:SystemRoot
            Write-OfficeInstallLog @logParams -Message "OTP Console finalizado com ExitCode $($process.ExitCode)" -Level INFO

            # 7. Aguarda conclusão real da instalação
            Write-OfficeInstallLog @logParams -Message "Aguardando conclusão da instalação do Office (timeout: $SetupTimeoutMin min)..." -Level STEP

            $timer = [Stopwatch]::StartNew()
            $timeoutSpan = [timespan]::FromMinutes($SetupTimeoutMin)
            $installedAfterDeploy = $null
            $everSawInstallerAlive = $false

            while ($timer.Elapsed -lt $timeoutSpan) {
                $installedAfterDeploy = Test-OfficeInstalled
                if ($installedAfterDeploy) { break }

                $helperProcs = Get-InstallHelperProcess
                if ($helperProcs) { $everSawInstallerAlive = $true }

                $statusMsg = if ($helperProcs) {
                    "Instalador ativo ($(($helperProcs.ProcessName | Select-Object -Unique) -join ', '))"
                }
                elseif (-not $everSawInstallerAlive -and $timer.Elapsed.TotalMinutes -gt $startGraceMin) {
                    "Nenhum sinal do instalador após $startGraceMin min - pode ter falhado ao iniciar"
                }
                else {
                    'Aguardando confirmação de conclusão...'
                }

                Write-OfficeInstallLog @logParams -Message "Aguardando instalação... [$([int]$timer.Elapsed.TotalMinutes) min] $statusMsg" -Level INFO
                Start-Sleep -Seconds $pollIntervalSec
            }
            $timer.Stop()

            if (-not $installedAfterDeploy) {
                $errContent = if (Test-Path -Path $stdErrLog) { Get-Content -Path $stdErrLog -Raw -ErrorAction SilentlyContinue } else { 'Log de erro ausente.' }
                $outContent = if (Test-Path -Path $stdOutLog) { Get-Content -Path $stdOutLog -Raw -ErrorAction SilentlyContinue } else { 'Log de saída ausente.' }
                Write-OfficeInstallLog @logParams -Message "STDOUT do deploy:`n$outContent" -Level INFO
                Write-OfficeInstallLog @logParams -Message "STDERR do deploy:`n$errContent" -Level INFO

                if (-not $everSawInstallerAlive) {
                    Write-OfficeInstallLog @logParams -Message 'O instalador nunca deu sinal de vida (setup/OfficeClickToRun não detectados).' -Level ERRO
                    throw 'O instalador nunca deu sinal de vida (setup/OfficeClickToRun não foram iniciados).'
                }

                Write-OfficeInstallLog @logParams -Message "Timeout de $SetupTimeoutMin minutos atingido." -Level ERRO
                throw "Timeout de $SetupTimeoutMin minutos atingido aguardando a conclusão da instalação."
            }

            Write-OfficeInstallLog @logParams -Message "SUCESSO: Office instalado com sucesso ($installedAfterDeploy)!" -Level OK
        }

        return $true
    }
    catch {
        Write-OfficeInstallLog @logParams -Message "Erro inesperado: $_" -Level ERRO
        throw
    }
    finally {
        Clear-OTPProcess
        if (Test-Path -Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($mutexOwned -and $mutex) {
            try {
                $mutex.ReleaseMutex()
            }
            catch {
                Write-OfficeInstallLog @logParams -Message "AVISO: Falha ao liberar mutex: $_" -Level INFO
            }
        }
        if ($mutex) { $mutex.Dispose() }
    }
}

#endregion

Export-ModuleMember -Function Install-Office
