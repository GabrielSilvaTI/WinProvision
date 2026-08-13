#Requires -Version 7.0

<#
.SYNOPSIS
    Baixa um JSON de configuração do GitHub e garante que os apps listados
    estejam instalados e atualizados via winget, de forma idempotente.
.DESCRIPTION
    Para cada pacote: verifica se está instalado (winget list --exact).
    Se não estiver, instala. Se estiver, tenta upgrade (winget decide
    internamente se há versão nova, sem parsing manual de versão).
.DEPENDENCIES
    winget instalado e acesso à internet.
.LINK
    https://github.com/GabrielSilvaTI/WinProvision
#>

using namespace System.IO

# ========== CONFIGURAÇÕES ==========

$jsonUrl      = 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/core/WinProvision_Programas.json'
$tempDir      = [Path]::Combine($env:TEMP, 'WinProvision')
$jsonFile     = [Path]::Combine($tempDir, 'Programas.json')
$logFile      = [Path]::Combine($tempDir, 'winget-idempotente.log')

# Códigos de retorno do winget relevantes para este fluxo
# Fonte: https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md
$WINGET_ERROR_UPDATE_NOT_APPLICABLE     = -1978335189  # 0x8A15002B - já na última versão
$WINGET_ERROR_PACKAGE_ALREADY_INSTALLED = -1978335135  # 0x8A150061 - install pego em corrida

# ========== CÓDIGOS DE SAÍDA DESTE SCRIPT ==========
# 0 = OK - todos os pacotes já estavam instalados/atualizados ou foram processados com sucesso
# 1 = Falha ao baixar o arquivo de configuração JSON (Programas.json) do GitHub
# 2 = Falha ao interpretar (parse) o JSON baixado - conteúdo inválido/corrompido
# 3 = Nenhum pacote definido em $jsonContent.Sources.Packages
# 4 = Uma ou mais instalações (winget install) falharam
# 5 = Uma ou mais atualizações (winget upgrade) falharam
# 6 = Falha mista - houve falhas tanto em instalações quanto em atualizações
$EXIT_SUCCESS          = 0
$EXIT_DOWNLOAD_FAILED  = 1
$EXIT_JSON_INVALID     = 2
$EXIT_NO_PACKAGES      = 3
$EXIT_INSTALL_FAILED   = 4
$EXIT_UPDATE_FAILED    = 5
$EXIT_MIXED_FAILURE    = 6

# ========== FUNÇÕES DE LOG ==========

function Write-Log([string]$Message) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $logFile -Value $line
}

function Write-Step([string]$Message) {
    Write-Host "`n[STEP] $Message" -ForegroundColor Cyan
    Write-Log "STEP: $Message"
}

function Write-Success([string]$Message) {
    Write-Host "[OK] $Message" -ForegroundColor Green
    Write-Log "OK: $Message"
}

function Write-ErrorMsg([string]$Message) {
    Write-Host "[ERRO] $Message" -ForegroundColor Red
    Write-Log "ERRO: $Message"
}

# ========== VERIFICAÇÃO E INSTALAÇÃO IDEMPOTENTE ==========

function Test-AppInstalled {
    param([Parameter(Mandatory)][string]$Id)

    $null = winget list --id $Id --exact --source winget --accept-source-agreements --disable-interactivity 2>&1
    return $LASTEXITCODE -eq 0
}

function Install-App {
    param([Parameter(Mandatory)][string]$Id)

    $output = winget install --id $Id --exact --silent --source winget `
        --accept-package-agreements --accept-source-agreements `
        --disable-interactivity 2>&1
    $code = $LASTEXITCODE
    Write-Log "install $Id -> exit $code`n$output"

    if ($code -eq 0 -or $code -eq $WINGET_ERROR_PACKAGE_ALREADY_INSTALLED) {
        return @{ Success = $true; Code = $code }
    }
    return @{ Success = $false; Code = $code }
}

function Update-App {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Id)

    if (-not $PSCmdlet.ShouldProcess($Id, 'winget upgrade')) {
        return @{ Success = $true; Code = 0 }
    }

    $output = winget upgrade --id $Id --exact --silent --source winget `
        --accept-package-agreements --accept-source-agreements `
        --disable-interactivity 2>&1
    $code = $LASTEXITCODE
    Write-Log "upgrade $Id -> exit $code`n$output"

    if ($code -eq 0 -or $code -eq $WINGET_ERROR_UPDATE_NOT_APPLICABLE) {
        return @{ Success = $true; Code = $code }
    }
    return @{ Success = $false; Code = $code }
}

if (-not (Test-Path $tempDir)) {
    $null = New-Item -ItemType Directory -Path $tempDir -Force
}

# ========== DOWNLOAD DO JSON ==========

Write-Step 'Baixando arquivo de configuração...'

try {
    Invoke-WebRequest -Uri $jsonUrl -OutFile $jsonFile -ProgressAction SilentlyContinue -ErrorAction Stop
    Write-Success "Arquivo salvo em: $jsonFile"
} catch {
    Write-ErrorMsg "Falha no download: $_"
    exit $EXIT_DOWNLOAD_FAILED
}

# ========== PARSE DO JSON ==========

try {
    $jsonContent = Get-Content $jsonFile -Raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-ErrorMsg "Falha ao interpretar o JSON de configuração: $_"
    exit $EXIT_JSON_INVALID
}

$packages = $jsonContent.Sources.Packages

if (-not $packages -or $packages.Count -eq 0) {
    Write-ErrorMsg 'Nenhum pacote encontrado em Sources.Packages no JSON de configuração.'
    exit $EXIT_NO_PACKAGES
}

Write-Step "Pacotes a verificar ($($packages.Count)):"
$packages | ForEach-Object { Write-Host "  - $($_.Id)" -ForegroundColor Gray }

# ========== LOOP PRINCIPAL ==========

Write-Step 'Verificando e instalando/atualizando pacotes...'

$results = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($pkg in $packages) {
    $id = $pkg.Id
    Write-Host "`n-> $id" -ForegroundColor White

    $installed = Test-AppInstalled -Id $id

    if (-not $installed) {
        Write-Host "   Não instalado. Instalando..." -ForegroundColor Yellow
        $result = Install-App -Id $id
        $action = 'Instalação'
    } else {
        Write-Host "   Já instalado. Verificando atualização..." -ForegroundColor Yellow
        $result = Update-App -Id $id
        $action = 'Atualização'
    }

    if ($result.Success) {
        Write-Success "$id ($action) OK"
        $results.Add([pscustomobject]@{ Id = $id; Status = 'OK'; Action = $action; Code = $result.Code })
    } else {
        Write-ErrorMsg "$id ($action) falhou. Código: $($result.Code)"
        $results.Add([pscustomobject]@{ Id = $id; Status = 'FALHA'; Action = $action; Code = $result.Code })
    }
}

# ========== RELATÓRIO FINAL ==========

Write-Step 'RELATÓRIO FINAL'
Write-Host ('=' * 50) -ForegroundColor Cyan

$failed         = $results | Where-Object { $_.Status -eq 'FALHA' }
$failedInstalls = $failed  | Where-Object { $_.Action -eq 'Instalação' }
$failedUpdates  = $failed  | Where-Object { $_.Action -eq 'Atualização' }

if ($failed.Count -eq 0) {
    Write-Host 'TODOS OS PACOTES FORAM PROCESSADOS COM SUCESSO!' -ForegroundColor Green
    Write-Host ('=' * 50) -ForegroundColor Cyan
    Write-Host "Log completo: $logFile" -ForegroundColor Gray
    Write-Host 'Script concluído.' -ForegroundColor Green
    exit $EXIT_SUCCESS
}

Write-Host 'PACOTES COM FALHA:' -ForegroundColor Red
$failed | ForEach-Object { Write-Host "  x $($_.Id) - $($_.Action) - código $($_.Code)" -ForegroundColor Red }
Write-Host "`nLog completo: $logFile" -ForegroundColor Yellow
Write-Host ('=' * 50) -ForegroundColor Cyan

if ($failedInstalls.Count -gt 0 -and $failedUpdates.Count -gt 0) {
    Write-ErrorMsg 'Houve falhas tanto em instalações quanto em atualizações.'
    exit $EXIT_MIXED_FAILURE
} elseif ($failedInstalls.Count -gt 0) {
    Write-ErrorMsg 'Houve falha em uma ou mais instalações.'
    exit $EXIT_INSTALL_FAILED
} else {
    Write-ErrorMsg 'Houve falha em uma ou mais atualizações.'
    exit $EXIT_UPDATE_FAILED
}
