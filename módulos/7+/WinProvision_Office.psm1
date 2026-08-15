#Requires -Version 7.0

<#
.SYNOPSIS
    Módulo para instalação autônoma e gerenciamento do Microsoft Office via Office Tool Plus (OTP).
#>

# ============================================================================
# FUNÇÕES PRIVADAS (Internas do Módulo)
# ============================================================================

function Write-OfficeInstallLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$LogDir,
        [Parameter(Mandatory)][string]$LogFile,
        [ValidateSet('STEP', 'OK', 'ERRO', 'INFO')][string]$Level = 'INFO'
    )

    if (-not (Test-Path $LogDir)) { 
        $null = New-Item -ItemType Directory -Path $LogDir -Force 
    }
    $line = "[$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue

    switch ($Level) {
        'STEP' { Write-Host "`n[STEP] $Message" -ForegroundColor Cyan }
        'OK'   { Write-Host $Message -ForegroundColor Green }
        'ERRO' { Write-Host $Message -ForegroundColor Red }
        'INFO' { Write-Verbose $Message }
    }
}

function Test-OfficeInstalled {
    [CmdletBinding()]
    [OutputType([string])]
    param()

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

function Clear-OTPProcess {
    [CmdletBinding()]
    param()

    $ProcessesToKill = @('Office Tool Plus.Console', 'Office Tool Plus', 'setup')
    foreach ($ProcName in $ProcessesToKill) {
        Get-Process -Name $ProcName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Set-Location -Path $env:SystemRoot
    [System.GC]::Collect()
    Start-Sleep -Seconds 1
}

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$OperationName = 'operação',
        [int]$MaxRetries = 3,
        [int]$RetryDelaySec = 5,
        [string]$LogDir,
        [string]$LogFile
    )
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            return & $ScriptBlock
        } catch {
            Write-OfficeInstallLog -Message "Tentativa $attempt/$MaxRetries de '$OperationName' falhou: $_" -LogDir $LogDir -LogFile $LogFile -Level INFO
            if ($attempt -eq $MaxRetries) { throw }
            Start-Sleep -Seconds ($RetryDelaySec * $attempt)
        }
    }
}

function Get-InstallHelperProcess {
    [CmdletBinding()]
    param()

    Get-Process -Name 'setup', 'OfficeClickToRun', 'OfficeC2RClient' -ErrorAction SilentlyContinue
}

# ============================================================================
# FUNÇÕES PÚBLICAS (Exportadas)
# ============================================================================

function Install-Office {
    <#
    .SYNOPSIS
        Instala o Microsoft Office de forma autônoma utilizando o Office Tool Plus.
    .DESCRIPTION
        Consulta a versão mais recente do OTP no GitHub, realiza o download da versão x64,
        extrai o instalador e executa a instalação do Office 365 de forma idempotente.
    .PARAMETER ProductId
        Identificador do produto a ser instalado. Padrão: 'O365HomePremRetail_pt-br'.
    .PARAMETER Channel
        Canal de atualização do Office. Padrão: 'Current'.
    .PARAMETER Architecture
        Arquitetura do Office (32 ou 64). Padrão: '64'.
    .PARAMETER SetupTimeoutMin
        Tempo máximo em minutos para aguardar a conclusão da instalação. Padrão: 60.
    .EXAMPLE
        Import-Module .\Install-Office.psd1
        Install-Office
    .EXAMPLE
        Install-Office -ProductId 'O365ProPlusRetail_pt-br' -Channel 'MonthlyEnterprise' -Verbose
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter()]
        [string]$ProductId = 'O365HomePremRetail_pt-br',

        [Parameter()]
        [string]$Channel = 'Current',

        [Parameter()]
        [ValidateSet('32', '64')]
        [string]$Architecture = '64',

        [Parameter()]
        [int]$SetupTimeoutMin = 60
    )

    $ProgressPreference = 'SilentlyContinue'

    $OtpApiUrl       = 'https://api.github.com/repos/YerongAI/Office-Tool/releases/latest'
    $TempDir         = Join-Path -Path $env:SystemRoot -ChildPath 'Temp\OTP_Provisioning'
    $ZipFile         = Join-Path -Path $TempDir -ChildPath 'OTP.zip'
    $ExeName         = 'Office Tool Plus.Console.exe'
    $ProcessArgs     = "deploy /add $ProductId /channel $Channel /edition $Architecture /display False /acpteula True"
    $MaxRetries      = 3
    $RetryDelaySec   = 5
    $PollIntervalSec = 15
    $StartGraceMin   = 5

    $LogDir  = Join-Path -Path $env:TEMP -ChildPath 'WinProvision'
    $LogFile = Join-Path -Path $LogDir -ChildPath 'office-install.log'
    $MutexName = 'Global\WinProvision_OfficeInstall'

    # Checagens de Privilégio
    try {
        $IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
        Write-OfficeInstallLog -Message "Iniciando módulo de instalação do Office. PSVersion=$($PSVersionTable.PSVersion) Elevado=$IsElevated" -LogDir $LogDir -LogFile $LogFile -Level INFO
        if (-not $IsElevated) {
            Write-OfficeInstallLog -Message 'AVISO: Token não reportado como elevado. A instalação do Office exige privilégios administrativos.' -LogDir $LogDir -LogFile $LogFile -Level INFO
        }
    } catch {
        Write-OfficeInstallLog -Message "AVISO: Não foi possível verificar nível de privilégio: $_" -LogDir $LogDir -LogFile $LogFile -Level INFO
    }

    # Trava de Execução Única (Mutex)
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
            Write-OfficeInstallLog -Message 'Encerrado: Outra instância já está em execução (mutex ocupado).' -LogDir $LogDir -LogFile $LogFile -Level ERRO
            throw [System.InvalidOperationException]::new('Outra instância deste instalador já está em execução nesta máquina.')
        }
    } catch [System.InvalidOperationException] {
        throw
    } catch {
        Write-OfficeInstallLog -Message "AVISO: Não foi possível obter a trava de execução única: $_" -LogDir $LogDir -LogFile $LogFile -Level INFO
    }

    try {
        # 1. Verificação de Idempotência
        $ExistingProducts = Test-OfficeInstalled
        if ($ExistingProducts) {
            Write-OfficeInstallLog -Message "Office já está instalado nesta máquina ($ExistingProducts). Operação concluída." -LogDir $LogDir -LogFile $LogFile -Level OK
            return $true
        }

        Write-OfficeInstallLog -Message 'Limpando processos antigos...' -LogDir $LogDir -LogFile $LogFile -Level STEP
        Clear-OTPProcess

        if (Test-Path -Path $TempDir) {
            Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $null = New-Item -Path $TempDir -ItemType Directory -Force

        $Headers = @{ 'User-Agent' = 'WinProvision' }

        # 2. Consulta API do GitHub
        Write-OfficeInstallLog -Message 'Consultando API do GitHub para obter a versão mais recente...' -LogDir $LogDir -LogFile $LogFile -Level STEP
        try {
            $ReleaseInfo = Invoke-WithRetry -OperationName 'consulta à API do GitHub' -LogDir $LogDir -LogFile $LogFile -ScriptBlock {
                Invoke-RestMethod -Uri $OtpApiUrl -Headers $Headers -TimeoutSec 30
            }
        } catch {
            Write-OfficeInstallLog -Message "Falha ao consultar API do GitHub: $_" -LogDir $LogDir -LogFile $LogFile -Level ERRO
            throw [System.Net.WebException]::new("Falha ao consultar a API do GitHub após $MaxRetries tentativas: $_")
        }

        $Asset = $ReleaseInfo.assets | Where-Object { $_.name -like 'Office_Tool_with_runtime_*_x64.zip' } | Select-Object -First 1
        if (-not $Asset) {
            Write-OfficeInstallLog -Message "Pacote x64 não encontrado no release $($ReleaseInfo.tag_name)." -LogDir $LogDir -LogFile $LogFile -Level ERRO
            throw [System.IO.FileNotFoundException]::new("Não foi possível encontrar o pacote x64 do OTP na release $($ReleaseInfo.tag_name).")
        }

        # 3. Download
        Write-OfficeInstallLog -Message "Baixando Office Tool Plus ($($ReleaseInfo.tag_name))..." -LogDir $LogDir -LogFile $LogFile -Level STEP
        try {
            Invoke-WithRetry -OperationName 'download do OTP' -LogDir $LogDir -LogFile $LogFile -ScriptBlock {
                Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $ZipFile -Headers $Headers -TimeoutSec 180
            } | Out-Null

            if (-not (Test-Path -Path $ZipFile) -or (Get-Item -Path $ZipFile).Length -eq 0) {
                throw 'O arquivo ZIP baixado está ausente ou vazio.'
            }
        } catch {
            Write-OfficeInstallLog -Message "Falha no download do OTP: $_" -LogDir $LogDir -LogFile $LogFile -Level ERRO
            throw
        }

        # 4. Extração
        Write-OfficeInstallLog -Message 'Extraindo arquivos do OTP...' -LogDir $LogDir -LogFile $LogFile -Level STEP
        try {
            Expand-Archive -Path $ZipFile -DestinationPath $TempDir -Force
        } catch {
            Write-OfficeInstallLog -Message "Falha ao extrair pacote do OTP: $_" -LogDir $LogDir -LogFile $LogFile -Level ERRO
            throw
        }

        # 5. Localização do Executável
        $ExeItem = Get-ChildItem -Path $TempDir -Filter $ExeName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $ExeItem) {
            Write-OfficeInstallLog -Message "Executável '$ExeName' não localizado." -LogDir $LogDir -LogFile $LogFile -Level ERRO
            throw [System.IO.FileNotFoundException]::new("O executável '$ExeName' não foi localizado após a extração.")
        }
        $ExePath       = $ExeItem.FullName
        $WorkingFolder = $ExeItem.DirectoryName

        # 6. Execução do OTP Console
        Write-OfficeInstallLog -Message 'Iniciando a instalação do Office...' -LogDir $LogDir -LogFile $LogFile -Level STEP
        Write-OfficeInstallLog -Message "Executando: `"$ExePath`" $ProcessArgs" -LogDir $LogDir -LogFile $LogFile -Level INFO

        if ($PSCmdlet.ShouldProcess("Microsoft Office ($ProductId)", "Instalar via Office Tool Plus")) {
            $StdOutLog = Join-Path -Path $WorkingFolder -ChildPath 'deploy_stdout.log'
            $StdErrLog = Join-Path -Path $WorkingFolder -ChildPath 'deploy_stderr.log'

            Set-Location -Path $WorkingFolder
            $Process = Start-Process -FilePath $ExePath -ArgumentList $ProcessArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $StdOutLog -RedirectStandardError $StdErrLog
            Set-Location -Path $env:SystemRoot
            Write-OfficeInstallLog -Message "OTP Console finalizado com ExitCode $($Process.ExitCode)" -LogDir $LogDir -LogFile $LogFile -Level INFO

            # 7. Aguarda Conclusão REAL
            Write-OfficeInstallLog -Message "Aguardando conclusão da instalação do Office (timeout: $SetupTimeoutMin min)..." -LogDir $LogDir -LogFile $LogFile -Level STEP

            $Timer                 = [System.Diagnostics.Stopwatch]::StartNew()
            $TimeoutSpan           = [TimeSpan]::FromMinutes($SetupTimeoutMin)
            $InstalledAfterDeploy  = $null
            $EverSawInstallerAlive = $false

            while ($Timer.Elapsed -lt $TimeoutSpan) {
                $InstalledAfterDeploy = Test-OfficeInstalled
                if ($InstalledAfterDeploy) { break }

                $HelperProcs = Get-InstallHelperProcess
                if ($HelperProcs) { $EverSawInstallerAlive = $true }

                $StatusMsg = if ($HelperProcs) {
                    "Instalador ativo ($((($HelperProcs).ProcessName | Select-Object -Unique) -join ', '))"
                } elseif (-not $EverSawInstallerAlive -and $Timer.Elapsed.TotalMinutes -gt $StartGraceMin) {
                    "Nenhum sinal do instalador após $StartGraceMin min - pode ter falhado ao iniciar"
                } else {
                    'Aguardando confirmação de conclusão...'
                }

                Write-OfficeInstallLog -Message "Aguardando instalação... [$([int]$Timer.Elapsed.TotalMinutes) min] $StatusMsg" -LogDir $LogDir -LogFile $LogFile -Level INFO
                Start-Sleep -Seconds $PollIntervalSec
            }
            $Timer.Stop()

            if (-not $InstalledAfterDeploy) {
                $ErrContent = if (Test-Path $StdErrLog) { Get-Content $StdErrLog -Raw -ErrorAction SilentlyContinue } else { 'Log de erro ausente.' }
                $OutContent = if (Test-Path $StdOutLog) { Get-Content $StdOutLog -Raw -ErrorAction SilentlyContinue } else { 'Log de saída ausente.' }
                Write-OfficeInstallLog -Message "STDOUT do deploy:`n$OutContent" -LogDir $LogDir -LogFile $LogFile -Level INFO
                Write-OfficeInstallLog -Message "STDERR do deploy:`n$ErrContent" -LogDir $LogDir -LogFile $LogFile -Level INFO

                if (-not $EverSawInstallerAlive) {
                    Write-OfficeInstallLog -Message 'O instalador nunca deu sinal de vida (setup/OfficeClickToRun não detectados).' -LogDir $LogDir -LogFile $LogFile -Level ERRO
                    throw 'O instalador nunca deu sinal de vida (setup/OfficeClickToRun não foram iniciados).'
                }

                Write-OfficeInstallLog -Message "Timeout de $SetupTimeoutMin minutos atingido." -LogDir $LogDir -LogFile $LogFile -Level ERRO
                throw "Timeout de $SetupTimeoutMin minutos atingido aguardando a conclusão da instalação."
            }

            Write-OfficeInstallLog -Message "SUCESSO: Office instalado com sucesso ($InstalledAfterDeploy)!" -LogDir $LogDir -LogFile $LogFile -Level OK
        }

        return $true
    }
    catch {
        Write-OfficeInstallLog -Message "Erro inesperado: $_" -LogDir $LogDir -LogFile $LogFile -Level ERRO
        throw
    }
    finally {
        Clear-OTPProcess
        if (Test-Path -Path $TempDir) {
            Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($MutexOwned -and $Mutex) {
            try {
                $Mutex.ReleaseMutex()
            } catch {
                Write-OfficeInstallLog -Message "AVISO: Falha ao liberar mutex: $_" -LogDir $LogDir -LogFile $LogFile -Level INFO
            }
        }
        if ($Mutex) { $Mutex.Dispose() }
    }
}

Export-ModuleMember -Function Install-Office
