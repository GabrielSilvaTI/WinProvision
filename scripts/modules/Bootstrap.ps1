[CmdletBinding()]
param(
    # Permite ao orquestrador definir o caminho do log centralizado
    [string]$LogPath = "C:\ProgramData\WinProvision\Logs\WinProvision_$((Get-Date).ToString('yyyyMMdd_HHmmss')).log",

    # Atualiza pacotes ja instalados sem alterar a logica de deteccao
    [switch]$UpgradeExisting
)

# ============================================================================
# AUTO-ELEVACAO DE PRIVILEGIOS (PRESERVA PARAMETROS)
# ============================================================================
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Warning "[ ELEVATION ] Executando sem privilegios de Administrador. Solicitando elevacao..."

    $ScriptPath = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $null }

    if (-not $ScriptPath) {
        Write-Warning "[ ELEVATION ] Nao foi possivel determinar o caminho do script. Prosseguindo sem elevar."
    } else {
        $ArgList = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

        # Garante LogPath identico entre a instancia atual e a elevada
        if (-not $PSBoundParameters.ContainsKey('LogPath')) {
            $ArgList += " -LogPath `"$LogPath`""
        }

        foreach ($key in $PSBoundParameters.Keys) {
            $val = $PSBoundParameters[$key]
            if ($val -is [switch] -or $val -eq $true) { $ArgList += " -$key" }
            else { $ArgList += " -$key `"$val`"" }
        }

        Start-Process powershell.exe -ArgumentList $ArgList -Verb RunAs
        exit 0
    }
}

# ============================================================================
# LOG CENTRALIZADO E TELEMETRIA
# ============================================================================
$LogDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path $LogDir)) {
    $null = New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue
}

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "PROGRESS")][string]$Level = "INFO"
    )
    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $FormattedLine = "[$Timestamp] [$Level] $Message"

    switch ($Level) {
        "WARN"  { Write-Warning $Message }
        "ERROR" { Write-Error $Message -ErrorAction Continue }
        default { Write-Output $FormattedLine }
    }

    try {
        Add-Content -Path $LogPath -Value $FormattedLine -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

function Remove-PathsIfExist {
    param ([string[]]$Paths)
    foreach ($p in $Paths) {
        if ($p -and (Test-Path $p)) {
            Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

Write-Log "========================================================"
Write-Log "   INICIANDO PROVISIONAMENTO DE SOFTWARE WINPROVISION"
Write-Log "   Arquivo de Log: $LogPath"
if ($UpgradeExisting) { Write-Log "   Modo Upgrade Ativo: Softwares existentes serao atualizados." }
Write-Log "========================================================"

$ProgressActivity = "WinProvision - Instalacao de Softwares"
Write-Progress -Activity $ProgressActivity -Status "Verificando WinGet..." -PercentComplete 0

function Get-GitHubLatestAssets {
    param ([string]$Repo)
    try {
        $Uri = "https://api.github.com/repos/$Repo/releases/latest"
        $Release = Invoke-RestMethod -Uri $Uri -Headers @{"User-Agent"="PowerShell"} -ErrorAction Stop
        return $Release.assets
    } catch {
        return $null
    }
}

# ============================================================================
# BOOTSTRAP DOS GERENCIADORES DE PACOTE
# ============================================================================

# --- WINGET ---
try {
    if (Get-Command "winget" -ErrorAction SilentlyContinue) {
        Write-Log "Windows Package Manager (WinGet) ja esta presente." "INFO"
    } else {
        Write-Log "WinGet nao encontrado. Instalando via GitHub Oficial..." "INFO"
        $WingetSuccess = $false
        $WingetTempDir = Join-Path -Path $env:TEMP -ChildPath "WinGetInstall"
        $FallbackDir   = $null
        $FallbackZip   = $null
        if (Test-Path $WingetTempDir) { Remove-Item $WingetTempDir -Recurse -Force -ErrorAction SilentlyContinue }
        $null = New-Item -Path $WingetTempDir -ItemType Directory -Force

        try {
            $Assets = Get-GitHubLatestAssets -Repo "microsoft/winget-cli"
            if (-not $Assets) { throw "API GitHub sem resposta." }

            $DepAsset    = $Assets | Where-Object { $_.name -like "*Dependencies*.zip" } | Select-Object -First 1
            $BundleAsset = $Assets | Where-Object { $_.name -like "*.msixbundle" -and $_.name -like "*DesktopAppInstaller*" } | Select-Object -First 1

            if (-not $DepAsset -or -not $BundleAsset) { throw "Assets nao encontrados." }

            $DepZipPath = Join-Path -Path $WingetTempDir -ChildPath $DepAsset.name
            $BundlePath = Join-Path -Path $WingetTempDir -ChildPath $BundleAsset.name
            $DepExtDir  = Join-Path -Path $WingetTempDir -ChildPath "Dependencies"

            Invoke-WebRequest -Uri $DepAsset.browser_download_url -OutFile $DepZipPath -UseBasicParsing
            Invoke-WebRequest -Uri $BundleAsset.browser_download_url -OutFile $BundlePath -UseBasicParsing

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($DepZipPath, $DepExtDir)

            $DepPackages = Get-ChildItem -Path $DepExtDir -Include "*.msix","*.appx" -Recurse
            foreach ($Dep in $DepPackages) { Add-AppxPackage -Path $Dep.FullName -ErrorAction SilentlyContinue }

            Add-AppxPackage -Path $BundlePath -ForceApplicationShutdown -ErrorAction Stop
            $WingetSuccess = $true
            Write-Log "WinGet instalado com sucesso via GitHub Oficial." "INFO"
        } catch {
            Write-Log "Falha na instalacao oficial do WinGet ($($_)). Executando Fallback..." "WARN"
        }

        if (-not $WingetSuccess) {
            try {
                $FallbackZip = Join-Path -Path $env:TEMP -ChildPath "winget_fallback.zip"
                $FallbackDir = Join-Path -Path $env:TEMP -ChildPath "WingetFallbackExt"
                Invoke-WebRequest -Uri 'https://github.com/GabrielSilvaTI/WinProvision/releases/download/V1/winget.zip' -OutFile $FallbackZip -UseBasicParsing

                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [System.IO.Compression.ZipFile]::ExtractToDirectory($FallbackZip, $FallbackDir)

                # Ordem de instalacao importa: dependencias antes do pacote principal
                $PackagesList = Get-ChildItem -Path $FallbackDir -Include "*.msix","*.msixbundle","*.appx","*.appxbundle" -Recurse |
                    Sort-Object {
                        $n = $_.Name.ToLower()
                        if ($n -match "vclibs") { 1 }
                        elseif ($n -match "xaml" -or $n -match "appruntime") { 2 }
                        elseif ($n -match "desktopappinstaller" -or $n -match "winget") { 9 }
                        else { 5 }
                    }

                foreach ($Pkg in $PackagesList) {
                    try {
                        Add-AppxPackage -Path $Pkg.FullName -ForceApplicationShutdown -ErrorAction Stop
                    } catch {
                        Start-Process -FilePath "Dism.exe" -ArgumentList "/Online /Add-ProvisionedAppxPackage /PackagePath:`"$($Pkg.FullName)`" /SkipLicense" -Wait -NoNewWindow
                    }
                }
                Write-Log "WinGet instalado via Fallback." "INFO"
            } catch {
                Write-Log "Nao foi possivel concluir instalacao do WinGet: $_" "WARN"
            }
        }

        Remove-PathsIfExist -Paths @($WingetTempDir, $FallbackDir, $FallbackZip)
        $env:Path += ";$env:ProgramFiles\WindowsApps;$(Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Filter "winget.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DirectoryName -First 1)"
    }
} catch {
    Write-Log "Erro no modulo WinGet: $_" "WARN"
}

Write-Log "5% - Verificando Chocolatey" "PROGRESS"
Write-Progress -Activity $ProgressActivity -Status "Verificando Chocolatey..." -PercentComplete 5

# --- CHOCOLATEY ---
try {
    if (Get-Command "choco" -ErrorAction SilentlyContinue) {
        Write-Log "Chocolatey ja esta presente." "INFO"
    } else {
        Write-Log "Chocolatey nao encontrado. Instalando via GitHub Oficial..." "INFO"
        $ChocoSuccess = $false
        $ChocoTempDir = Join-Path -Path $env:TEMP -ChildPath "ChocoInstall"
        $ChocoZipPath = $null
        $ChocoExtDir  = $null
        if (Test-Path $ChocoTempDir) { Remove-Item $ChocoTempDir -Recurse -Force -ErrorAction SilentlyContinue }
        $null = New-Item -Path $ChocoTempDir -ItemType Directory -Force

        try {
            $Assets = Get-GitHubLatestAssets -Repo "chocolatey/choco"
            if (-not $Assets) { throw "API GitHub sem resposta." }

            $NupkgAsset = $Assets | Where-Object { $_.name -like "*.nupkg" } | Select-Object -First 1
            if (-not $NupkgAsset) { throw "Arquivo .nupkg nao localizado." }

            $NupkgPath = Join-Path -Path $ChocoTempDir -ChildPath "choco.nupkg"
            $ZipPath   = Join-Path -Path $ChocoTempDir -ChildPath "choco.zip"
            $ExtDir    = Join-Path -Path $ChocoTempDir -ChildPath "Extracted"

            Invoke-WebRequest -Uri $NupkgAsset.browser_download_url -OutFile $NupkgPath -UseBasicParsing
            Copy-Item -Path $NupkgPath -Destination $ZipPath
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $ExtDir)

            Set-ExecutionPolicy Bypass -Scope Process -Force
            $InstallScript = Get-ChildItem -Path $ExtDir -Filter "chocolateyInstall.ps1" -Recurse | Select-Object -First 1

            if ($InstallScript) {
                & $InstallScript.FullName
                $ChocoSuccess = $true
                Write-Log "Chocolatey instalado com sucesso via GitHub Oficial." "INFO"
            } else {
                throw "chocolateyInstall.ps1 nao encontrado no pacote .nupkg."
            }
        } catch {
            Write-Log "Falha na instalacao oficial do Chocolatey ($($_)). Executando Fallback..." "WARN"
        }

        if (-not $ChocoSuccess) {
            try {
                $ChocoZipPath = Join-Path -Path $env:TEMP -ChildPath "chocolatey_fallback.zip"
                $ChocoExtDir  = Join-Path -Path $env:TEMP -ChildPath "ChocoFallbackExt"
                Invoke-WebRequest -Uri 'https://github.com/GabrielSilvaTI/WinProvision/releases/download/V1/chocolatey.zip' -OutFile $ChocoZipPath -UseBasicParsing

                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [System.IO.Compression.ZipFile]::ExtractToDirectory($ChocoZipPath, $ChocoExtDir)

                Set-ExecutionPolicy Bypass -Scope Process -Force
                $InstallScript = Get-ChildItem -Path $ChocoExtDir -Filter "chocolateyInstall.ps1" -Recurse | Select-Object -First 1
                if ($InstallScript) { & $InstallScript.FullName }
                Write-Log "Chocolatey instalado via Fallback." "INFO"
            } catch {
                Write-Log "Falha no Fallback do Chocolatey: $_" "WARN"
            }
        }

        $env:Path += ";$env:ALLUSERSPROFILE\chocolatey\bin"
        Remove-PathsIfExist -Paths @($ChocoTempDir, $ChocoZipPath, $ChocoExtDir)
    }
} catch {
    Write-Log "Erro no modulo Chocolatey: $_" "WARN"
}

Write-Log "8% - Carregando lista de pacotes" "PROGRESS"
Write-Progress -Activity $ProgressActivity -Status "Carregando lista de pacotes..." -PercentComplete 8

# ============================================================================
# MAPEAMENTO DE REGISTRO E DETECCAO POR TOKENS
# ============================================================================
$script:InstalledRegistry = Get-ItemProperty @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
) -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }

$script:IgnoredTokens = @('64-bit', '32-bit', 'x64', 'x86', 'arm64', 'installer', 'setup', 'portable', 'win32', 'msi', 'app')

function Test-IsAppInstalled {
    param ([string]$AppId, [string]$AppName)
    try {
        if ([string]::IsNullOrWhiteSpace($AppId) -and [string]::IsNullOrWhiteSpace($AppName)) { return $false }

        $CoreTokens = @()
        if ($AppId) {
            foreach ($token in ($AppId -split "\.")) {
                if ($script:IgnoredTokens -notcontains $token.ToLower() -and $token.Length -gt 1) {
                    $CoreTokens += $token
                }
            }
        }

        foreach ($item in $script:InstalledRegistry) {
            $displayName  = [string]$item.DisplayName
            $registryKey  = [string]$item.PSChildName
            $uninstallStr = [string]$item.UninstallString

            if ([string]::IsNullOrWhiteSpace($displayName)) { continue }

            if ($AppId -and ($registryKey.Equals($AppId, [System.StringComparison]::OrdinalIgnoreCase) -or
                $uninstallStr.IndexOf($AppId, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                return $true
            }

            if ($AppName -and $displayName.IndexOf($AppName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }

            if ($CoreTokens.Count -gt 0) {
                $ProductTokens = if ($CoreTokens.Count -gt 1) { $CoreTokens[1..($CoreTokens.Count - 1)] } else { $CoreTokens }

                $allMatch = $true
                foreach ($token in $ProductTokens) {
                    $cleanDisplayName = $displayName -replace "[-_\s]", ""
                    $cleanToken       = $token -replace "[-_\s]", ""

                    if ($displayName.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -and
                        $cleanDisplayName.IndexOf($cleanToken, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                        $allMatch = $false
                        break
                    }
                }
                if ($allMatch) { return $true }
            }
        }
        return $false
    } catch {
        return $false
    }
}

# ============================================================================
# CARREGAMENTO DO JSON DE CONFIGURACAO
# ============================================================================
try {
    $JsonUrl  = "https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/pacotes.json"
    $JsonData = Invoke-RestMethod -Uri $JsonUrl -UseBasicParsing
    $Packages = if ($JsonData.packages) { $JsonData.packages } else { $JsonData }
} catch {
    Write-Log "Falha critica ao carregar o JSON de pacotes: $_" "ERROR"
    exit 1
}

# Mapeamento manual priorizado sobre a busca ao vivo para os apps mais comuns
$ChocoDictionary = @{
    "Microsoft.VisualStudioCode" = "vscode"
    "GIMP.GIMP"                  = "gimp"
    "Discord.Discord"            = "discord"
    "Microsoft.PowerToys"        = "powertoys"
    "VideoLAN.VLC"               = "vlc"
    "Google.Chrome"              = "googlechrome"
}

function Get-CleanSearchTerm {
    param ([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    $clean = $Text -replace "\([^)]*\)", " "
    $clean = $clean -replace "\s{2,}", " "
    return $clean.Trim()
}

function Resolve-ChocoPackageId {
    param ([string]$SearchTerm)
    if ([string]::IsNullOrWhiteSpace($SearchTerm)) { return $null }
    try {
        $RawOutput = & choco.exe search "$SearchTerm" --order-by=Popularity --limit-output --page-size=1 2>$null
        if (-not $RawOutput) { return $null }
        $FirstLine = @($RawOutput) | Where-Object { $_ -match '\|' } | Select-Object -First 1
        if (-not $FirstLine) { return $null }
        return ($FirstLine -split '\|')[0].Trim()
    } catch {
        return $null
    }
}

# Resolucao em cascata: dicionario manual -> busca ao vivo no Chocolatey -> heuristica de ultimo recurso
function Get-ChocoFallbackId {
    param ([string]$AppId, [string]$AppName)

    if ($ChocoDictionary.ContainsKey($AppId)) { return $ChocoDictionary[$AppId] }

    if (Get-Command "choco" -ErrorAction SilentlyContinue) {
        $SearchTerm = if ($AppName) { Get-CleanSearchTerm -Text $AppName } else { ($AppId -split "\.") -join " " }
        $Resolved = Resolve-ChocoPackageId -SearchTerm $SearchTerm
        if ($Resolved) {
            Write-Log "Pacote Chocolatey resolvido dinamicamente: '$SearchTerm' -> '$Resolved'" "INFO"
            return $Resolved
        }
        Write-Log "Busca no Chocolatey nao encontrou resultado para '$SearchTerm'. Usando heuristica de ultimo recurso." "WARN"
    }

    return ($AppId -split "\.")[-1].ToLower()
}

$WinGetSuccessCodes = @(0, -1978335191, -1978335212, -1978335189, -1978335222)
$ChocoInstallQueue  = [System.Collections.Generic.List[string]]::new()

# ============================================================================
# LOOP DE PROCESSAMENTO COM PROGRESSO E ETA REAL
# ============================================================================
$TotalCount   = if ($Packages) { @($Packages).Count } else { 0 }
$CurrentIndex = 0

if ($TotalCount -eq 0) {
    Write-Log "Nenhum pacote encontrado no JSON de configuracao." "WARN"
}

$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($Pkg in $Packages) {
    $CurrentIndex++

    # Faixa de progresso: 0-8% bootstrap, 10-90% pacotes, 90-100% lote Choco + fechamento
    $PercentComplete = 10 + [math]::Min([math]::Round(($CurrentIndex / $TotalCount) * 80), 80)

    # ETA calculada com o tempo medio real dos pacotes ja concluidos
    if ($CurrentIndex -gt 1) {
        $AvgSecPerPkg  = $Stopwatch.Elapsed.TotalSeconds / ($CurrentIndex - 1)
        $RemainingPkgs = $TotalCount - $CurrentIndex
        $EtaSec        = [math]::Max([math]::Round($AvgSecPerPkg * $RemainingPkgs), 0)
        $EtaText       = "ETA: ~$([TimeSpan]::FromSeconds($EtaSec).ToString('mm\:ss'))"
    } else {
        $EtaSec  = $null
        $EtaText = "ETA: calculando..."
    }

    $AppId   = if ($Pkg.Id) { $Pkg.Id } else { $Pkg.id }
    $AppName = if ($Pkg.Name) { $Pkg.Name } else { $Pkg.name }
    $Manager = if ($Pkg.ManagerName) { $Pkg.ManagerName.ToLower() } else { "winget" }

    if (-not $AppId) { continue }

    Write-Log "$PercentComplete% - Processando [$CurrentIndex/$TotalCount]: $AppName ($AppId) | $EtaText" "PROGRESS"

    $ProgressParams = @{
        Activity        = $ProgressActivity
        Status          = "[$CurrentIndex/$TotalCount] $AppName | $EtaText"
        PercentComplete = $PercentComplete
    }
    if ($null -ne $EtaSec) { $ProgressParams.SecondsRemaining = $EtaSec }
    Write-Progress @ProgressParams

    try {
        $IsInstalled = Test-IsAppInstalled -AppId $AppId -AppName $AppName

        if ($IsInstalled) {
            if (-not $UpgradeExisting) {
                Write-Log "[ SKIPPED ] $AppId ja esta instalado." "INFO"
                continue
            }

            Write-Log "[ UPGRADE ] $AppId detectado. Tentando atualizar via WinGet..." "INFO"
            if (Get-Command "winget" -ErrorAction SilentlyContinue) {
                $Proc = Start-Process -FilePath "winget.exe" -ArgumentList "upgrade --id `"$AppId`" -e --source winget --accept-package-agreements --accept-source-agreements --silent --disable-interactivity" -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue
                $UpgExitCode = if ($Proc) { $Proc.ExitCode } else { "N/A" }
                Write-Log "[ UPGRADE OK ] $AppId processado (ExitCode: $UpgExitCode)." "INFO"
            }
            continue
        }

        if ($Manager -eq "winget") {
            if (Get-Command "winget" -ErrorAction SilentlyContinue) {
                Write-Log "[ INSTALL ] Instalando via WinGet: $AppId..." "INFO"
                $Proc = Start-Process -FilePath "winget.exe" -ArgumentList "install --id `"$AppId`" -e --source winget --accept-package-agreements --accept-source-agreements --silent --disable-interactivity" -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue

                if ($Proc -and ($Proc.ExitCode -in $WinGetSuccessCodes)) {
                    Write-Log "[ SUCCESS ] $AppId instalado com sucesso (Codigo: $($Proc.ExitCode))." "INFO"
                } else {
                    $ExitCodeStr = if ($Proc) { $Proc.ExitCode } else { "N/A" }
                    Write-Log "WinGet falhou para $AppId (ExitCode: $ExitCodeStr). Adicionando ao fallback Chocolatey..." "WARN"
                    $ChocoInstallQueue.Add((Get-ChocoFallbackId -AppId $AppId -AppName $AppName))
                }
            } else {
                Write-Log "WinGet indisponivel. Adicionando $AppId ao Chocolatey..." "WARN"
                $ChocoInstallQueue.Add((Get-ChocoFallbackId -AppId $AppId -AppName $AppName))
            }
        }
        elseif ($Manager -in @("chocolatey", "choco")) {
            $ChocoName = if ($ChocoDictionary.ContainsKey($AppId)) { $ChocoDictionary[$AppId] } else { $AppId }
            $ChocoInstallQueue.Add($ChocoName)
        }
    }
    catch {
        Write-Log "Excecao ao processar o pacote '$AppId': $_" "ERROR"
    }
}

$Stopwatch.Stop()

# ============================================================================
# EXECUCAO EM LOTE DO CHOCOLATEY (ETAPA FINAL)
# ============================================================================
if ($ChocoInstallQueue.Count -gt 0) {
    try {
        $UniqueApps = $ChocoInstallQueue | Select-Object -Unique

        Write-Log "90% - Executando lote de fallback via Chocolatey" "PROGRESS"
        Write-Progress -Activity $ProgressActivity -Status "Processando fila do Chocolatey..." -PercentComplete 90
        Write-Log "Fila Chocolatey: $($UniqueApps -join ' ')" "INFO"

        if (Get-Command "choco" -ErrorAction SilentlyContinue) {
            $ChocoArgs = "install " + ($UniqueApps -join " ") + " -y --no-progress --silent"
            $Proc = Start-Process -FilePath "choco.exe" -ArgumentList $ChocoArgs -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue
            $BatchExitCode = if ($Proc) { $Proc.ExitCode } else { "N/A" }
            Write-Log "Lote Chocolatey concluido (ExitCode: $BatchExitCode)." "INFO"
        } else {
            Write-Log "Chocolatey indisponivel para processar a fila." "WARN"
        }
    } catch {
        Write-Log "Erro no lote do Chocolatey: $_" "ERROR"
    }
}

Write-Progress -Activity $ProgressActivity -Status "Concluido" -PercentComplete 100 -Completed
Write-Log "100% - Provisionamento Concluido" "PROGRESS"
Write-Log "========================================================"
Write-Log " PROVISIONAMENTO FINALIZADO COM SUCESSO!"
Write-Log "========================================================"

exit 0
