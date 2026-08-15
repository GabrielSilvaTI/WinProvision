#Requires -Version 5.1

using namespace System.Security.Principal
using namespace System.Net

Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Módulo para verificação e instalação automática do PowerShell 7+ via GitHub Releases.
.NOTES
    Compatível com Windows PowerShell 5.1 propositalmente: este módulo é o ponto de entrada
    do provisionamento e pode ser executado antes de o PowerShell 7+ existir na máquina,
    portanto não deve depender de sintaxes exclusivas do PowerShell 7 (operador ternário,
    operador de coalescência nula, ForEach-Object -Parallel, etc.).
#>

#region Funções privadas (internas)

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

#endregion

#region Funções públicas (exportadas)

function Install-PowerShell7 {
    <#
    .SYNOPSIS
        Verifica se o PowerShell 7+ está instalado; se não estiver, instala a versão mais recente diretamente do GitHub.
    .DESCRIPTION
        Módulo autônomo projetado para automação. Retorna $true em caso de sucesso; dispara
        exceção em caso de falha.
    .EXAMPLE
        Install-PowerShell7
    .EXAMPLE
        Install-PowerShell7 -Verbose
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()

    # Alta performance: desativa a barra de progresso (acelera o download)
    $ProgressPreference = 'SilentlyContinue'
    $ErrorActionPreference = 'Stop'

    # Habilita TLS 1.2 sem sobrescrever protocolos já habilitados no processo
    [ServicePointManager]::SecurityProtocol = [ServicePointManager]::SecurityProtocol -bor [SecurityProtocolType]::Tls12

    # Elevação de privilégios
    $isAdmin = [WindowsPrincipal]::new([WindowsIdentity]::GetCurrent()).IsInRole([WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw [UnauthorizedAccessException]::new('Privilégios de Administrador são necessários para instalar o PowerShell 7+.')
    }

    # Resolve o "Program Files" 64-bit real, mesmo se este processo for 32-bit (WOW64)
    $programFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $pwshPath = Join-Path -Path $programFiles64 -ChildPath 'PowerShell\7\pwsh.exe'

    # 1. Verificação de idempotência
    if (Test-Pwsh7Installed -KnownPath $pwshPath) {
        Write-Host 'PowerShell 7+ já presente.' -ForegroundColor Green
        $pwshDir = Split-Path -Path $pwshPath -Parent
        if ($env:Path -notlike "*$pwshDir*") {
            $env:Path += ";$pwshDir"
        }
        return $true
    }

    # 2. Detecção de arquitetura real do SO
    $osArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $assetPattern = if ($osArch -eq 'ARM64') { '*win-arm64.msi' } else { '*win-x64.msi' }

    $webClient = [WebClient]::new()
    $webClient.Headers.Add('User-Agent', 'PowerShell-Installer')

    try {
        # 3. Busca do release via API do GitHub
        Write-Host 'Buscando release no GitHub...' -ForegroundColor Cyan
        try {
            $json = $webClient.DownloadString('https://api.github.com/repos/PowerShell/PowerShell/releases/latest') | ConvertFrom-Json
        }
        catch {
            throw [WebException]::new("Falha ao consultar a API do GitHub: $_", $_.Exception)
        }

        $msiUrl = ($json.assets | Where-Object name -like $assetPattern | Select-Object -First 1).browser_download_url
        if (-not $msiUrl) {
            throw [System.IO.FileNotFoundException]::new("URL do MSI não encontrada para o padrão '$assetPattern'.")
        }

        # 4. Download direto via .NET Stream
        $tempMsi = Join-Path -Path $env:TEMP -ChildPath "pwsh7-$([guid]::NewGuid()).msi"
        try {
            Write-Host 'Baixando MSI em alta velocidade...' -ForegroundColor Cyan
            $webClient.DownloadFile($msiUrl, $tempMsi)

            $downloadedFile = Get-Item -Path $tempMsi -ErrorAction SilentlyContinue
            if (-not $downloadedFile -or $downloadedFile.Length -eq 0) {
                throw 'Arquivo MSI baixado está ausente ou vazio.'
            }
        }
        catch {
            throw "Falha no download do MSI: $_"
        }
    }
    finally {
        $webClient.Dispose()
    }

    # 5. Instalação silenciosa via msiexec
    try {
        if ($PSCmdlet.ShouldProcess('PowerShell 7+', 'Instalar via msiexec /quiet')) {
            Write-Host 'Instalando...' -ForegroundColor Cyan
            $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $tempMsi, '/quiet', '/norestart') -Wait -PassThru
            if ($proc.ExitCode -ne 0) {
                throw "Falha no msiexec (Código: $($proc.ExitCode))"
            }
        }
    }
    catch {
        throw "Erro na instalação: $_"
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
        throw 'Instalação concluída, mas a verificação pós-instalação falhou.'
    }

    Write-Host 'PowerShell 7+ instalado com sucesso!' -ForegroundColor Green
    return $true
}

#endregion

Export-ModuleMember -Function Install-PowerShell7
