#Requires -Version 7.0

using namespace System.IO

Set-StrictMode -Version Latest
# Funções de módulo NÃO herdam $ErrorActionPreference do script/orquestrador
# que as importa — precisa ser declarado aqui também.
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Módulo para provisionamento e atualização idempotente de aplicações via winget.
#>

# Códigos de retorno do winget tratados como sucesso (não são falhas reais)
New-Variable -Name WINGET_ERROR_UPDATE_NOT_APPLICABLE -Option ReadOnly -Scope Script -Value -1978335189   # 0x8A15002B - já na última versão
New-Variable -Name WINGET_ERROR_PACKAGE_ALREADY_INSTALLED -Option ReadOnly -Scope Script -Value -1978335135 # 0x8A150061 - install pego em corrida

#region Funções privadas (internas)

function Write-WinProvisionLog {
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
        [string]$LogFile,

        [ValidateSet('STEP', 'OK', 'ERRO', 'INFO')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logLine = "[$timestamp] [$Level] $Message"

    $logDir = [Path]::GetDirectoryName($LogFile)
    if (-not (Test-Path -Path $logDir)) {
        $null = New-Item -ItemType Directory -Path $logDir -Force
    }

    Add-Content -Path $LogFile -Value $logLine -ErrorAction SilentlyContinue

    switch ($Level) {
        'STEP' { Write-Host "`n[STEP] $Message" -ForegroundColor Cyan }
        'OK' { Write-Host "[OK] $Message" -ForegroundColor Green }
        'ERRO' { Write-Host "[ERRO] $Message" -ForegroundColor Red }
        'INFO' { Write-Verbose $Message }
    }
}

function Test-WingetAvailable {
    <#
    .SYNOPSIS
        Verifica se o executável winget está disponível no PATH da sessão atual.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return [bool](Get-Command -Name winget -CommandType Application -ErrorAction SilentlyContinue)
}

function Test-AppInstalled {
    <#
    .SYNOPSIS
        Verifica, via winget list, se um pacote já está instalado.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Id
    )

    $null = winget list --id $Id --exact --source winget --accept-source-agreements --disable-interactivity 2>&1
    return $LASTEXITCODE -eq 0
}

function Install-App {
    <#
    .SYNOPSIS
        Instala um pacote via winget install, de forma silenciosa e não interativa.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogFile
    )

    if (-not $PSCmdlet.ShouldProcess($Id, 'winget install')) {
        return [pscustomobject]@{ Success = $true; Code = 0 }
    }

    $output = winget install --id $Id --exact --silent --source winget `
        --accept-package-agreements --accept-source-agreements `
        --disable-interactivity 2>&1

    $code = $LASTEXITCODE
    Write-WinProvisionLog -Message "install $Id -> exit $code`n$output" -LogFile $LogFile -Level INFO

    $isSuccess = $code -in @(0, $script:WINGET_ERROR_PACKAGE_ALREADY_INSTALLED)
    return [pscustomobject]@{ Success = $isSuccess; Code = $code }
}

function Update-App {
    <#
    .SYNOPSIS
        Atualiza um pacote via winget upgrade, de forma silenciosa e não interativa.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogFile
    )

    if (-not $PSCmdlet.ShouldProcess($Id, 'winget upgrade')) {
        return [pscustomobject]@{ Success = $true; Code = 0 }
    }

    $output = winget upgrade --id $Id --exact --silent --source winget `
        --accept-package-agreements --accept-source-agreements `
        --disable-interactivity 2>&1

    $code = $LASTEXITCODE
    Write-WinProvisionLog -Message "upgrade $Id -> exit $code`n$output" -LogFile $LogFile -Level INFO

    $isSuccess = $code -in @(0, $script:WINGET_ERROR_UPDATE_NOT_APPLICABLE)
    return [pscustomobject]@{ Success = $isSuccess; Code = $code }
}

#endregion

#region Funções públicas (exportadas)

function Install-Programas {
    <#
    .SYNOPSIS
        Baixa uma configuração de programas via JSON e garante sua instalação e atualização.
    .DESCRIPTION
        Lê a lista de pacotes de um arquivo de configuração remoto (JSON) e processa cada
        aplicativo com winget de forma idempotente: instala o que estiver ausente e atualiza
        o que já estiver instalado.
    .PARAMETER JsonUrl
        URL do arquivo JSON contendo a definição dos pacotes.
    .PARAMETER TempDir
        Diretório onde o arquivo de configuração baixado é gravado (cache temporário).
    .PARAMETER LogArchivePath
        Pasta onde o log desta execução é salvo quando o módulo roda de forma
        isolada. Mesmo padrão usado pelo WinProvisionLog (Complete-ProvisionLog),
        para manter os logs do projeto no mesmo lugar.
    .PARAMETER MaxRetries
        Número máximo de tentativas por pacote antes de marcar como falha.
    .PARAMETER RetryDelaySeconds
        Tempo de espera, em segundos, entre tentativas de um mesmo pacote.
    .EXAMPLE
        Install-Programas -Verbose
    .EXAMPLE
        Install-Programas -JsonUrl 'https://exemplo.com/programas.json'
    .OUTPUTS
        System.Management.Automation.PSCustomObject com as propriedades:
        Success (bool), TotalCount (int), FailedCount (int), LogFile (string),
        Results (lista com o detalhe de cada pacote processado).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$JsonUrl = 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/config/apps/programas.json',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$TempDir = [Path]::Combine($env:TEMP, 'WinProvision'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogArchivePath = 'C:\ProgramData\WinProvision\Logs',

        [Parameter()]
        [ValidateRange(1, 10)]
        [int]$MaxRetries = 3,

        [Parameter()]
        [ValidateRange(0, 300)]
        [int]$RetryDelaySeconds = 5
    )

    $jsonFile = [Path]::Combine($TempDir, 'Programas.json')
    $logFile = [Path]::Combine($LogArchivePath, "Instalar-Programas_$((Get-Date).ToString('yyyyMMdd-HHmmss')).log")

    if (-not (Test-Path -Path $TempDir)) {
        $null = New-Item -ItemType Directory -Path $TempDir -Force
    }
    if (-not (Test-Path -Path $LogArchivePath)) {
        $null = New-Item -ItemType Directory -Path $LogArchivePath -Force
    }

    # 0. Pré-requisito: winget precisa estar disponível
    if (-not (Test-WingetAvailable)) {
        Write-WinProvisionLog -Message 'winget não encontrado no PATH. Verifique se o módulo Install-Winget foi executado antes deste.' -LogFile $logFile -Level ERRO
        throw [System.InvalidOperationException]::new('winget não está disponível no PATH desta sessão.')
    }

    # 1. Download do JSON
    Write-WinProvisionLog -Message 'Baixando arquivo de configuração...' -LogFile $logFile -Level STEP

    try {
        Invoke-WebRequest -Uri $JsonUrl -OutFile $jsonFile -ProgressAction SilentlyContinue -ErrorAction Stop
        Write-WinProvisionLog -Message "Arquivo salvo em: $jsonFile" -LogFile $logFile -Level OK
    }
    catch {
        Write-WinProvisionLog -Message "Falha no download: $_" -LogFile $logFile -Level ERRO
        throw [System.Net.WebException]::new("Falha ao baixar o arquivo JSON de configuração: $_", $_.Exception)
    }

    # 2. Parse do JSON
    try {
        $jsonContent = Get-Content -Path $jsonFile -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-WinProvisionLog -Message "Falha ao interpretar o JSON de configuração: $_" -LogFile $logFile -Level ERRO
        throw [System.FormatException]::new("O JSON baixado é inválido ou está corrompido: $_", $_.Exception)
    }

    $packages = $jsonContent.Sources.Packages

    if (-not $packages -or $packages.Count -eq 0) {
        Write-WinProvisionLog -Message 'Nenhum pacote encontrado em Sources.Packages no JSON.' -LogFile $logFile -Level ERRO
        throw [System.InvalidOperationException]::new('Nenhum pacote foi definido no arquivo JSON.')
    }

    Write-WinProvisionLog -Message "Pacotes a verificar ($($packages.Count)):" -LogFile $logFile -Level STEP
    foreach ($pkg in $packages) {
        Write-Host "  - $($pkg.Id)" -ForegroundColor Gray
    }

    # 2.1 Aquecimento: ativa o WindowsPackageManagerServer.exe (backend COM do
    # winget) agora, logo antes do loop. A primeira chamada de qualquer sessão
    # sobe esse processo do zero, o que é o real motivo do primeiro pacote
    # demorar mais que os outros; chamadas seguintes reaproveitam o processo
    # já ativo. Fazer isso antes do download do JSON não ajuda: o servidor
    # fica ocioso só por alguns segundos e cai antes do loop começar.
    Write-WinProvisionLog -Message 'Aquecendo backend do winget...' -LogFile $logFile -Level STEP
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = winget source update 2>&1
    $sw.Stop()
    Write-WinProvisionLog -Message "Backend aquecido em $($sw.Elapsed.TotalSeconds.ToString('0.0'))s." -LogFile $logFile -Level OK

    # 3. Loop principal
    Write-WinProvisionLog -Message 'Verificando e instalando/atualizando pacotes...' -LogFile $logFile -Level STEP

    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($pkg in $packages) {
        $id = $pkg.Id
        Write-Host "`n-> $id" -ForegroundColor White

        $installed = Test-AppInstalled -Id $id
        $action = $installed ? 'Atualização' : 'Instalação'

        if (-not $installed) {
            Write-Host '    Não instalado. Instalando...' -ForegroundColor Yellow
        }
        else {
            Write-Host '    Já instalado. Verificando atualização...' -ForegroundColor Yellow
        }

        $attempt = 0
        do {
            $attempt++
            $result = $installed ? (Update-App -Id $id -LogFile $logFile) : (Install-App -Id $id -LogFile $logFile)

            if (-not $result.Success -and $attempt -lt $MaxRetries) {
                Write-WinProvisionLog -Message "$id ($action) falhou na tentativa $attempt/$MaxRetries. Código: $($result.Code). Tentando novamente em $($RetryDelaySeconds)s..." -LogFile $logFile -Level ERRO
                Write-Host "    Falha na tentativa $attempt/$MaxRetries. Nova tentativa em $($RetryDelaySeconds)s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        } while (-not $result.Success -and $attempt -lt $MaxRetries)

        $status = $result.Success ? 'OK' : 'FALHA'
        $level = $result.Success ? 'OK' : 'ERRO'
        Write-WinProvisionLog -Message "$id ($action) $status. Código: $($result.Code). Tentativas: $attempt/$MaxRetries" -LogFile $logFile -Level $level

        $results.Add([pscustomobject]@{ Id = $id; Status = $status; Action = $action; Code = $result.Code; Attempts = $attempt })
    }

    # 4. Relatório final
    Write-WinProvisionLog -Message 'RELATÓRIO FINAL' -LogFile $logFile -Level STEP
    Write-Host ('=' * 50) -ForegroundColor Cyan

    $failed = @($results | Where-Object Status -eq 'FALHA')

    if (-not $failed) {
        Write-Host 'TODOS OS PACOTES FORAM PROCESSADOS COM SUCESSO!' -ForegroundColor Green
        Write-Host ('=' * 50) -ForegroundColor Cyan
        Write-Host "Log completo: $logFile" -ForegroundColor Gray
    }
    else {
        Write-Host 'PACOTES COM FALHA:' -ForegroundColor Red
        foreach ($f in $failed) {
            Write-Host "  x $($f.Id) - $($f.Action) - código $($f.Code)" -ForegroundColor Red
        }
        Write-Host "`nLog completo: $logFile" -ForegroundColor Yellow
        Write-Host ('=' * 50) -ForegroundColor Cyan
    }

    # Retorna UM ÚNICO pscustomobject com a propriedade 'Success', que é o
    # contrato exigido pelo Orquestrador (Invoke-ModuleFunction). O detalhe
    # por pacote continua disponível em .Results para diagnóstico/log.
    return [pscustomobject]@{
        Success     = ($failed.Count -eq 0)
        TotalCount  = $results.Count
        FailedCount = $failed.Count
        LogFile     = $logFile
        Results     = $results
    }
}

#endregion

Export-ModuleMember -Function Install-Programas
