#Requires -Version 7.0

using namespace System.IO

Set-StrictMode -Version Latest

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
        Diretório onde o arquivo baixado e os logs serão gravados.
    .EXAMPLE
        Install-Programas -Verbose
    .EXAMPLE
        Install-Programas -JsonUrl 'https://exemplo.com/programas.json'
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$JsonUrl = 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/configura%C3%A7%C3%B5es/programas.json',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$TempDir = [Path]::Combine($env:TEMP, 'WinProvision')
    )

    $jsonFile = [Path]::Combine($TempDir, 'Programas.json')
    $logFile = [Path]::Combine($TempDir, 'winget-idempotente.log')

    if (-not (Test-Path -Path $TempDir)) {
        $null = New-Item -ItemType Directory -Path $TempDir -Force
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

    # 3. Loop principal
    Write-WinProvisionLog -Message 'Verificando e instalando/atualizando pacotes...' -LogFile $logFile -Level STEP

    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($pkg in $packages) {
        $id = $pkg.Id
        Write-Host "`n-> $id" -ForegroundColor White

        $installed = Test-AppInstalled -Id $id

        if (-not $installed) {
            Write-Host '    Não instalado. Instalando...' -ForegroundColor Yellow
            $result = Install-App -Id $id -LogFile $logFile
            $action = 'Instalação'
        }
        else {
            Write-Host '    Já instalado. Verificando atualização...' -ForegroundColor Yellow
            $result = Update-App -Id $id -LogFile $logFile
            $action = 'Atualização'
        }

        $status = $result.Success ? 'OK' : 'FALHA'
        $level = $result.Success ? 'OK' : 'ERRO'
        Write-WinProvisionLog -Message "$id ($action) $status. Código: $($result.Code)" -LogFile $logFile -Level $level

        $results.Add([pscustomobject]@{ Id = $id; Status = $status; Action = $action; Code = $result.Code })
    }

    # 4. Relatório final
    Write-WinProvisionLog -Message 'RELATÓRIO FINAL' -LogFile $logFile -Level STEP
    Write-Host ('=' * 50) -ForegroundColor Cyan

    $failed = $results | Where-Object Status -eq 'FALHA'

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

    # Retorna o objeto de resultados estruturado para o pipeline do PowerShell
    return $results
}

#endregion

Export-ModuleMember -Function Install-Programas
