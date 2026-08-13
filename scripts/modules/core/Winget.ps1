#Requires -Version 7.0
<#
.SYNOPSIS
    Verifica se o winget está instalado e funcional; se não estiver, instala a
    versão mais recente a partir do GitHub, usando os dois assets oficiais do
    release: DesktopAppInstaller_Dependencies.zip e o .msixbundle do App Installer.

.DESCRIPTION
    Script 100% autônomo, sem retry/fallback interno — cada etapa roda uma
    única vez e falha rápido com o exit code correspondente, delegando
    política de retry para o módulo/orquestrador chamador.

.NOTES
    Requer PowerShell 7.0+ (usa ForEach-Object -Parallel).

    CAVEAT IMPORTANTE: Add-AppxPackage pode falhar quando este script roda sem
    uma sessão de usuário interativa (ex.: como conta SYSTEM em um agente RMM).
    Nesses casos, considere disparar o script no contexto do usuário logado.

    O DesktopAppInstaller_Dependencies.zip contém uma subpasta por arquitetura
    (x86/x64/arm64), cada uma com os pacotes VCLibs + Microsoft.WindowsAppRuntime
    exigidos pelo App Installer. Os arquivos são instalados em ordem alfabética,
    o que já respeita a ordem de dependência atual (VCLibs antes de WindowsAppRuntime).

    Códigos de saída:
        0 = OK (já instalado ou instalado com sucesso)
        1 = Sem privilégios de Administrador
        2 = Falha ao consultar a API do GitHub (winget-cli)
        3 = Asset necessário não encontrado no release (zip ou msixbundle)
        4 = Falha no download de algum arquivo
        5 = Falha ao extrair/instalar as dependências (zip)
        6 = Falha ao instalar o .msixbundle do winget
        7 = Falha na verificação pós-instalação
#>

$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

# ── 1. Verifica elevação de privilégios ──
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "Privilégios de Administrador necessários."
    exit 1
}

# Aviso: Add-AppxPackage é pouco confiável fora de uma sessão interativa
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
if ($currentUser -eq 'NT AUTHORITY\SYSTEM') {
    Write-Warning "Executando como SYSTEM: Add-AppxPackage pode falhar sem uma sessão de usuário interativa."
}

# ── 2. Checagem confiável do winget (Get-Command sozinho não é suficiente: ──
#      o stub do App Execution Alias existe mesmo com o pacote desinstalado) ──
function Test-WingetInstalled {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    $pkg = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue
    return [bool]($cmd -and $pkg)
}

if (Test-WingetInstalled) {
    Write-Host "winget já está instalado e ativo." -ForegroundColor Green
    exit 0
}

# Detecta arquitetura real do SO
$osArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$archTag = if ($osArch -eq 'ARM64') { 'arm64' } else { 'x64' }

# ── 3. Resolve URLs dos dois assets do release mais recente (via API do GitHub) ──
try {
    Write-Host "Buscando assets da versão mais recente do winget..." -ForegroundColor Cyan
    $ghHeaders = @{
        'User-Agent' = 'PowerShell-Winget-Installer'
        'Accept'     = 'application/vnd.github+json'
    }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/microsoft/winget-cli/releases/latest" -Headers $ghHeaders
    $depsZipUrl = ($release.assets | Where-Object name -like "*Dependencies.zip" | Select-Object -First 1).browser_download_url
    $msixBundleUrl = ($release.assets | Where-Object name -like "*.msixbundle" | Select-Object -First 1).browser_download_url
} catch {
    Write-Error "Falha ao consultar API do GitHub: $_"
    exit 2
}

if (-not $depsZipUrl -or -not $msixBundleUrl) {
    Write-Error "Um ou mais assets necessários não foram encontrados no release (zip de dependências ou .msixbundle)."
    exit 3
}

$workDir = Join-Path $env:TEMP "winget-install-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

$downloads = @(
    @{ Uri = $depsZipUrl;    Out = Join-Path $workDir "DesktopAppInstaller_Dependencies.zip" },
    @{ Uri = $msixBundleUrl; Out = Join-Path $workDir "Microsoft.DesktopAppInstaller.msixbundle" }
)

# ── 4. Download em paralelo (recurso nativo do PowerShell 7+) ──
try {
    Write-Host "Baixando dependências e winget..." -ForegroundColor Cyan
    $downloads | ForEach-Object -Parallel {
        Invoke-WebRequest -Uri $_.Uri -OutFile $_.Out
    } -ThrottleLimit 2

    foreach ($d in $downloads) {
        if (-not (Test-Path $d.Out) -or (Get-Item $d.Out).Length -eq 0) {
            throw "Arquivo ausente ou vazio: $($d.Out)"
        }
    }
} catch {
    Write-Error "Falha no download: $_"
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 4
}

# ── 5. Extrai o zip e instala as dependências da arquitetura correta ──
try {
    Write-Host "Extraindo dependências..." -ForegroundColor Cyan
    $depsExtractPath = Join-Path $workDir "deps"
    Expand-Archive -Path $downloads[0].Out -DestinationPath $depsExtractPath -Force

    $archFolder = Join-Path $depsExtractPath $archTag
    if (-not (Test-Path $archFolder)) {
        throw "Pasta de dependências para a arquitetura '$archTag' não encontrada no zip."
    }

    $depFiles = Get-ChildItem -Path $archFolder -File -Include "*.appx", "*.msix" -Recurse | Sort-Object Name
    if (-not $depFiles) {
        throw "Nenhum pacote de dependência (.appx/.msix) encontrado em '$archFolder'."
    }

    Write-Host "Instalando dependências ($($depFiles.Count) pacote(s))..." -ForegroundColor Cyan
    foreach ($file in $depFiles) {
        Write-Host "  - $($file.Name)" -ForegroundColor DarkGray
        Add-AppxPackage -Path $file.FullName
    }
} catch {
    Write-Error "Falha ao extrair/instalar as dependências: $_"
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 5
}

# ── 6. Instala o winget (App Installer) ──
try {
    Write-Host "Instalando winget..." -ForegroundColor Cyan
    Add-AppxPackage -Path $downloads[1].Out

    # Atualiza PATH da sessão atual para uso imediato
    $aliasPath = "$env:LocalAppData\Microsoft\WindowsApps"
    if ($env:Path -notlike "*$aliasPath*") { $env:Path += ";$aliasPath" }
} catch {
    Write-Error "Falha ao instalar o .msixbundle do winget: $_"
    exit 6
} finally {
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ── 7. Verificação pós-instalação (checagem única, sem retry) ──
if (-not (Test-WingetInstalled)) {
    Write-Error "Instalação concluída, mas a verificação pós-instalação falhou."
    exit 7
}

Write-Host "winget instalado com sucesso!" -ForegroundColor Green
exit 0
