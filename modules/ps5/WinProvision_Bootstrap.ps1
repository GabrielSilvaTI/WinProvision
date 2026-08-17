#Requires -Version 5.1

<#
.SYNOPSIS
    Bootstrap do provisionamento Zero-Touch (ponto de entrada em Windows PowerShell 5.1).
.DESCRIPTION
    Ponto de entrada do sistema de provisionamento, compatível com Windows PowerShell 5.1
    (presente nativamente no Windows, antes de qualquer provisionamento acontecer).

    Fluxo:
      1. Garante elevação (Administrador) — relança a si mesmo via UAC se necessário,
         funcionando tanto executado como arquivo local quanto via 'iwr | iex'.
      2. Baixa e importa o módulo Install-PowerShell7 (compatível com PS 5.1) e garante
         que o PowerShell 7+ esteja instalado na máquina.
      3. Delega a execução para o Orquestrador (PowerShell 7+) invocando 'pwsh.exe'
         diretamente — nunca 'powershell.exe', já que o Orquestrador usa sintaxe
         exclusiva do PS7+ que falha silenciosamente em Windows PowerShell 5.1 — e sem
         '-Wait', para não travar o FirstLogonCommands/UserOnce enquanto o Orquestrador
         roda (a área de trabalho aparece normalmente; o Orquestrador segue rodando em
         segundo plano na mesma sessão interativa, com sua própria UI visível).

    Não depende de sintaxes exclusivas do PowerShell 7+ (operador ternário, operador de
    coalescência nula, ForEach-Object -Parallel, -MaximumRetryCount em Invoke-WebRequest, etc.),
    já que pode ser a primeira coisa a rodar numa máquina limpa.
.PARAMETER ModuleBaseUrl
    URL base (raw.githubusercontent.com) onde Install-PowerShell7.psd1/.psm1 estão hospedados.
.PARAMETER BootstrapUrl
    URL raw deste próprio script. Usada apenas para o caso de auto-elevação quando o script
    está rodando via 'iwr | iex' (sem arquivo local em disco para relançar). Por padrão,
    derivada de -ModuleBaseUrl (mesma pasta).
.PARAMETER OrchestratorUrl
    URL raw do script Orquestrador (PowerShell 7+) a ser executado após garantir o pwsh.
.PARAMETER MaxRetries
    Número máximo de tentativas para cada requisição HTTP.
.PARAMETER TimeoutSec
    Timeout, em segundos, para cada requisição HTTP.
.PARAMETER LogPath
    Caminho do arquivo de log (transcript) da execução.
.NOTES
    Versão: 2.0.0 (PowerShell 5.1 / Ponto de Entrada Zero-Touch — delegação via Scheduled Task)
#>

[CmdletBinding()]
param(
    [ValidatePattern('^https://')]
    [string]$ModuleBaseUrl = 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/m%C3%B3dulos/5.1',

    [ValidatePattern('^https://')]
    [string]$BootstrapUrl = "$ModuleBaseUrl/Bootstrap.ps1",

    [ValidatePattern('^https://')]
    [string]$OrchestratorUrl = 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/orquestrador/orquestrador.ps1',

    [ValidateRange(1, 10)]
    [int]$MaxRetries = 3,

    [ValidateRange(5, 300)]
    [int]$TimeoutSec = 30,

    [string]$LogPath = $(if ($env:TEMP) { Join-Path -Path $env:TEMP -ChildPath 'WinProvision\bootstrap.log' } else { 'C:\Windows\Temp\WinProvision\bootstrap.log' })
)

# --- Configurações de Automação Total (Zero Interatividade) ---
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$ConfirmPreference     = 'None'

# Evita "mojibake" em mensagens acentuadas em sessões desatendidas
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Força TLS 1.2 para chamadas .NET (Invoke-WebRequest/Invoke-RestMethod usam o
# ServicePointManager por baixo). Necessário porque, numa máquina recém-sysprepada
# (antes de qualquer Windows Update), o .NET Framework pode resolver
# 'SystemDefault' para TLS 1.0 — que o raw.githubusercontent.com rejeita, causando
# falha silenciosa de handshake em execuções não interativas (UserOnce/RunOnce).
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
    Write-Warning "Não foi possível forçar TLS 1.2 via ServicePointManager: $($_.Exception.Message)"
}

$tempRoot = $env:TEMP
if (-not $tempRoot) { $tempRoot = 'C:\Windows\Temp' }
$script:WorkDir   = Join-Path -Path $tempRoot -ChildPath 'WinProvision\Bootstrap'
$script:MutexName = 'Global\WinProvision_Bootstrap'

# --- Funções Auxiliares ---

function Write-Step {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('White', 'Gray', 'Cyan', 'Green', 'Red', 'Yellow')]
        [string]$Color = 'White'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

function Test-IsElevated {
    <#
    .SYNOPSIS
        Verifica se o processo atual já possui privilégios suficientes para instalar software.
    .DESCRIPTION
        Além do teste padrão de IsInRole(Administrator), trata a conta SYSTEM (S-1-5-18) como
        já elevada: ela não pertence ao grupo BUILTIN\Administrators (então IsInRole retornaria
        $false), mas possui privilégios equivalentes ou superiores. Isso é essencial quando o
        Bootstrap é disparado por mecanismos como FirstLogonCommands (unattend.xml) ou o legado
        [GuiRunOnce]/"UserOnce" do sysprep.inf, que frequentemente executam como SYSTEM — contexto
        onde um prompt de UAC nunca teria alguém para responder, travando o provisionamento.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()

    if ($identity.User.Value -eq 'S-1-5-18') {
        return $true
    }

    $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identity
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevate {
    <#
    .SYNOPSIS
        Relança o próprio Bootstrap com elevação (UAC), funcionando tanto executado como
        arquivo local ($PSCommandPath preenchido) quanto via 'iwr | iex' (sem arquivo local).
    .OUTPUTS
        System.Int32. Código de saída do processo elevado.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    $psExe = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'

    if ($PSCommandPath) {
        Write-Step -Message "Executando como arquivo local. Relançando '$PSCommandPath' com elevação (UAC)..." -Color Yellow
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    }
    else {
        Write-Step -Message "Executando via pipe (sem arquivo local). Relançando via download remoto ($BootstrapUrl) com elevação (UAC)..." -Color Yellow
        $remoteCmd = "`$ProgressPreference='SilentlyContinue'; Invoke-Expression (Invoke-WebRequest -Uri '$BootstrapUrl' -UseBasicParsing -TimeoutSec $TimeoutSec).Content"
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $remoteCmd)
    }

    try {
        $proc = Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs -Wait -PassThru -ErrorAction Stop
        return $proc.ExitCode
    }
    catch {
        # Motivo comum: usuário cancelou o prompt do UAC.
        throw "Falha ao relançar o Bootstrap com elevação (UAC cancelado ou bloqueado?): $($_.Exception.Message)"
    }
}

function Initialize-WorkDirectory {
    [CmdletBinding()]
    param()
    if (Test-Path -LiteralPath $script:WorkDir) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
    $null = New-Item -Path $script:WorkDir -ItemType Directory -Force
    Write-Step -Message "Diretório de trabalho inicializado em: $script:WorkDir" -Color Gray
}

function Remove-WorkDirectory {
    [CmdletBinding()]
    param()
    if (Test-Path -LiteralPath $script:WorkDir) {
        try {
            Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -Confirm:$false -ErrorAction Stop
            Write-Step -Message 'Limpeza: Arquivos temporários removidos.' -Color Gray
        }
        catch {
            Write-Step -Message "Aviso: Não foi possível limpar a pasta temporária: $($_.Exception.Message)" -Color Yellow
        }
    }
}

function Save-BootstrapModuleFiles {
    <#
    .SYNOPSIS
        Baixa Install-PowerShell7.psd1/.psm1, com retry manual (Invoke-WebRequest no PS 5.1
        não possui -MaximumRetryCount nativo, diferente do PS7+).
    .OUTPUTS
        System.String. Caminho da pasta onde os arquivos do módulo foram salvos.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $moduleDir = Join-Path -Path $script:WorkDir -ChildPath 'Install-PowerShell7'
    $null = New-Item -Path $moduleDir -ItemType Directory -Force

    foreach ($ext in @('psd1', 'psm1')) {
        $url  = "$ModuleBaseUrl/Install-PowerShell7.$ext"
        $dest = Join-Path -Path $moduleDir -ChildPath "Install-PowerShell7.$ext"

        Write-Step -Message "Baixando: Install-PowerShell7.$ext ..." -Color Gray

        $attempt = 0
        while ($true) {
            $attempt++
            try {
                Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
                break
            }
            catch {
                if ($attempt -ge $MaxRetries) {
                    throw "Falha ao baixar Install-PowerShell7.$ext após $MaxRetries tentativa(s): $($_.Exception.Message)"
                }
                Write-Step -Message "Tentativa $attempt/$MaxRetries falhou ao baixar '$ext': $($_.Exception.Message). Nova tentativa em 2s..." -Color Yellow
                Start-Sleep -Seconds 2
            }
        }
    }
    return $moduleDir
}

function Resolve-PwshPath {
    <#
    .SYNOPSIS
        Localiza o executável do pwsh 7+ recém-instalado (ou já presente).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Install-PowerShell7 já atualiza $env:Path do processo atual ao instalar,
    # então Get-Command normalmente resolve sem precisar de nova sessão.
    $cmd = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $programFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $knownPath = Join-Path -Path $programFiles64 -ChildPath 'PowerShell\7\pwsh.exe'
    if (Test-Path -Path $knownPath) { return $knownPath }

    return $null
}

# --- Execução Principal ---

function Start-Bootstrap {
    [CmdletBinding()]
    param()

    $transcriptStarted = $false
    try {
        $logDir = Split-Path -Path $LogPath -Parent
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            $null = New-Item -Path $logDir -ItemType Directory -Force
        }
        Start-Transcript -Path $LogPath -Append -ErrorAction Stop | Out-Null
        $transcriptStarted = $true
    }
    catch {
        Write-Step -Message "Aviso: não foi possível iniciar o log em '$LogPath': $($_.Exception.Message)" -Color Yellow
    }

    Write-Step -Message '============================================' -Color White
    Write-Step -Message '   BOOTSTRAP DE PROVISIONAMENTO (ZERO-TOUCH)' -Color White
    Write-Step -Message '============================================' -Color White

    $exitCode = 0
    $mutex = $null
    $mutexOwned = $false

    try {
        # 1. Garante elevação. Não segura mutex aqui: o processo pai (não elevado)
        #    apenas relança e aguarda o filho elevado — evita deadlock no mutex.
        if (-not (Test-IsElevated)) {
            Write-Step -Message 'Privilégios administrativos ausentes.' -Color Yellow
            if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { }; $transcriptStarted = $false }

            $childExitCode = Invoke-SelfElevate
            exit $childExitCode
        }

        Write-Step -Message "Executando com privilégios suficientes. Identidade=$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) PSVersion=$($PSVersionTable.PSVersion)" -Color Gray

        # 2. Trava de execução única (mutex) — só a partir daqui, já elevado.
        try {
            $mutex = New-Object -TypeName System.Threading.Mutex -ArgumentList $false, $script:MutexName
            try {
                $mutexOwned = $mutex.WaitOne(0)
            }
            catch [System.Threading.AbandonedMutexException] {
                $mutexOwned = $true
            }

            if (-not $mutexOwned) {
                Write-Step -Message 'Encerrado: Outra instância do Bootstrap já está em execução (mutex ocupado).' -Color Red
                throw [System.InvalidOperationException]::new('Outra instância do Bootstrap já está em execução nesta máquina.')
            }
        }
        catch [System.InvalidOperationException] {
            throw
        }
        catch {
            Write-Step -Message "AVISO: Não foi possível obter a trava de execução única: $($_.Exception.Message)" -Color Yellow
        }

        # 3. Garante o PowerShell 7+ instalado
        Initialize-WorkDirectory
        $moduleDir = Save-BootstrapModuleFiles
        $psd1 = Join-Path -Path $moduleDir -ChildPath 'Install-PowerShell7.psd1'

        try {
            $null = Test-ModuleManifest -Path $psd1 -ErrorAction Stop
        }
        catch {
            throw "Manifesto de módulo inválido para Install-PowerShell7: $($_.Exception.Message)"
        }

        Write-Step -Message 'Importando módulo Install-PowerShell7...' -Color Gray
        Import-Module -Name $psd1 -Force -DisableNameChecking -ErrorAction Stop

        Write-Step -Message 'Garantindo PowerShell 7+ instalado...' -Color Cyan
        $result = Install-PowerShell7 -MaxRetries $MaxRetries -TimeoutSec $TimeoutSec

        # Mesmo contrato de retorno usado pelo Orquestrador ao avaliar módulos:
        # $null (sucesso implícito), [bool], ou objeto/hashtable com propriedade 'Success'.
        $isSuccess = $false
        switch ($true) {
            { $null -eq $result } { $isSuccess = $true; break }
            { $result -is [bool] } { $isSuccess = $result; break }
            { $result -is [hashtable] -and $result.ContainsKey('Success') } { $isSuccess = [bool]$result['Success']; break }
            { $result -is [pscustomobject] -and $result.PSObject.Properties['Success'] } { $isSuccess = [bool]$result.Success; break }
        }

        if (-not $isSuccess) {
            throw 'O módulo Install-PowerShell7 retornou status de falha.'
        }

        Write-Step -Message '[OK] PowerShell 7+ garantido nesta máquina.' -Color Green

        # 4. Delega ao Orquestrador via pwsh (nunca powershell.exe). Sem '-Wait': o
        #    FirstLogonCommands/UserOnce roda na Sessão 1 (interativa) neste ambiente,
        #    então não há isolamento de sessão a contornar — só o bloqueio síncrono,
        #    que impediria a área de trabalho de aparecer até o Orquestrador terminar.
        $pwshExe = Resolve-PwshPath
        if (-not $pwshExe) {
            throw 'PowerShell 7+ foi instalado, mas o executável pwsh.exe não pôde ser localizado.'
        }

        Write-Step -Message "Delegando execução para o Orquestrador via pwsh (sem aguardar): $pwshExe" -Color Cyan
        Write-Step -Message '============================================' -Color White

        if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { }; $transcriptStarted = $false }

        # A partir daqui, sintaxe é do PS7+ (executada dentro do pwsh, não desta sessão 5.1).
        $orchestratorCmd = "`$ProgressPreference='SilentlyContinue'; Invoke-Expression (Invoke-RestMethod -Uri '$OrchestratorUrl' -TimeoutSec $TimeoutSec -MaximumRetryCount $MaxRetries -RetryIntervalSec 2)"
        $null = Start-Process -FilePath $pwshExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $orchestratorCmd) -PassThru -ErrorAction Stop

        $exitCode = 0
    }
    catch {
        Write-Step -Message "[FALHA CRÍTICA] $($_.Exception.Message)" -Color Red
        $exitCode = 1
    }
    finally {
        Remove-WorkDirectory
        if ($mutexOwned -and $mutex) {
            try { $mutex.ReleaseMutex() } catch { }
        }
        if ($mutex) { $mutex.Dispose() }
        if ($transcriptStarted) {
            try { Stop-Transcript | Out-Null } catch { }
        }
    }

    exit $exitCode
}

# Inicia a execução imediatamente.
Start-Bootstrap
