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
      3. Registra (ou atualiza) uma Scheduled Task que invoca o Orquestrador (PowerShell 7+)
         via 'pwsh.exe' — nunca 'powershell.exe', já que o Orquestrador usa sintaxe
         exclusiva do PS7+ que falha silenciosamente em Windows PowerShell 5.1 — e dispara
         essa task imediatamente para a sessão atual.

    Por que Scheduled Task em vez de invocar o pwsh diretamente com -Wait:
      Quando disparado via FirstLogonCommands/UserOnce, o Bootstrap frequentemente roda
      como SYSTEM, em Sessão 0 — isolada da sessão interativa do usuário. Um processo
      lançado diretamente ali nunca conseguiria desenhar UI na tela do usuário, e
      esperar (-Wait) o Orquestrador inteiro terminar travaria o primeiro logon (a área
      de trabalho só apareceria depois de todos os módulos rodarem). Registrar uma
      Scheduled Task com LogonType Interactive, disparando-a manualmente na sessão do
      usuário que acabou de logar, resolve os dois problemas: o Bootstrap encerra rápido
      (a área de trabalho aparece normalmente) e o Orquestrador roda na sessão certa,
      onde uma UI (ex.: WPF) poderá aparecer.

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
.PARAMETER TaskName
    Nome da Scheduled Task que dispara o Orquestrador. Fica registrada permanentemente
    no sistema (não se auto-remove), para permitir reexecução/depuração posterior.
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

    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'WinProvision_Orchestrator',

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

$tempRoot = $env:TEMP
if (-not $tempRoot) { $tempRoot = 'C:\Windows\Temp' }
$script:WorkDir   = Join-Path -Path $tempRoot -ChildPath 'WinProvision\Bootstrap'
$script:MutexName = 'Global\WinProvision_Bootstrap'
$script:TaskName  = $TaskName

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

function Get-InteractiveUserName {
    <#
    .SYNOPSIS
        Determina o usuário da sessão interativa de console, para agendar o Orquestrador
        na sessão certa (permitindo UI visível) em vez de rodá-lo isolado em Sessão 0.
    .DESCRIPTION
        Se o Bootstrap já está rodando no contexto do próprio usuário (não SYSTEM), essa é
        a resposta direta. Se está rodando como SYSTEM (caso comum via FirstLogonCommands),
        consulta o Win32_ComputerSystem via CIM para descobrir quem é o usuário logado na
        sessão de console; 'query user' é usado apenas como fallback, pois nem sempre está
        disponível/confiável em builds mínimas.
    .OUTPUTS
        System.String. Nome do usuário no formato DOMÍNIO\Usuário, ou $null se não encontrado.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()

    if ($identity.User.Value -ne 'S-1-5-18') {
        return $identity.Name
    }

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.UserName) { return $cs.UserName }
    }
    catch { }

    try {
        $quserOutput = & query user 2>$null
        if ($LASTEXITCODE -eq 0 -and $quserOutput) {
            $activeLine = $quserOutput | Select-Object -Skip 1 | Where-Object { $_ -match '\sActive\s' } | Select-Object -First 1
            if ($activeLine) {
                $userName = ($activeLine.Trim() -split '\s+')[0].TrimStart('>')
                if ($userName) { return "$env:COMPUTERNAME\$userName" }
            }
        }
    }
    catch { }

    return $null
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

function Set-OrchestratorScheduledTask {
    <#
    .SYNOPSIS
        Registra (ou atualiza) a Scheduled Task que roda o Orquestrador e a dispara
        imediatamente para a sessão atual.
    .DESCRIPTION
        A task fica registrada permanentemente (não se auto-remove), disparando em cada
        logon do usuário informado — útil para reexecução/depuração manual depois. Como o
        evento de logon que ativaria a trigger 'AtLogOn' já aconteceu antes da task existir,
        ela é iniciada manualmente aqui via Start-ScheduledTask para não perder a execução
        desta sessão. LogonType Interactive + a sessão do usuário já estar ativa é o que
        permite ao Task Scheduler lançar o processo nela (com UI visível), sem exigir senha
        armazenada.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PwshPath,
        [Parameter(Mandatory)]
        [string]$OrchestratorUrl,
        [Parameter(Mandatory)]
        [int]$TimeoutSec,
        [Parameter(Mandatory)]
        [int]$MaxRetries,
        [Parameter(Mandatory)]
        [string]$UserName
    )

    # Sintaxe do PS7+ (?? , -MaximumRetryCount) — executada dentro do pwsh, não desta sessão 5.1.
    $taskCmd = "`$ProgressPreference='SilentlyContinue'; Invoke-Expression (Invoke-RestMethod -Uri '$OrchestratorUrl' -TimeoutSec $TimeoutSec -MaximumRetryCount $MaxRetries -RetryIntervalSec 2)"
    $argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$taskCmd`""

    $action    = New-ScheduledTaskAction -Execute $PwshPath -Argument $argList
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $UserName
    $principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)

    $existing = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Step -Message "Task agendada '$script:TaskName' já existe — atualizando definição (fica registrada; útil para reexecução/depuração)." -Color Gray
        $null = Set-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -ErrorAction Stop
    }
    else {
        Write-Step -Message "Registrando task agendada '$script:TaskName' (fica registrada permanentemente; dispara em cada logon deste usuário)." -Color Gray
        $null = Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop
    }

    Write-Step -Message "Disparando a task agendada agora, para esta sessão (usuário=$UserName)." -Color Cyan
    Start-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
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

        # 4. Delega ao Orquestrador via Scheduled Task (nunca powershell.exe, nunca
        #    bloqueando o logon) — roda na sessão interativa do usuário, permitindo
        #    UI visível, e libera a área de trabalho imediatamente.
        $pwshExe = Resolve-PwshPath
        if (-not $pwshExe) {
            throw 'PowerShell 7+ foi instalado, mas o executável pwsh.exe não pôde ser localizado.'
        }

        $interactiveUser = Get-InteractiveUserName
        if (-not $interactiveUser) {
            throw 'Não foi possível determinar o usuário da sessão interativa para agendar o Orquestrador.'
        }

        Write-Step -Message "Delegando execução para o Orquestrador via task agendada. pwsh=$pwshExe usuário=$interactiveUser" -Color Cyan
        Set-OrchestratorScheduledTask -PwshPath $pwshExe -OrchestratorUrl $OrchestratorUrl -TimeoutSec $TimeoutSec -MaxRetries $MaxRetries -UserName $interactiveUser

        Write-Step -Message '[OK] Orquestrador agendado e disparado. Bootstrap encerra sem bloquear o logon.' -Color Green
        Write-Step -Message '============================================' -Color White

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
