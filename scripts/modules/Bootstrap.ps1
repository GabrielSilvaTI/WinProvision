[CmdletBinding()]
param(
    [string]$LogPath = "C:\ProgramData\WinProvision\Logs\WinProvision_$((Get-Date).ToString('yyyyMMdd_HHmmss')).log",
    [switch]$UpgradeExisting,
    [int]$LogRetentionDays = 30
)

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Warning "[ ELEVATION ] Executando sem privilégios. Solicitando elevação..."
    $ScriptPath = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $null }
    if (-not $ScriptPath) {
        Write-Warning "[ ELEVATION ] Não foi possível determinar o caminho do script. Prosseguindo sem elevar."
    } else {
        $ArgArray = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
        if (-not $PSBoundParameters.ContainsKey('LogPath')) { $ArgArray += @('-LogPath', $LogPath) }
        foreach ($key in $PSBoundParameters.Keys) {
            $val = $PSBoundParameters[$key]
            if ($val -is [switch]) {
                if ($val.IsPresent) { $ArgArray += "-$key" }
            } else {
                $ArgArray += @("-$key", [string]$val)
            }
        }
        Start-Process powershell.exe -ArgumentList $ArgArray -Verb RunAs
        exit 0
    }
}

$LogDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path $LogDir)) { $null = New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue }

function Write-Log {
    param ([string]$Message, [ValidateSet("INFO","OK","WARN","ERROR","PROGRESS","DEBUG")][string]$Level = "INFO")
    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $FormattedLine = "[$Timestamp] [$Level] $Message"
    $colorMap = @{'INFO'='Cyan';'OK'='Green';'WARN'='Yellow';'ERROR'='Red';'PROGRESS'='Magenta';'DEBUG'='Gray'}
    if ($colorMap.ContainsKey($Level)) { $color = $colorMap[$Level] } else { $color = 'White' }

    $logMutex = $null
    $lockAcquired = $false
    try {
        $logMutex = New-Object System.Threading.Mutex($false, 'Local\WinProvisionWriteLogMutex')
        $lockAcquired = $logMutex.WaitOne(2000)
        Write-Host "[$Timestamp] " -NoNewline -ForegroundColor DarkGray
        Write-Host ("{0,-8}" -f $Level) -NoNewline -ForegroundColor $color
        Write-Host " $Message" -ForegroundColor $color
        Add-Content -Path $LogPath -Value $FormattedLine -Encoding UTF8 -ErrorAction SilentlyContinue
    } finally {
        if ($lockAcquired -and $logMutex) { try { $logMutex.ReleaseMutex() } catch {} }
        if ($logMutex) { try { $logMutex.Dispose() } catch {} }
    }
}

function Remove-PathsIfExist {
    [CmdletBinding(SupportsShouldProcess)] param ([string[]]$Paths)
    foreach ($p in $Paths) {
        if ($p -and (Test-Path $p)) {
            if ($PSCmdlet.ShouldProcess($p, "Remove")) {
                Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-LogRotation {
    param ([string]$Directory, [int]$RetentionDays)
    try {
        if (-not (Test-Path $Directory)) { return }
        $cutoff = (Get-Date).AddDays(-1 * $RetentionDays)
        Get-ChildItem -Path $Directory -Filter 'WinProvision_*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Falha na rotação de logs: $_" "WARN"
    }
}
Invoke-LogRotation -Directory $LogDir -RetentionDays $LogRetentionDays

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Log "TLS 1.3 indisponível neste runtime. Usando apenas TLS 1.2." "WARN"
    } catch {
        Write-Log "Falha ao configurar SecurityProtocol: $_" "WARN"
    }
}
[System.Net.ServicePointManager]::DefaultConnectionLimit = 512
$ProgressPreference = 'SilentlyContinue'

Write-Log "========================================================" "INFO"
Write-Log "   INICIANDO PROVISIONAMENTO DE SOFTWARE WINPROVISION" "INFO"
Write-Log "   Arquivo de Log: $LogPath" "INFO"
if ($UpgradeExisting) { Write-Log "   Modo Upgrade Ativo: softwares existentes serão atualizados." "INFO" }
Write-Log "========================================================" "INFO"

$ProgressActivity = "WinProvision - Instalação de Softwares"
Write-Progress -Activity $ProgressActivity -Status "Inicializando..." -PercentComplete 0

$MutexName = 'Global\WinProvisionBootstrapMutex'
$Mutex = $null
$AcquiredMutex = $false
try {
    $Mutex = New-Object System.Threading.Mutex($false, $MutexName)
    if ($Mutex.WaitOne(0)) {
        $AcquiredMutex = $true
    } else {
        Write-Log "Outra instância do script já está em execução. Saindo." "ERROR"
        exit 2
    }
} catch {
    Write-Log "Falha ao criar mutex, prosseguindo sem bloqueio: $_" "WARN"
}

try {

Write-Log "Mapeando registro do sistema..." "PROGRESS"
Write-Progress -Activity $ProgressActivity -Status "Mapeando registro..." -PercentComplete 2

$script:InstalledRegistry = Get-ItemProperty @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
) -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }

$script:IgnoredTokens = @('64-bit','32-bit','x64','x86','arm64','installer','setup','portable','win32','msi','app')

$script:InstalledRegistryIndexed = foreach ($item in $script:InstalledRegistry) {
    $displayName = [string]$item.DisplayName
    [PSCustomObject]@{
        DisplayName      = $displayName
        CleanDisplayName = ($displayName -replace "[-_\s]", "")
        RegistryKey      = [string]$item.PSChildName
        UninstallString  = [string]$item.UninstallString
    }
}

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

        foreach ($item in $script:InstalledRegistryIndexed) {
            $displayName = $item.DisplayName
            if ([string]::IsNullOrWhiteSpace($displayName)) { continue }

            if ($AppId -and ($item.RegistryKey.Equals($AppId, [System.StringComparison]::OrdinalIgnoreCase) -or
                $item.UninstallString.IndexOf($AppId, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                return $true
            }

            if ($AppName -and $displayName.IndexOf($AppName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }

            if ($CoreTokens.Count -gt 0) {
                $ProductTokens = if ($CoreTokens.Count -gt 1) { $CoreTokens[1..($CoreTokens.Count - 1)] } else { $CoreTokens }
                $allMatch = $true
                foreach ($token in $ProductTokens) {
                    $cleanToken = $token -replace "[-_\s]", ""
                    if ($displayName.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -and
                        $item.CleanDisplayName.IndexOf($cleanToken, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
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

function Get-CurlPath {
    $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    if ($curl) { return $curl.Source }
    $sysCurl = "$env:SystemRoot\System32\curl.exe"
    if (Test-Path $sysCurl) { return $sysCurl }
    return $null
}

function Invoke-DownloadWithRetryCurl {
    param(
        [string]$Url,
        [string]$DestinationPath,
        [string]$CurlPath,
        [int]$MaxRetries = 3,
        [int]$InitialDelaySec = 2
    )
    if (-not $CurlPath) {
        Write-Log "curl.exe não disponível." "WARN"
        return $false
    }

    $delay = $InitialDelaySec
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            Write-Log "Download com curl (tentativa $attempt): $Url" "DEBUG"
            $dir = Split-Path $DestinationPath -Parent
            if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

            $arguments = @('-sL', '--retry', '3', '-o', $DestinationPath, $Url)
            $process = Start-Process -FilePath $CurlPath -ArgumentList $arguments -Wait -NoNewWindow -PassThru
            if ($process.ExitCode -eq 0) {
                Write-Log "Download com curl concluído: $DestinationPath" "OK"
                return $true
            } else {
                Write-Log "curl retornou código $($process.ExitCode) na tentativa $attempt." "WARN"
            }
        }
        catch {
            Write-Log "Exceção no curl (tentativa $attempt): $_" "WARN"
        }
        if ($attempt -lt $MaxRetries) {
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 30)
        }
    }
    return $false
}

function Invoke-DownloadWithRetryHttpClient {
    param(
        [string]$Url,
        [string]$DestinationPath,
        [int]$MaxRetries = 3,
        [int]$InitialDelaySec = 2
    )
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    } catch {
        Write-Log "HttpClient não disponível." "WARN"
        return $false
    }

    $delay = $InitialDelaySec
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $client = $null
        $handler = $null
        $stream = $null
        $fileStream = $null
        try {
            Write-Log "Download com HttpClient (tentativa $attempt): $Url" "DEBUG"
            $dir = Split-Path $DestinationPath -Parent
            if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

            $handler = New-Object System.Net.Http.HttpClientHandler
            $handler.MaxConnectionsPerServer = 512
            $client = New-Object System.Net.Http.HttpClient($handler)
            $client.Timeout = [TimeSpan]::FromMinutes(5)
            $client.DefaultRequestHeaders.UserAgent.TryParseAdd('Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShell/5.1')

            $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $response.EnsureSuccessStatusCode() | Out-Null

            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $fileStream = [System.IO.File]::OpenWrite($DestinationPath)
            $buffer = [byte[]]::new(81920)
            $bytesRead = 0
            do {
                $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
                if ($bytesRead -gt 0) {
                    $fileStream.Write($buffer, 0, $bytesRead)
                }
            } while ($bytesRead -gt 0)

            Write-Log "Download com HttpClient concluído: $DestinationPath" "OK"
            return $true
        }
        catch {
            Write-Log "Falha no HttpClient (tentativa $attempt): $_" "WARN"
            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Seconds $delay
                $delay = [Math]::Min($delay * 2, 30)
            }
        }
        finally {
            if ($fileStream) { $fileStream.Dispose() }
            if ($stream) { $stream.Dispose() }
            if ($client) { $client.Dispose() }
            if ($handler) { $handler.Dispose() }
        }
    }
    return $false
}

function Invoke-DownloadWithFallback {
    param(
        [string]$PrimaryUrl,
        [string]$SecondaryUrl,
        [string]$DestinationPath
    )
    $curlPath = Get-CurlPath

    function TryDownloadUrl {
        param([string]$Url, [string]$Dest, [string]$Curl)
        if (-not $Url) { return $false }
        if ($Curl) {
            if (Invoke-DownloadWithRetryCurl -Url $Url -DestinationPath $Dest -CurlPath $Curl) {
                return $true
            }
        }
        return (Invoke-DownloadWithRetryHttpClient -Url $Url -DestinationPath $Dest)
    }

    if (TryDownloadUrl -Url $PrimaryUrl -Dest $DestinationPath -Curl $curlPath) {
        return $true
    }

    if ($SecondaryUrl) {
        Write-Log "Falha na URL primária, tentando secundária: $SecondaryUrl" "WARN"
        if (TryDownloadUrl -Url $SecondaryUrl -Dest $DestinationPath -Curl $curlPath) {
            return $true
        }
    }

    Write-Log "Todas as tentativas de download falharam para: $PrimaryUrl" "ERROR"
    return $false
}

function Expand-ZipFast {
    param(
        [string]$ZipPath,
        [string]$DestinationPath
    )
    try {
        if (Test-Path $DestinationPath) {
            Remove-Item -Path $DestinationPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $DestinationPath)
        Write-Log "Extraído ZIP: $ZipPath -> $DestinationPath" "OK"
        return $true
    }
    catch {
        Write-Log "Falha na extração do ZIP: $_" "ERROR"
        return $false
    }
}

function New-DownloadRunspacePool {
    param ([int]$MaxRunspaces)

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    $functionsToImport = @(
        'Get-CurlPath',
        'Invoke-DownloadWithRetryCurl',
        'Invoke-DownloadWithRetryHttpClient',
        'Write-Log'
    )
    foreach ($fname in $functionsToImport) {
        $funcDef = Get-Item "function:$fname" -ErrorAction SilentlyContinue
        if ($funcDef) {
            $entry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fname, $funcDef.Definition)
            $iss.Commands.Add($entry)
        }
    }
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('LogPath', $LogPath, $null)))

    $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1, $MaxRunspaces), $iss, $Host)
    $pool.Open()
    return $pool
}

function Invoke-ParallelDownloads {
    param(
        [hashtable[]]$DownloadTasks
    )
    if (-not $DownloadTasks -or $DownloadTasks.Count -eq 0) { return @{} }

    $runspacePool = New-DownloadRunspacePool -MaxRunspaces ([Math]::Min(8, $DownloadTasks.Count))
    $jobs = @()

    foreach ($task in $DownloadTasks) {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $runspacePool
        [void]$ps.AddScript({
            param($Url, $Dest)
            $curlPath = Get-CurlPath
            $ok = $false
            if ($curlPath) {
                $ok = Invoke-DownloadWithRetryCurl -Url $Url -DestinationPath $Dest -CurlPath $curlPath
            }
            if (-not $ok) {
                $ok = Invoke-DownloadWithRetryHttpClient -Url $Url -DestinationPath $Dest
            }
            return $ok
        }).AddParameters(@{ Url = $task.Url; Dest = $task.Destination })

        $jobs += [PSCustomObject]@{
            PowerShell  = $ps
            AsyncResult = $ps.BeginInvoke()
            Url         = $task.Url
            Dest        = $task.Destination
        }
    }

    $results = @{}
    foreach ($j in $jobs) {
        try {
            $success = $j.PowerShell.EndInvoke($j.AsyncResult)
            $results[$j.Dest] = [bool]$success
            if ($success) {
                Write-Log "Download paralelo concluído: $($j.Dest)" "OK"
            } else {
                Write-Log "Download paralelo falhou: $($j.Dest)" "ERROR"
            }
            if ($j.PowerShell.Streams.Error.Count -gt 0) {
                foreach ($e in $j.PowerShell.Streams.Error) {
                    Write-Log "Erro no runspace ($($j.Dest)): $e" "DEBUG"
                }
            }
        } catch {
            Write-Log "Erro no job paralelo para $($j.Dest): $_" "ERROR"
            $results[$j.Dest] = $false
        } finally {
            $j.PowerShell.Dispose()
        }
    }
    $runspacePool.Close()
    $runspacePool.Dispose()
    return $results
}

$script:GitHubReleaseCacheDir = Join-Path $env:ProgramData 'WinProvision\Cache'
$script:GitHubReleaseCacheTtlMinutes = 360

function Get-CachedGitHubRelease {
    param ([string]$Repo)
    try {
        if (-not (Test-Path $script:GitHubReleaseCacheDir)) {
            New-Item -Path $script:GitHubReleaseCacheDir -ItemType Directory -Force | Out-Null
        }
        $cacheFile = Join-Path $script:GitHubReleaseCacheDir (($Repo -replace '[\\/]', '_') + '.json')

        if (Test-Path $cacheFile) {
            $age = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
            if ($age.TotalMinutes -lt $script:GitHubReleaseCacheTtlMinutes) {
                Write-Log "Usando release cacheada em disco para $Repo (idade: $([int]$age.TotalMinutes) min)." "DEBUG"
                return Get-Content -Path $cacheFile -Raw | ConvertFrom-Json
            }
        }

        $Uri = "https://api.github.com/repos/$Repo/releases/latest"
        $Release = Invoke-RestMethod -Uri $Uri -Headers @{"User-Agent"="PowerShell"} -ErrorAction Stop -TimeoutSec 30
        $Release | ConvertTo-Json -Depth 10 | Set-Content -Path $cacheFile -Encoding UTF8 -ErrorAction SilentlyContinue
        return $Release
    } catch {
        $cacheFile = Join-Path $script:GitHubReleaseCacheDir (($Repo -replace '[\\/]', '_') + '.json')
        if (Test-Path $cacheFile) {
            Write-Log "Falha ao consultar API do GitHub para $Repo, usando cache expirado: $_" "WARN"
            return Get-Content -Path $cacheFile -Raw | ConvertFrom-Json
        }
        throw
    }
}

Write-Progress -Activity $ProgressActivity -Status "Verificando WinGet..." -PercentComplete 3

$WingetZipUrl_Secondary   = 'https://github.com/GabrielSilvaTI/WinProvision/releases/download/V1/winget.zip'
$ChocoZipUrl_Secondary    = 'https://github.com/GabrielSilvaTI/WinProvision/releases/download/V1/chocolatey.zip'
$PackagesJsonUrl_Primary   = 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/pacotes.json'
$PackagesJsonUrl_Secondary = 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/V1/scripts/modules/pacotes.json'

$TempRoot = $env:TEMP
$WingetZipPath = Join-Path $TempRoot 'winget_bootstrap.zip'
$WingetExtractDir = Join-Path $TempRoot 'WingetBootstrap'
$ChocoExtractDir  = Join-Path $TempRoot 'ChocoBootstrap'

function Update-PathFromRegistry {
    try {
        $machinePath = [Microsoft.Win32.Registry]::GetValue('HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 'Path', $null)
        $userPath = [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Environment', 'Path', $null)
        $paths = @()
        if ($machinePath) { $paths += $machinePath -split ';' }
        if ($userPath) { $paths += $userPath -split ';' }
        $uniquePaths = $paths | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique
        $env:Path = ($uniquePaths -join ';')
        Write-Log "PATH atualizado a partir do registro." "DEBUG"
    } catch {
        Write-Log "Falha ao atualizar PATH: $_" "WARN"
    }
}

try {
    if (Get-Command "winget" -ErrorAction SilentlyContinue) {
        Write-Log "Windows Package Manager (WinGet) já está presente." "OK"
    } else {
        Write-Log "WinGet não encontrado. Instalando via GitHub Oficial..." "INFO"
        $WingetSuccess = $false
        $WingetTempDir = Join-Path -Path $env:TEMP -ChildPath "WinGetInstall"
        if (Test-Path $WingetTempDir) { Remove-Item $WingetTempDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path $WingetTempDir -ItemType Directory -Force | Out-Null

        try {
            $Release = Get-CachedGitHubRelease -Repo 'microsoft/winget-cli'
            $Assets = $Release.assets

            $DepAsset    = $Assets | Where-Object { $_.name -like "*Dependencies*.zip" } | Select-Object -First 1
            $BundleAsset = $Assets | Where-Object { $_.name -like "*.msixbundle" -and $_.name -like "*DesktopAppInstaller*" } | Select-Object -First 1

            if (($DepAsset) -and ($BundleAsset)) {
                $DepZipPath = Join-Path -Path $WingetTempDir -ChildPath $DepAsset.name
                $BundlePath = Join-Path -Path $WingetTempDir -ChildPath $BundleAsset.name
                $DepExtDir  = Join-Path -Path $WingetTempDir -ChildPath "Dependencies"

                $downloadTasks = @(
                    @{ Url = $DepAsset.browser_download_url; Destination = $DepZipPath },
                    @{ Url = $BundleAsset.browser_download_url; Destination = $BundlePath }
                )
                $results = Invoke-ParallelDownloads -DownloadTasks $downloadTasks

                if ($results[$DepZipPath] -and $results[$BundlePath]) {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    [System.IO.Compression.ZipFile]::ExtractToDirectory($DepZipPath, $DepExtDir)
                    $DepPackages = Get-ChildItem -Path $DepExtDir -Include "*.msix","*.appx" -Recurse
                    foreach ($Dep in $DepPackages) { Add-AppxPackage -Path $Dep.FullName -ErrorAction SilentlyContinue }
                    Add-AppxPackage -Path $BundlePath -ForceApplicationShutdown -ErrorAction Stop
                    $WingetSuccess = $true
                    Write-Log "WinGet instalado com sucesso via GitHub Oficial." "OK"
                }
            }
        } catch {
            Write-Log "Falha na instalação oficial do WinGet ($($_)). Executando Fallback..." "WARN"
        }

        if (-not $WingetSuccess) {
            if (Invoke-DownloadWithFallback -PrimaryUrl $WingetZipUrl_Secondary -DestinationPath $WingetZipPath) {
                if (Expand-ZipFast -ZipPath $WingetZipPath -DestinationPath $WingetExtractDir) {
                    $PackagesList = Get-ChildItem -Path $WingetExtractDir -Include "*.msix","*.msixbundle","*.appx","*.appxbundle" -Recurse |
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
                    Write-Log "WinGet instalado via Fallback." "OK"
                }
            }
        }

        Remove-PathsIfExist -Paths @($WingetTempDir, $WingetExtractDir, $WingetZipPath)
        Update-PathFromRegistry
    }
} catch {
    Write-Log "Erro no módulo WinGet: $_" "WARN"
}

Write-Progress -Activity $ProgressActivity -Status "Verificando Chocolatey..." -PercentComplete 5
try {
    if (Get-Command "choco" -ErrorAction SilentlyContinue) {
        Write-Log "Chocolatey já está presente." "OK"
    } else {
        Write-Log "Chocolatey não encontrado. Instalando via GitHub Oficial..." "INFO"
        $ChocoSuccess = $false
        $ChocoTempDir = Join-Path -Path $env:TEMP -ChildPath "ChocoInstall"
        if (Test-Path $ChocoTempDir) { Remove-Item $ChocoTempDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path $ChocoTempDir -ItemType Directory -Force | Out-Null

        try {
            $Release = Get-CachedGitHubRelease -Repo 'chocolatey/choco'
            $Assets = $Release.assets

            $NupkgAsset = $Assets | Where-Object { $_.name -like "*.nupkg" } | Select-Object -First 1
            if ($NupkgAsset) {
                $NupkgPath = Join-Path -Path $ChocoTempDir -ChildPath "choco.nupkg"
                $ZipPath   = Join-Path -Path $ChocoTempDir -ChildPath "choco.zip"
                $ExtDir    = Join-Path -Path $ChocoTempDir -ChildPath "Extracted"

                if (Invoke-DownloadWithFallback -PrimaryUrl $NupkgAsset.browser_download_url -DestinationPath $NupkgPath) {
                    Copy-Item -Path $NupkgPath -Destination $ZipPath
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $ExtDir)

                    Set-ExecutionPolicy Bypass -Scope Process -Force
                    $InstallScript = Get-ChildItem -Path $ExtDir -Filter "chocolateyInstall.ps1" -Recurse | Select-Object -First 1
                    if ($InstallScript) {
                        & $InstallScript.FullName
                        $ChocoSuccess = $true
                        Write-Log "Chocolatey instalado com sucesso via GitHub Oficial." "OK"
                    }
                }
            }
        } catch {
            Write-Log "Falha na instalação oficial do Chocolatey ($($_)). Executando Fallback..." "WARN"
        }

        if (-not $ChocoSuccess) {
            $ChocoFallbackZip = Join-Path $env:TEMP "chocolatey_fallback.zip"
            if (Invoke-DownloadWithFallback -PrimaryUrl $ChocoZipUrl_Secondary -DestinationPath $ChocoFallbackZip) {
                if (Expand-ZipFast -ZipPath $ChocoFallbackZip -DestinationPath $ChocoExtractDir) {
                    Set-ExecutionPolicy Bypass -Scope Process -Force
                    $InstallScript = Get-ChildItem -Path $ChocoExtractDir -Filter "chocolateyInstall.ps1" -Recurse | Select-Object -First 1
                    if ($InstallScript) { & $InstallScript.FullName }
                    Write-Log "Chocolatey instalado via Fallback." "OK"
                }
                Remove-Item $ChocoFallbackZip -Force -ErrorAction SilentlyContinue
            }
        }

        Remove-PathsIfExist -Paths @($ChocoTempDir, $ChocoExtractDir)
        Update-PathFromRegistry
    }
} catch {
    Write-Log "Erro no módulo Chocolatey: $_" "WARN"
}

Write-Log "8% - Carregando lista de pacotes" "PROGRESS"
Write-Progress -Activity $ProgressActivity -Status "Carregando lista de pacotes..." -PercentComplete 8

try {
    $JsonData = Invoke-RestMethod -Uri $PackagesJsonUrl_Primary -UseBasicParsing -ErrorAction Stop -TimeoutSec 30
    $Packages = if ($JsonData.packages) { $JsonData.packages } else { $JsonData }
} catch {
    Write-Log "Falha ao carregar JSON primário ($_), tentando fallback fixado na release V1..." "WARN"
    try {
        $JsonData = Invoke-RestMethod -Uri $PackagesJsonUrl_Secondary -UseBasicParsing -ErrorAction Stop -TimeoutSec 30
        $Packages = if ($JsonData.packages) { $JsonData.packages } else { $JsonData }
        Write-Log "Lista de pacotes carregada a partir do fallback fixado." "OK"
    } catch {
        Write-Log "Falha crítica ao carregar o JSON de pacotes: $_" "ERROR"
        exit 1
    }
}

$ChocoDictionary = @{
    "Microsoft.VisualStudioCode" = "vscode"
    "GIMP.GIMP"                  = "gimp"
    "Discord.Discord"            = "discord"
    "Microsoft.PowerToys"        = "powertoys"
    "VideoLAN.VLC"               = "vlc"
    "Google.Chrome"              = "googlechrome"
    "Mozilla.Firefox"            = "firefox"
    "Microsoft.Edge"             = "microsoft-edge"
    "Microsoft.WindowsTerminal"  = "microsoft-windows-terminal"
    "Microsoft.PowerShell"       = "pwsh"
    "Git.Git"                    = "git"
    "7zip.7zip"                  = "7zip"
    "Notepad++.Notepad++"        = "notepadplusplus"
    "Spotify.Spotify"            = "spotify"
    "SlackTechnologies.Slack"    = "slack"
    "Zoom.Zoom"                  = "zoom"
    "Oracle.VirtualBox"          = "virtualbox"
    "Docker.DockerDesktop"       = "docker-desktop"
    "Microsoft.DotNet.SDK"       = "dotnetcore-sdk"
    "Python.Python"              = "python"
    "OpenJS.NodeJS"              = "nodejs"
    "Microsoft.Teams"            = "microsoft-teams"
    "Adobe.AcrobatReaderDC"      = "adobereader"
    "Brave.Brave"                = "brave"
}

$ChocoCache = @{}

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
    if ($ChocoCache.ContainsKey($SearchTerm)) { return $ChocoCache[$SearchTerm] }

    try {
        $RawOutput = & choco.exe search "$SearchTerm" --order-by=Popularity --limit-output --page-size=1 2>$null
        if (-not $RawOutput) { return $null }
        $FirstLine = @($RawOutput) | Where-Object { $_ -match '\|' } | Select-Object -First 1
        if (-not $FirstLine) { return $null }
        $result = ($FirstLine -split '\|')[0].Trim()
        $ChocoCache[$SearchTerm] = $result
        return $result
    } catch {
        return $null
    }
}

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
        Write-Log "Busca no Chocolatey não encontrou resultado para '$SearchTerm'. Usando heurística." "WARN"
    }

    return ($AppId -split "\.")[-1].ToLower()
}

$ProgressPreference = 'Continue'

$TotalCount   = if ($Packages) { @($Packages).Count } else { 0 }
$CurrentIndex = 0
$ChocoInstallQueue = [System.Collections.Generic.List[string]]::new()
$WinGetSuccessCodes = @(0, -1978335191, -1978335212, -1978335189, -1978335222)

if ($TotalCount -eq 0) {
    Write-Log "Nenhum pacote encontrado no JSON de configuração." "WARN"
}

$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($Pkg in $Packages) {
    $CurrentIndex++
    $PercentComplete = 10 + [math]::Min([math]::Round(($CurrentIndex / $TotalCount) * 80), 80)

    if ($CurrentIndex -gt 1) {
        $AvgSecPerPkg  = $Stopwatch.Elapsed.TotalSeconds / ($CurrentIndex - 1)
        $RemainingPkgs = $TotalCount - $CurrentIndex
        $EtaSec        = [math]::Max([math]::Round($AvgSecPerPkg * $RemainingPkgs), 0)
        $EtaText       = "ETA: ~$([TimeSpan]::FromSeconds($EtaSec).ToString('mm\:ss'))"
    } else {
        $EtaText = "ETA: calculando..."
    }

    $AppId   = if ($Pkg.Id) { $Pkg.Id } else { $Pkg.id }
    $AppName = if ($Pkg.Name) { $Pkg.Name } else { $Pkg.name }
    $Manager = if ($Pkg.ManagerName) { $Pkg.ManagerName.ToLower() } else { "winget" }

    if (-not $AppId) { continue }

    Write-Log "$PercentComplete% - Processando [$CurrentIndex/$TotalCount]: $AppName ($AppId) | $EtaText" "PROGRESS"
    Write-Progress -Activity $ProgressActivity -Status "[$CurrentIndex/$TotalCount] $AppName | $EtaText" -PercentComplete $PercentComplete

    try {
        $IsInstalled = Test-IsAppInstalled -AppId $AppId -AppName $AppName

        if ($IsInstalled) {
            if (-not $UpgradeExisting) {
                Write-Log "[ SKIPPED ] $AppId já está instalado." "INFO"
                continue
            }

            Write-Log "[ UPGRADE ] $AppId detectado. Tentando atualizar via WinGet..." "INFO"
            if (Get-Command "winget" -ErrorAction SilentlyContinue) {
                $wingetArgs = @('upgrade', '--id', $AppId, '-e', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements', '--silent', '--disable-interactivity')
                $Proc = Start-Process -FilePath "winget.exe" -ArgumentList $wingetArgs -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue
                Write-Log "[ UPGRADE OK ] $AppId processado (ExitCode: $($Proc.ExitCode))." "INFO"
            }
            continue
        }

        if ($Manager -eq "winget") {
            if (Get-Command "winget" -ErrorAction SilentlyContinue) {
                Write-Log "[ INSTALL ] Instalando via WinGet: $AppId..." "INFO"
                $wingetArgs = @('install', '--id', $AppId, '-e', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements', '--silent', '--disable-interactivity')
                $Proc = Start-Process -FilePath "winget.exe" -ArgumentList $wingetArgs -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue

                $ExitLooksOk = $Proc -and ($Proc.ExitCode -in $WinGetSuccessCodes)
                Start-Sleep -Milliseconds 500
                $script:InstalledRegistry = Get-ItemProperty @(
                    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
                ) -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
                $script:InstalledRegistryIndexed = foreach ($item in $script:InstalledRegistry) {
                    $dn = [string]$item.DisplayName
                    [PSCustomObject]@{
                        DisplayName      = $dn
                        CleanDisplayName = ($dn -replace "[-_\s]", "")
                        RegistryKey      = [string]$item.PSChildName
                        UninstallString  = [string]$item.UninstallString
                    }
                }
                $ConfirmedInstalled = Test-IsAppInstalled -AppId $AppId -AppName $AppName

                if ($ExitLooksOk -or $ConfirmedInstalled) {
                    Write-Log "[ SUCCESS ] $AppId instalado com sucesso (Código: $($Proc.ExitCode); confirmado no registro: $ConfirmedInstalled)." "OK"
                } else {
                    $ExitCodeStr = if ($Proc) { $Proc.ExitCode } else { "N/A" }
                    Write-Log "WinGet falhou para $AppId (ExitCode: $ExitCodeStr, não encontrado no registro). Adicionando ao fallback Chocolatey..." "WARN"
                    $ChocoInstallQueue.Add((Get-ChocoFallbackId -AppId $AppId -AppName $AppName))
                }
            } else {
                Write-Log "WinGet indisponível. Adicionando $AppId ao Chocolatey..." "WARN"
                $ChocoInstallQueue.Add((Get-ChocoFallbackId -AppId $AppId -AppName $AppName))
            }
        }
        elseif ($Manager -in @("chocolatey", "choco")) {
            $ChocoName = if ($ChocoDictionary.ContainsKey($AppId)) { $ChocoDictionary[$AppId] } else { $AppId }
            $ChocoInstallQueue.Add($ChocoName)
        }
    }
    catch {
        Write-Log "Exceção ao processar o pacote '$AppId': $_" "ERROR"
    }
}

$Stopwatch.Stop()

if ($ChocoInstallQueue.Count -gt 0) {
    try {
        $UniqueApps = $ChocoInstallQueue | Select-Object -Unique

        Write-Log "90% - Executando lote de fallback via Chocolatey" "PROGRESS"
        Write-Progress -Activity $ProgressActivity -Status "Processando fila do Chocolatey..." -PercentComplete 90
        Write-Log "Fila Chocolatey: $($UniqueApps -join ' ')" "INFO"

        if (Get-Command "choco" -ErrorAction SilentlyContinue) {
            $chocoArgs = @('install') + ($UniqueApps) + @('-y', '--no-progress', '--silent')
            $Proc = Start-Process -FilePath "choco.exe" -ArgumentList $chocoArgs -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue
            Write-Log "Lote Chocolatey concluído (ExitCode: $($Proc.ExitCode))." "INFO"
        } else {
            Write-Log "Chocolatey indisponível para processar a fila." "WARN"
        }
    } catch {
        Write-Log "Erro no lote do Chocolatey: $_" "ERROR"
    }
}

Write-Progress -Activity $ProgressActivity -Status "Concluído" -PercentComplete 100 -Completed
Write-Log "100% - Provisionamento Concluído" "PROGRESS"
Write-Log "========================================================" "INFO"
Write-Log " PROVISIONAMENTO FINALIZADO COM SUCESSO!" "OK"
Write-Log "========================================================" "INFO"

}
finally {
    if ($AcquiredMutex -and $Mutex) {
        try { $Mutex.ReleaseMutex() } catch {}
    }
    if ($Mutex) {
        try { $Mutex.Dispose() } catch {}
    }
}

exit 0
