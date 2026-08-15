#Requires -Version 7.0

<#
.SYNOPSIS
    Módulo para instalação autônoma e verificação do Microsoft WinGet.
#>

# ============================================================================
# FUNÇÕES PRIVADAS (Internas)
# ============================================================================

function Test-WingetInstalled {
    <#
    .SYNOPSIS
        Verifica se o winget.exe e o pacote Microsoft.DesktopAppInstaller estão ativos.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    $pkg = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue
    return [bool]($cmd -and $pkg)
}

# ============================================================================
# FUNÇÕES PÚBLICAS (Exportadas)
# ============================================================================

function Install-Winget {
    <#
    .SYNOPSIS
        Verifica se o winget está instalado; se não estiver, instala via GitHub Release.
    .DESCRIPTION
        Baixa o zip de dependências oficiais (VCLibs, WindowsAppRuntime) e o .msixbundle 
        mais recente diretamente do repositório oficial microsoft/winget-cli e executa 
        a instalação no sistema.
    .PARAMETER Force
        Força a rotina de rets-download e reinstalação mesmo que o winget já esteja ativo.
    .EXAMPLE
        Install-Winget -Verbose
    .EXAMPLE
        Install-Winget -Force
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter()]
        [switch]$Force
    )

    $ProgressPreference = 'SilentlyContinue'

    # 1. Verifica elevação de privilégios
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw [System.UnauthorizedAccessException]::new("Privilégios de Administrador necessários para instalar o winget.")
    }

    # Aviso sobre sessão do sistema (SYSTEM account)
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($currentUser -eq 'NT AUTHORITY\SYSTEM') {
        Write-Warning "Executando como SYSTEM: Add-AppxPackage pode falhar sem uma sessão de usuário interativa."
    }

    # 2. Checagem prévia
    if ((Test-WingetInstalled) -and -not $Force) {
        Write-Host "winget já está instalado e ativo." -ForegroundColor Green
        return $true
    }

    # Detecta arquitetura do sistema operacional
    $osArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $archTag = if ($osArch -eq 'ARM64') { 'arm64' } else { 'x64' }

    # 3. Consulta de assets via GitHub API
    try {
        Write-Host "Buscando assets da versão mais recente do winget..." -ForegroundColor Cyan
        $ghHeaders = @{
            'User-Agent' = 'PowerShell-Winget-Installer'
            'Accept'     = 'application/vnd.github+json'
        }
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/microsoft/winget-cli/releases/latest" -Headers $ghHeaders
        $depsZipUrl = ($release.assets | Where-Object name -like "*Dependencies.zip" | Select-Object -First 1).browser_download_url
        $msixBundleUrl = ($release.assets | Where-Object name -like "*.msixbundle" | Select-Object -First 1).browser_download_url
    }
    catch {
        throw [System.Net.WebException]::new("Falha ao consultar API do GitHub: $_")
    }

    if (-not $depsZipUrl -or -not $msixBundleUrl) {
        throw [System.IO.FileNotFoundException]::new("Um ou mais assets necessários não foram encontrados no release do GitHub.")
    }

    # Diretório temporário seguro de trabalho
    $workDir = Join-Path $env:TEMP "winget-install-$([guid]::NewGuid())"
    $null = New-Item -ItemType Directory -Path $workDir -Force

    $downloads = @(
        @{ Uri = $depsZipUrl;    Out = Join-Path $workDir "DesktopAppInstaller_Dependencies.zip" },
        @{ Uri = $msixBundleUrl; Out = Join-Path $workDir "Microsoft.DesktopAppInstaller.msixbundle" }
    )

    try {
        # 4. Download em paralelo
        Write-Host "Baixando dependências e winget..." -ForegroundColor Cyan
        $downloads | ForEach-Object -Parallel {
            Invoke-WebRequest -Uri $_.Uri -OutFile $_.Out
        } -ThrottleLimit 2

        foreach ($d in $downloads) {
            if (-not (Test-Path $d.Out) -or (Get-Item $d.Out).Length -eq 0) {
                throw "Arquivo ausente ou vazio: $($d.Out)"
            }
        }

        # 5. Extração e Instalação de Dependências
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
            if ($PSCmdlet.ShouldProcess($file.Name, "Add-AppxPackage (Dependência)")) {
                Write-Host "  - $($file.Name)" -ForegroundColor DarkGray
                Add-AppxPackage -Path $file.FullName
            }
        }

        # 6. Instalação do App Installer (.msixbundle)
        if ($PSCmdlet.ShouldProcess("Microsoft.DesktopAppInstaller", "Add-AppxPackage (winget)")) {
            Write-Host "Instalando winget..." -ForegroundColor Cyan
            Add-AppxPackage -Path $downloads[1].Out

            # Atualiza PATH da sessão para disponibilidade imediata
            $aliasPath = "$env:LocalAppData\Microsoft\WindowsApps"
            if ($env:Path -notlike "*$aliasPath*") { 
                $env:Path += ";$aliasPath" 
            }
        }
    }
    catch {
        throw "Falha durante o processo de instalação: $_"
    }
    finally {
        # Limpeza do diretório temporário
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 7. Verificação pós-instalação
    if (-not (Test-WingetInstalled) -and -not $WhatIfPreference) {
        throw "Instalação concluída, mas a verificação pós-instalação falhou."
    }

    Write-Host "winget instalado com sucesso!" -ForegroundColor Green
    return $true
}

# Expor apenas a função principal do módulo
Export-ModuleMember -Function Install-Winget
