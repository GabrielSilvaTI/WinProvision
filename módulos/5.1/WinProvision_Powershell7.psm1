#Requires -Version 5.1

function Install-PowerShell7 {
    <#
    .SYNOPSIS
        Verifica se o PowerShell 7+ está instalado; se não estiver, instala a versão mais recente diretamente do GitHub.

    .DESCRIPTION
        Módulo autônomo projetado para automação. Retorna $true em caso de sucesso ou dispara exceção/erro em falhas.

    .EXAMPLE
        Install-PowerShell7
    #>
    [CmdletBinding()]
    param()

    # ── Alta performance: desativa a barra de progresso (acelera o download) ──
    $ProgressPreference = 'SilentlyContinue'
    $ErrorActionPreference = 'Stop'

    # Habilita TLS 1.2 sem sobrescrever protocolos já habilitados no processo
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # ── Elevação de privilégios ──
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Error "Privilégios de Administrador necessários."
        return $false
    }

    # Resolve o "Program Files" 64-bit real, mesmo se este processo for 32-bit (WOW64)
    $programFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $pwshPath = Join-Path $programFiles64 "PowerShell\7\pwsh.exe"

    # Helper interno para verificação
    function Test-Pwsh7Installed {
        param([string]$KnownPath)

        $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        $exePath = if ($cmd) { $cmd.Source } elseif (Test-Path $KnownPath) { $KnownPath } else { $null }

        if (-not $exePath) { return $false }

        try {
            $rawVersion = (Get-Item $exePath).VersionInfo.ProductVersion
            $cleanVersion = ($rawVersion -split '[-+]')[0]
            return ([Version]$cleanVersion).Major -ge 7
        } catch {
            return $true
        }
    }

    if (Test-Pwsh7Installed -KnownPath $pwshPath) {
        Write-Host "PowerShell 7+ já presente." -ForegroundColor Green
        $pwshDir = Split-Path $pwshPath
        if ($env:Path -notlike "*$pwshDir*") { $env:Path += ";$pwshDir" }
        return $true
    }

    # Helper de rede com retry
    function Invoke-WithRetry {
        param(
            [scriptblock]$Action,
            [int]$MaxAttempts = 3,
            [int]$DelaySeconds = 2
        )
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            try {
                return & $Action
            } catch {
                if ($attempt -eq $MaxAttempts) { throw }
                Write-Host "Tentativa $attempt falhou, tentando novamente em ${DelaySeconds}s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $DelaySeconds
            }
        }
    }

    # Detecta arquitetura real do SO
    $osArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $assetPattern = if ($osArch -eq 'ARM64') { '*win-arm64.msi' } else { '*win-x64.msi' }

    $webClient = New-Object System.Net.WebClient
    $webClient.Headers.Add("User-Agent", "PowerShell-Installer")

    # ── Busca do release via API do GitHub ──
    try {
        Write-Host "Buscando release no GitHub..." -ForegroundColor Cyan
        $json = Invoke-WithRetry {
            $webClient.DownloadString("https://api.github.com/repos/PowerShell/PowerShell/releases/latest") | ConvertFrom-Json
        }
        $msiUrl = ($json.assets | Where-Object { $_.name -like $assetPattern } | Select-Object -First 1).browser_download_url
    } catch {
        Write-Error "Falha ao consultar API do GitHub: $_"
        $webClient.Dispose()
        return $false
    }

    if (-not $msiUrl) {
        Write-Error "URL do MSI não encontrada para o padrão '$assetPattern'."
        $webClient.Dispose()
        return $false
    }

    # ── Download direto via .NET Stream + instalação silenciosa ──
    $tempMsi = Join-Path $env:TEMP "pwsh7-$([guid]::NewGuid()).msi"
    try {
        Write-Host "Baixando MSI em alta velocidade..." -ForegroundColor Cyan
        Invoke-WithRetry { $webClient.DownloadFile($msiUrl, $tempMsi) }

        if (-not (Test-Path $tempMsi) -or (Get-Item $tempMsi).Length -eq 0) {
            throw "Arquivo MSI baixado está ausente ou vazio."
        }
    } catch {
        Write-Error "Falha no download do MSI: $_"
        return $false
    } finally {
        $webClient.Dispose()
    }

    try {
        Write-Host "Instalando..." -ForegroundColor Cyan
        $proc = Start-Process "msiexec.exe" -ArgumentList "/i `"$tempMsi`" /quiet /norestart" -Wait -PassThru
        if ($proc.ExitCode -ne 0) { throw "Falha no msiexec (Código: $($proc.ExitCode))" }
    } catch {
        Write-Error "Erro na instalação: $_"
        return $false
    } finally {
        if (Test-Path $tempMsi) { Remove-Item $tempMsi -Force -ErrorAction SilentlyContinue }
    }

    # ── Ajuste de PATH (sessão atual + máquina) ──
    $pwshDir = Split-Path $pwshPath
    $sysPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($sysPath -notlike "*$pwshDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$sysPath;$pwshDir", "Machine")
    }
    if ($env:Path -notlike "*$pwshDir*") { $env:Path += ";$pwshDir" }

    # ── Verificação pós-instalação ──
    if (-not (Test-Pwsh7Installed -KnownPath $pwshPath)) {
        Write-Error "Instalação concluída, mas a verificação pós-instalação falhou."
        return $false
    }

    Write-Host "PowerShell 7+ instalado com sucesso!" -ForegroundColor Green
    return $true
}

# Exporta explicitamente a função
Export-ModuleMember -Function Install-PowerShell7
