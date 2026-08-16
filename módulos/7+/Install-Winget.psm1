#Requires -Version 7.0

using namespace System.Security.Principal

Set-StrictMode -Version Latest
# Funções de módulo NÃO herdam preferências do script/orquestrador que as
# importa — precisam ser declaradas aqui também. Não cobre runspaces de
# ForEach-Object -Parallel, que recebem estado próprio (ver comentário
# no bloco de download).
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

<#
.SYNOPSIS
    Módulo para instalação autônoma e verificação do Microsoft WinGet.
#>

#region Funções privadas (internas)

function Test-WingetInstalled {
    <#
    .SYNOPSIS
        Verifica se o winget.exe e o pacote Microsoft.DesktopAppInstaller estão presentes e ativos.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $cmd = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
    $pkg = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue

    return [bool]($cmd -and $pkg)
}

#endregion

#region Funções públicas (exportadas)

function Install-Winget {
    <#
    .SYNOPSIS
        Verifica se o winget está instalado; caso não esteja, realiza a instalação a partir do release oficial no GitHub.
    .DESCRIPTION
        Consulta a API do GitHub para obter o release mais recente do winget-cli, baixa o pacote de
        dependências (VCLibs, WindowsAppRuntime) e o .msixbundle correspondentes à arquitetura do
        sistema operacional, e instala ambos via Add-AppxPackage.
    .PARAMETER Force
        Força o download e a reinstalação mesmo que o winget já esteja instalado e ativo.
    .PARAMETER TimeoutSec
        Timeout, em segundos, para cada requisição HTTP (consulta ao GitHub e downloads).
    .PARAMETER MaxRetries
        Número máximo de tentativas para cada requisição HTTP.
    .EXAMPLE
        Install-Winget -Verbose
    .EXAMPLE
        Install-Winget -Force
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([bool])]
    param(
        [Parameter()]
        [switch]$Force,

        [ValidateRange(5, 300)]
        [int]$TimeoutSec = 30,

        [ValidateRange(1, 10)]
        [int]$MaxRetries = 3
    )

    # 1. Validação de privilégios administrativos
    $principal = [WindowsPrincipal]::new([WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([WindowsBuiltInRole]::Administrator)) {
        throw [UnauthorizedAccessException]::new('Privilégios de Administrador são necessários para instalar o winget.')
    }

    if ([WindowsIdentity]::GetCurrent().Name -eq 'NT AUTHORITY\SYSTEM') {
        Write-Warning 'Executando como SYSTEM: Add-AppxPackage pode falhar sem uma sessão de usuário interativa.'
    }

    # 2. Checagem prévia
    if ((Test-WingetInstalled) -and -not $Force) {
        Write-Host 'winget já está instalado e ativo.' -ForegroundColor Green
        return $true
    }

    # 3. Detecção de arquitetura do sistema operacional
    $osArch = $env:PROCESSOR_ARCHITEW6432 ?? $env:PROCESSOR_ARCHITECTURE
    $archTag = $osArch -eq 'ARM64' ? 'arm64' : 'x64'

    # 4. Consulta de assets via GitHub API
    Write-Host 'Buscando assets da versão mais recente do winget...' -ForegroundColor Cyan
    try {
        $ghHeaders = @{
            'User-Agent' = 'PowerShell-Winget-Installer'
            'Accept'     = 'application/vnd.github+json'
        }
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' `
            -Headers $ghHeaders `
            -TimeoutSec $TimeoutSec `
            -MaximumRetryCount $MaxRetries `
            -RetryIntervalSec 2 `
            -ErrorAction Stop

        $depsZipUrl = ($release.assets | Where-Object Name -like '*Dependencies.zip' | Select-Object -First 1).browser_download_url
        $msixBundleUrl = ($release.assets | Where-Object Name -like '*.msixbundle' | Select-Object -First 1).browser_download_url
    }
    catch {
        throw [System.Net.WebException]::new("Falha ao consultar API do GitHub: $_", $_.Exception)
    }

    if (-not $depsZipUrl -or -not $msixBundleUrl) {
        throw [System.IO.FileNotFoundException]::new('Um ou mais assets necessários não foram encontrados no release do GitHub.')
    }

    # 5. Preparação do diretório temporário de trabalho
    $workDir = Join-Path -Path $env:TEMP -ChildPath "winget-install-$([guid]::NewGuid())"
    $null = New-Item -ItemType Directory -Path $workDir -Force

    $downloads = @(
        @{ Uri = $depsZipUrl; Out = Join-Path $workDir 'DesktopAppInstaller_Dependencies.zip' }
        @{ Uri = $msixBundleUrl; Out = Join-Path $workDir 'Microsoft.DesktopAppInstaller.msixbundle' }
    )

    try {
        # 6. Download em paralelo
        # ForEach-Object -Parallel roda cada item em um runspace isolado, que
        # NÃO herda $ErrorActionPreference/$ProgressPreference do escopo
        # externo — por isso tudo precisa ser explícito aqui, incluindo as
        # variáveis capturadas via $using:.
        Write-Host 'Baixando dependências e winget...' -ForegroundColor Cyan
        $downloads | ForEach-Object -Parallel {
            Invoke-WebRequest -Uri $_.Uri -OutFile $_.Out `
                -TimeoutSec $using:TimeoutSec `
                -MaximumRetryCount $using:MaxRetries `
                -RetryIntervalSec 2 `
                -ProgressAction SilentlyContinue `
                -ErrorAction Stop
        } -ThrottleLimit 2

        foreach ($download in $downloads) {
            $file = Get-Item -Path $download.Out -ErrorAction SilentlyContinue
            if (-not $file -or $file.Length -eq 0) {
                throw "Arquivo ausente ou vazio: $($download.Out)"
            }
        }

        # 7. Extração das dependências
        Write-Host 'Extraindo dependências...' -ForegroundColor Cyan
        $depsExtractPath = Join-Path $workDir 'deps'
        Expand-Archive -Path $downloads[0].Out -DestinationPath $depsExtractPath -Force

        $archFolder = Join-Path $depsExtractPath $archTag
        if (-not (Test-Path -Path $archFolder)) {
            throw "Pasta de dependências para a arquitetura '$archTag' não encontrada no zip."
        }

        $depFiles = Get-ChildItem -Path $archFolder -File -Include '*.appx', '*.msix' -Recurse | Sort-Object Name
        if (-not $depFiles) {
            throw "Nenhum pacote de dependência (.appx/.msix) encontrado em '$archFolder'."
        }

        # 8. Instalação das dependências
        Write-Host "Instalando dependências ($($depFiles.Count) pacote(s))..." -ForegroundColor Cyan
        foreach ($file in $depFiles) {
            if ($PSCmdlet.ShouldProcess($file.Name, 'Add-AppxPackage (dependência)')) {
                Write-Host "  - $($file.Name)" -ForegroundColor DarkGray
                Add-AppxPackage -Path $file.FullName
            }
        }

        # 9. Instalação do App Installer (winget)
        if ($PSCmdlet.ShouldProcess('Microsoft.DesktopAppInstaller', 'Add-AppxPackage (winget)')) {
            Write-Host 'Instalando winget...' -ForegroundColor Cyan
            Add-AppxPackage -Path $downloads[1].Out

            # Disponibiliza o winget na sessão atual sem exigir novo logon
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
        # Limpeza do diretório temporário, independentemente do resultado
        Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 10. Verificação pós-instalação
    if (-not $WhatIfPreference -and -not (Test-WingetInstalled)) {
        throw 'Instalação concluída, mas a verificação pós-instalação falhou.'
    }

    Write-Host 'winget instalado com sucesso!' -ForegroundColor Green
    return $true
}

#endregion

Export-ModuleMember -Function Install-Winget
