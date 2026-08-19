#Requires -Version 5.1

using namespace System.Security.Principal
using namespace System.Net

Set-StrictMode -Version Latest

# Funções dentro de um módulo (.psm1) não herdam $ErrorActionPreference /
# $ProgressPreference do escopo do script chamador (Bootstrap) — usam o
# escopo do próprio módulo, que por padrão é 'Continue'. Definidas aqui,
# valem para todo o módulo, consistente com Install-Office/Install-Winget.
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

<#
.SYNOPSIS
    Módulo para verificação e instalação automática do PowerShell 7+ via GitHub Releases,
    com fallback para um JSON "fonte da verdade" e retry em todas as requisições HTTP.
.NOTES
    Compatível com Windows PowerShell 5.1 propositalmente: este módulo é o ponto de entrada
    do provisionamento e pode ser executado antes de o PowerShell 7+ existir na máquina,
    portanto não deve depender de sintaxes exclusivas do PowerShell 7 (operador ternário,
    operador de coalescência nula, ForEach-Object -Parallel, etc.).
#>

#region Funções privadas (internas)

function Write-Pwsh7InstallLog {
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

    $line = '[{0}] [{1}] {2}' -f ([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')), $Level, $Message
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue

    switch ($Level) {
        'STEP' { Write-Host "`n[STEP] $Message" -ForegroundColor Cyan }
        'OK' { Write-Host $Message -ForegroundColor Green }
        'ERRO' { Write-Host $Message -ForegroundColor Red }
        'INFO' { Write-Verbose $Message }
    }
}

function New-TimeoutWebClient {
    <#
    .SYNOPSIS
        Cria um WebClient com timeout configurável (não suportado nativamente pelo WebClient padrão).
    #>
    [CmdletBinding()]
    [OutputType([System.Net.WebClient])]
    param(
        [Parameter(Mandatory)]
        [int]$TimeoutMs
    )

    if (-not ([System.Management.Automation.PSTypeName]'WinProvision.TimeoutWebClient').Type) {
        Add-Type -Language CSharp -TypeDefinition @'
namespace WinProvision {
    public class TimeoutWebClient : System.Net.WebClient {
        public int TimeoutMs = 30000;
        protected override System.Net.WebRequest GetWebRequest(System.Uri address) {
            System.Net.WebRequest request = base.GetWebRequest(address);
            if (request != null) { request.Timeout = this.TimeoutMs; }
            return request;
        }
    }
}
'@
    }

    $client = New-Object -TypeName WinProvision.TimeoutWebClient
    $client.TimeoutMs = $TimeoutMs
    $client.Headers.Add('User-Agent', 'WinProvision')
    return $client
}

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Executa um bloco de script com retry manual (WebClient não possui -MaximumRetryCount nativo,
        diferente de Invoke-RestMethod/Invoke-WebRequest no PS7+).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [Parameter(Mandatory)]
        [string]$OperationName,

        [Parameter(Mandatory)]
        [hashtable]$LogParams,

        [int]$MaxRetries = 3,
        [int]$RetryIntervalSec = 2
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return & $Action
        }
        catch {
            if ($attempt -ge $MaxRetries) {
                throw
            }
            Write-Pwsh7InstallLog @LogParams -Message "Tentativa $attempt/$MaxRetries falhou em '$OperationName': $($_.Exception.Message). Nova tentativa em $RetryIntervalSec s..." -Level INFO
            Start-Sleep -Seconds $RetryIntervalSec
        }
    }
}

function Test-Pwsh7Installed {
    <#
    .SYNOPSIS
        Verifica se existe uma instalação válida do PowerShell 7+ na máquina.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$KnownPath
    )

    $cmd = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    $exePath = if ($cmd) { $cmd.Source } elseif (Test-Path -Path $KnownPath) { $KnownPath } else { $null }

    if (-not $exePath) {
        return $false
    }

    try {
        $rawVersion = (Get-Item -Path $exePath).VersionInfo.ProductVersion
        $cleanVersion = ($rawVersion -split '[-+]')[0]
        return ([version]$cleanVersion).Major -ge 7
    }
    catch {
        # Executável presente mas com versão ilegível: assume-se compatível para evitar reinstalação desnecessária
        return $true
    }
}

function Get-Pwsh7FallbackInfo {
    <#
    .SYNOPSIS
        Consulta o JSON de fallback ("fonte da verdade") com a URL e o hash SHA256 do
        instalador do PowerShell 7+, usado quando a API do GitHub está indisponível.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$FallbackUrl,

        [Parameter(Mandatory)]
        [string]$AssetPattern,

        [Parameter(Mandatory)]
        [int]$TimeoutMs,

        [Parameter(Mandatory)]
        [int]$MaxRetries,

        [Parameter(Mandatory)]
        [hashtable]$LogParams
    )

    # Copiados para variáveis locais aqui, no escopo imediato da função: o analisador de lint
    # não rastreia o uso de $FallbackUrl/$TimeoutMs quando a única referência a eles está
    # dentro de um scriptblock aninhado (o '-Action' de Invoke-WithRetry, logo abaixo) —
    # mesmo caso de $TimeoutSec/$DownloadTimeoutSec em Install-PowerShell7.
    $url = $FallbackUrl
    $timeoutMsLocal = $TimeoutMs

    $data = Invoke-WithRetry -MaxRetries $MaxRetries -RetryIntervalSec 2 -OperationName 'consulta ao JSON de fallback' -LogParams $LogParams -Action {
        $client = New-TimeoutWebClient -TimeoutMs $timeoutMsLocal
        try {
            $client.DownloadString($url) | ConvertFrom-Json
        }
        finally {
            $client.Dispose()
        }
    }

    $info = $data.powershell
    if (-not $info -or -not $info.download_url -or -not $info.filename) {
        throw [System.FormatException]::new('JSON de fallback com formato inesperado ou incompleto (campo "powershell" ausente).')
    }

    if ($info.filename -notlike $AssetPattern) {
        throw [System.NotSupportedException]::new("Fallback não possui instalador compatível com o padrão '$AssetPattern' (encontrado: '$($info.filename)').")
    }

    return [pscustomobject]@{
        Url     = $info.download_url
        Sha256  = $info.sha256
        Version = $info.version
    }
}

#endregion

#region Funções públicas (exportadas)

function Install-PowerShell7 {
    <#
    .SYNOPSIS
        Verifica se o PowerShell 7+ está instalado; se não estiver, instala a versão mais recente diretamente do GitHub.
    .DESCRIPTION
        Módulo autônomo projetado para automação. Retorna $true em caso de sucesso; dispara
        exceção em caso de falha.
    .PARAMETER MaxRetries
        Número máximo de tentativas para cada requisição HTTP (consulta à API e download).
    .PARAMETER TimeoutSec
        Timeout, em segundos, para a consulta à API do GitHub.
    .PARAMETER DownloadTimeoutSec
        Timeout, em segundos, para o download do instalador MSI.
    .PARAMETER FallbackSourceUrl
        URL do JSON "fonte da verdade" usado como fallback quando a API do GitHub falha
        após esgotar as tentativas de -MaxRetries (indisponibilidade, rate limit, etc.).
        Quando o fallback é utilizado e o JSON informa um hash SHA256, a integridade do
        MSI baixado é verificada antes da instalação.
    .EXAMPLE
        Install-PowerShell7
    .EXAMPLE
        Install-PowerShell7 -Verbose
    .EXAMPLE
        Install-PowerShell7 -MaxRetries 5 -FallbackSourceUrl 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/config/fallback/Powershell7.json'
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter()]
        [ValidateRange(1, 10)]
        [int]$MaxRetries = 3,

        [Parameter()]
        [ValidateRange(5, 300)]
        [int]$TimeoutSec = 30,

        [Parameter()]
        [ValidateRange(30, 900)]
        [int]$DownloadTimeoutSec = 180,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$FallbackSourceUrl = 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/config/fallback/Powershell7.json'
    )

    # Convertidos para milissegundos aqui, no escopo imediato da função: o analisador de lint
    # não rastreia o uso de $TimeoutSec/$DownloadTimeoutSec quando a única referência a eles
    # está dentro de um scriptblock aninhado (o '-Action' de Invoke-WithRetry, mais abaixo).
    $apiTimeoutMs = $TimeoutSec * 1000
    $downloadTimeoutMs = $DownloadTimeoutSec * 1000

    $logDir = Join-Path -Path $env:TEMP -ChildPath 'WinProvision'
    $logFile = Join-Path -Path $logDir -ChildPath 'pwsh7-install.log'
    $mutexName = 'Global\WinProvision_PowerShell7Install'
    $logParams = @{ LogDir = $logDir; LogFile = $logFile }

    # Habilita TLS 1.2 sem sobrescrever protocolos já habilitados no processo
    [ServicePointManager]::SecurityProtocol = [ServicePointManager]::SecurityProtocol -bor [SecurityProtocolType]::Tls12

    # Elevação de privilégios
    $isAdmin = [WindowsPrincipal]::new([WindowsIdentity]::GetCurrent()).IsInRole([WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Pwsh7InstallLog @logParams -Message 'Privilégios de Administrador são necessários para instalar o PowerShell 7+.' -Level ERRO
        throw [UnauthorizedAccessException]::new('Privilégios de Administrador são necessários para instalar o PowerShell 7+.')
    }

    # Trava de execução única (mutex)
    $mutex = $null
    $mutexOwned = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $mutexName)
        try {
            $mutexOwned = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            $mutexOwned = $true
        }

        if (-not $mutexOwned) {
            Write-Pwsh7InstallLog @logParams -Message 'Encerrado: Outra instância já está em execução (mutex ocupado).' -Level ERRO
            throw [System.InvalidOperationException]::new('Outra instância deste instalador já está em execução nesta máquina.')
        }
    }
    catch [System.InvalidOperationException] {
        throw
    }
    catch {
        Write-Pwsh7InstallLog @logParams -Message "AVISO: Não foi possível obter a trava de execução única: $_" -Level INFO
    }

    try {
        # Resolve o "Program Files" 64-bit real, mesmo se este processo for 32-bit (WOW64)
        $programFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
        $pwshPath = Join-Path -Path $programFiles64 -ChildPath 'PowerShell\7\pwsh.exe'

        # 1. Verificação de idempotência
        if (Test-Pwsh7Installed -KnownPath $pwshPath) {
            Write-Pwsh7InstallLog @logParams -Message 'PowerShell 7+ já presente nesta máquina. Operação concluída.' -Level OK
            $pwshDir = Split-Path -Path $pwshPath -Parent
            if ($env:Path -notlike "*$pwshDir*") {
                $env:Path += ";$pwshDir"
            }
            return $true
        }

        # 2. Detecção de arquitetura real do SO
        $osArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
        $assetPattern = if ($osArch -eq 'ARM64') { '*win-arm64.msi' } else { '*win-x64.msi' }

        # 3. Busca do release via API do GitHub (com retry e timeout); se esgotar as
        #    tentativas, cai para o JSON de fallback ("fonte da verdade") antes de desistir.
        Write-Pwsh7InstallLog @logParams -Message 'Buscando release mais recente do PowerShell no GitHub...' -Level STEP
        $msiUrl = $null
        $expectedSha256 = $null
        $releaseSource = 'GitHub'
        try {
            $json = Invoke-WithRetry -MaxRetries $MaxRetries -RetryIntervalSec 2 -OperationName 'consulta à API do GitHub' -LogParams $logParams -Action {
                $client = New-TimeoutWebClient -TimeoutMs $apiTimeoutMs
                try {
                    $client.DownloadString('https://api.github.com/repos/PowerShell/PowerShell/releases/latest') | ConvertFrom-Json
                }
                finally {
                    $client.Dispose()
                }
            }

            $msiUrl = ($json.assets | Where-Object name -like $assetPattern | Select-Object -First 1).browser_download_url
            if (-not $msiUrl) {
                throw [System.IO.FileNotFoundException]::new("URL do MSI não encontrada para o padrão '$assetPattern' na resposta da API do GitHub.")
            }
        }
        catch {
            Write-Pwsh7InstallLog @logParams -Message "Falha ao obter release via API do GitHub: $($_.Exception.Message). Tentando fonte de fallback ($FallbackSourceUrl)..." -Level ERRO

            try {
                $fallbackInfo = Get-Pwsh7FallbackInfo -FallbackUrl $FallbackSourceUrl -AssetPattern $assetPattern -TimeoutMs $apiTimeoutMs -MaxRetries $MaxRetries -LogParams $logParams
                $msiUrl = $fallbackInfo.Url
                $expectedSha256 = $fallbackInfo.Sha256
                $releaseSource = 'Fallback'
                Write-Pwsh7InstallLog @logParams -Message "Fonte de fallback utilizada com sucesso (versão $($fallbackInfo.Version))." -Level OK
            }
            catch {
                Write-Pwsh7InstallLog @logParams -Message "Falha também na fonte de fallback: $($_.Exception.Message)" -Level ERRO
                throw [WebException]::new("Falha ao obter URL do instalador via API do GitHub e via fallback: $($_.Exception.Message)", $_.Exception)
            }
        }

        # 4. Download do MSI (com retry e timeout)
        $tempMsi = Join-Path -Path $env:TEMP -ChildPath "pwsh7-$([guid]::NewGuid()).msi"
        Write-Pwsh7InstallLog @logParams -Message 'Baixando instalador MSI do PowerShell 7+...' -Level STEP
        try {
            Invoke-WithRetry -MaxRetries $MaxRetries -RetryIntervalSec 2 -OperationName 'download do MSI' -LogParams $logParams -Action {
                $client = New-TimeoutWebClient -TimeoutMs $downloadTimeoutMs
                try {
                    $client.DownloadFile($msiUrl, $tempMsi)
                }
                finally {
                    $client.Dispose()
                }
            }

            $downloadedFile = Get-Item -Path $tempMsi -ErrorAction SilentlyContinue
            if (-not $downloadedFile -or $downloadedFile.Length -eq 0) {
                throw 'Arquivo MSI baixado está ausente ou vazio.'
            }

            # Verificação de integridade: só é feita quando o hash veio da fonte de fallback,
            # já que a API do GitHub não fornece um SHA256 previamente conhecido dos assets.
            if ($expectedSha256) {
                $actualSha256 = (Get-FileHash -Path $tempMsi -Algorithm SHA256).Hash
                if ($actualSha256 -ne $expectedSha256.Trim()) {
                    throw "Hash SHA256 do MSI baixado via fallback não confere (esperado: $expectedSha256; obtido: $actualSha256)."
                }
                Write-Pwsh7InstallLog @logParams -Message 'Integridade do MSI (fallback) verificada via SHA256.' -Level OK
            }
        }
        catch {
            Write-Pwsh7InstallLog @logParams -Message "Falha no download do MSI (fonte: $releaseSource): $($_.Exception.Message)" -Level ERRO
            throw "Falha no download do MSI (fonte: $releaseSource): $($_.Exception.Message)"
        }

        # 5. Instalação silenciosa via msiexec
        try {
            if ($PSCmdlet.ShouldProcess('PowerShell 7+', 'Instalar via msiexec /quiet')) {
                Write-Pwsh7InstallLog @logParams -Message 'Instalando PowerShell 7+ via msiexec /quiet...' -Level STEP
                $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $tempMsi, '/quiet', '/norestart') -Wait -PassThru
                if ($proc.ExitCode -ne 0) {
                    throw "Falha no msiexec (Código: $($proc.ExitCode))"
                }
            }
        }
        catch {
            Write-Pwsh7InstallLog @logParams -Message "Erro na instalação: $($_.Exception.Message)" -Level ERRO
            throw "Erro na instalação: $($_.Exception.Message)"
        }
        finally {
            if (Test-Path -Path $tempMsi) {
                Remove-Item -Path $tempMsi -Force -ErrorAction SilentlyContinue
            }
        }

        # 6. Ajuste de PATH (sessão atual + máquina)
        $pwshDir = Split-Path -Path $pwshPath -Parent
        $sysPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        if ($sysPath -notlike "*$pwshDir*") {
            [Environment]::SetEnvironmentVariable('Path', "$sysPath;$pwshDir", 'Machine')
        }
        if ($env:Path -notlike "*$pwshDir*") {
            $env:Path += ";$pwshDir"
        }

        # 7. Verificação pós-instalação
        if (-not $WhatIfPreference -and -not (Test-Pwsh7Installed -KnownPath $pwshPath)) {
            Write-Pwsh7InstallLog @logParams -Message 'Instalação concluída, mas a verificação pós-instalação falhou.' -Level ERRO
            throw 'Instalação concluída, mas a verificação pós-instalação falhou.'
        }

        Write-Pwsh7InstallLog @logParams -Message 'SUCESSO: PowerShell 7+ instalado com sucesso!' -Level OK
        return $true
    }
    catch {
        Write-Pwsh7InstallLog @logParams -Message "Erro inesperado: $($_.Exception.Message)" -Level ERRO
        throw
    }
    finally {
        if ($mutexOwned -and $mutex) {
            try {
                $mutex.ReleaseMutex()
            }
            catch {
                Write-Pwsh7InstallLog @logParams -Message "AVISO: Falha ao liberar mutex: $_" -Level INFO
            }
        }
        if ($mutex) { $mutex.Dispose() }
    }
}

#endregion

Export-ModuleMember -Function Install-PowerShell7
