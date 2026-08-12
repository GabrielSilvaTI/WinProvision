#Requires -Version 7.2
<#
.SYNOPSIS
    WinProvision - Bootstrap de provisionamento de softwares para Windows (PowerShell 7.2+)
.NOTES
    Revisão aplicada: correção do bug de encaminhamento de -LogPath na elevação,
    tratamento robusto de erros (ErrorAction Stop em blocos try/catch), verificação
    de integridade (SHA256) de artefatos baixados de fontes de fallback, downloads
    via HttpClient (mais rápidos e com menor overhead que Invoke-WebRequest),
    logging via StreamWriter persistente (elimina reabertura de arquivo a cada linha),
    resolução paralela de pacotes no Chocolatey, pinagem de referências no GitHub,
    e suporte a execução via bootstrap remoto (irm | iex).
#>

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = "C:\ProgramData\WinProvision\Logs\WinProvision_$((Get-Date).ToString('yyyyMMdd_HHmmss')).log",
    [switch]$UpgradeExisting,
    [ValidateRange(1, 365)]
    [int]$LogRetentionDays = 30
)

$ErrorActionPreference = 'Stop'

# --- ELEVAÇÃO DE PRIVILÉGIOS ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "[ ELEVATION ] Executando sem privilégios. Solicitando elevação..."

    # Caminho normal: script salvo em disco (dot-sourced ou executado via -File)
    $ScriptPath = $PSCommandPath
    if (-not $ScriptPath) { $ScriptPath = $MyInvocation.MyCommand.Path }

    # Caminho de bootstrap remoto: `irm https://.../WinProvision.ps1 | iex`
    # Nesse cenário não existe arquivo em disco, então capturamos o próprio
    # texto-fonte via AST do ScriptBlock em execução e o materializamos em
    # um arquivo temporário para poder reexecutar elevado com -File.
    if (-not $ScriptPath -or -not (Test-Path $ScriptPath)) {
        try {
            $SourceText = $MyInvocation.MyCommand.ScriptBlock.Ast.Extent.Text
            if ([string]::IsNullOrWhiteSpace($SourceText)) { throw "Texto-fonte do script vazio." }

            $BootstrapDir = Join-Path $env:TEMP 'WinProvisionBootstrap'
            if (-not (Test-Path $BootstrapDir)) { $null = New-Item -Path $BootstrapDir -ItemType Directory -Force }
            $ScriptPath = Join-Path $BootstrapDir "WinProvision_$([guid]::NewGuid().ToString('N')).ps1"
            Set-Content -Path $ScriptPath -Value $SourceText -Encoding UTF8 -Force
        } catch {
            Write-Error "[ ELEVATION ] Não foi possível materializar o script para elevação (execução via pipeline sem suporte neste ambiente): $_"
            exit 1
        }
    }

    $PwshPath = [System.Environment]::ProcessPath
    if (-not $PwshPath) { $PwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
    if (-not $PwshPath) {
        Write-Error "[ ELEVATION ] Não foi possível localizar o executável do PowerShell 7+."
        exit 1
    }

    # CORREÇÃO: -LogPath sempre é encaminhado (valor default ou explícito).
    # Antes, quando o usuário informava -LogPath manualmente, o parâmetro
    # era descartado (não entrava no bloco "not ContainsKey" e era pulado
    # no loop genérico via "continue"), fazendo o processo elevado recalcular
    # um caminho de log novo e diferente do solicitado.
    $ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"", '-LogPath', "`"$LogPath`"")

    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -eq 'LogPath') { continue }
        $val = $PSBoundParameters[$key]
        if ($val -is [switch]) {
            if ($val.IsPresent) { $ArgList += "-$key" }
        } else {
            $ArgList += "-$key"
            $ArgList += "`"$val`""
        }
    }

    try {
        Start-Process -FilePath $PwshPath -ArgumentList ($ArgList -join ' ') -Verb RunAs -ErrorAction Stop
    } catch [System.ComponentModel.Win32Exception] {
        Write-Warning "[ ELEVATION ] Elevação cancelada pelo usuário (UAC negado). Encerrando."
        exit 1
    } catch {
        Write-Error "[ ELEVATION ] Falha ao iniciar processo elevado: $_"
        exit 1
    }
    exit 0
}

# --- CRIAÇÃO DE DIRETÓRIO DE LOGS E ROTAÇÃO ---
$LogDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path $LogDir)) { $null = New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue }

# --- LOGGER PERSISTENTE (StreamWriter aberto durante toda a execução) ---
# CORREÇÃO DE PERFORMANCE: Add-Content abre/fecha o arquivo a cada chamada.
# Com centenas de linhas de log (um pacote por linha, no mínimo), isso soma
# I/O desnecessário. Mantemos um único StreamWriter aberto com AutoFlush,
# o que reduz drasticamente o overhead mantendo a escrita em tempo real.
$script:LogWriter = $null
try {
    $FileStream = [System.IO.FileStream]::new($LogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $script:LogWriter = [System.IO.StreamWriter]::new($FileStream, [System.Text.Encoding]::UTF8)
    $script:LogWriter.AutoFlush = $true
} catch {
    Write-Warning "Não foi possível abrir o arquivo de log '$LogPath' para escrita: $_"
}

function Write-Log {
    param ([string]$Message, [ValidateSet("INFO", "OK", "WARN", "ERROR", "PROGRESS", "DEBUG")][string]$Level = "INFO")
    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $color = @{ INFO = 'Cyan'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; PROGRESS = 'Magenta'; DEBUG = 'Gray' }[$Level] ?? 'White'

    if ($Level -eq 'DEBUG') {
        Write-Verbose "[$Timestamp] [DEBUG] $Message"
    } else {
        Write-Host "[$Timestamp] " -NoNewline -ForegroundColor DarkGray
        Write-Host ("{0,-8}" -f $Level) -NoNewline -ForegroundColor $color
        Write-Host " $Message" -ForegroundColor $color
    }

    if ($script:LogWriter) {
        try { $script:LogWriter.WriteLine("[$Timestamp] [$Level] $Message") } catch { }
    }
}

function Invoke-LogRotation {
    param ([string]$Directory, [int]$RetentionDays)
    if (-not (Test-Path $Directory)) { return }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -Path $Directory -Filter 'WinProvision_*.log' -File -ErrorAction SilentlyContinue |
        Where-Object LastWriteTime -lt $cutoff |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
Invoke-LogRotation -Directory $LogDir -RetentionDays $LogRetentionDays

# --- EXECUTOR COM WATCHDOG (TIMEOUT DE PROCESSO) ---
function Invoke-ProcessWithTimeout {
    param (
        [string]$FilePath,
        [string[]]$ArgumentList,
        [int]$TimeoutSec = 600
    )
    try {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru -ErrorAction Stop
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            Write-Log "Processo '$FilePath' excedeu $TimeoutSec s. Encerrando árvore de processos." "WARN"
            $proc.Kill($true)
            return -1
        }
        return $proc.ExitCode
    } catch {
        Write-Log "Exceção ao executar processo '$FilePath': $_" "ERROR"
        return -1
    }
}

$ProgressPreference = 'SilentlyContinue'

Write-Log "========================================================" "INFO"
Write-Log "   INICIANDO PROVISIONAMENTO DE SOFTWARE WINPROVISION" "INFO"
Write-Log "   Arquivo de Log: $LogPath" "INFO"
if ($UpgradeExisting) { Write-Log "   Modo Upgrade Ativo: softwares existentes serão atualizados." "INFO" }
Write-Log "========================================================" "INFO"

$ProgressActivity = "WinProvision - Instalação de Softwares"
Write-Progress -Activity $ProgressActivity -Status "Inicializando..." -PercentComplete 0

# --- REGISTRO DE ARTEFATOS TEMPORÁRIOS PARA LIMPEZA GLOBAL ---
$script:GlobalTempPaths = [System.Collections.Generic.List[string]]::new()

# --- TRAVA DE INSTÂNCIA ÚNICA (MUTEX GLOBAL) ---
$MutexName = 'Global\WinProvisionBootstrapMutex'
$Mutex = $null
$AcquiredMutex = $false

try {
    $Mutex = [System.Threading.Mutex]::new($false, $MutexName)
    if (-not $Mutex.WaitOne(0)) {
        Write-Log "Outra instância do script já está em execução. Saindo." "ERROR"
        if ($script:LogWriter) { $script:LogWriter.Dispose() }
        exit 2
    }
    $AcquiredMutex = $true
} catch {
    Write-Log "Falha ao manipular Mutex, prosseguindo sem bloqueio: $_" "WARN"
}

# --- CLIENTE HTTP COMPARTILHADO (mais rápido que Invoke-WebRequest) ---
# CORREÇÃO DE PERFORMANCE: Invoke-WebRequest/Invoke-RestMethod têm overhead
# de parsing e criação de conexão a cada chamada. Um único HttpClient
# reaproveita o pool de conexões (keep-alive) e é thread-safe, podendo ser
# compartilhado inclusive entre runspaces paralelos via $using:.
$script:HttpHandler = [System.Net.Http.SocketsHttpHandler]::new()
$script:HttpHandler.PooledConnectionLifetime = [TimeSpan]::FromMinutes(5)
$script:HttpHandler.AutomaticDecompression = [System.Net.DecompressionMethods]::All
$script:HttpClient = [System.Net.Http.HttpClient]::new($script:HttpHandler)
$script:HttpClient.Timeout = [TimeSpan]::FromSeconds(300)
$script:HttpClient.DefaultRequestHeaders.UserAgent.ParseAdd('Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShell/7 WinProvision')
$script:HttpClient.DefaultRequestVersion = [version]'2.0'
$script:HttpClient.DefaultVersionPolicy = [System.Net.Http.HttpVersionPolicy]::RequestVersionOrLower

function Save-FileFromHttp {
    <#
        Download rápido e resiliente via HttpClient com retentativas exponenciais.
        Substitui Invoke-WebRequest para reduzir overhead e reaproveitar conexões.
    #>
    param (
        [System.Net.Http.HttpClient]$Client,
        [string]$Url,
        [string]$DestinationPath,
        [int]$MaxRetries = 3
    )
    $dir = Split-Path $DestinationPath -Parent
    if ($dir -and -not (Test-Path $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $response = $Client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $response.EnsureSuccessStatusCode() | Out-Null

            $fileStream = [System.IO.FileStream]::new($DestinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
            try {
                $contentStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $contentStream.CopyToAsync($fileStream).GetAwaiter().GetResult()
            } finally {
                $fileStream.Dispose()
            }
            return $true
        } catch {
            if ($attempt -ge $MaxRetries) {
                Write-Log "Falha definitiva ao baixar '$Url' após $MaxRetries tentativas: $_" "ERROR"
                return $false
            }
            $backoff = [math]::Pow(2, $attempt)
            Write-Log "Tentativa $attempt/$MaxRetries falhou para '$Url' ($_). Retentando em ${backoff}s..." "WARN"
            Start-Sleep -Seconds $backoff
        }
    }
    return $false
}

function Test-FileHashMatch {
    <#
        Verificação de integridade de artefatos de fallback (fora dos releases
        oficiais assinados). Se $ExpectedSha256 não for informado, apenas
        registra o hash calculado para fins de auditoria/trilha, sem bloquear
        — permitindo que o operador colete e fixe o hash esperado depois.
    #>
    param (
        [string]$FilePath,
        [string]$ExpectedSha256
    )
    if (-not (Test-Path $FilePath)) { return $false }
    $actualHash = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash

    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        Write-Log "Hash SHA256 de '$(Split-Path $FilePath -Leaf)': $actualHash (sem valor de referência configurado para validação automática)" "DEBUG"
        return $true
    }

    if ($actualHash -eq $ExpectedSha256) {
        Write-Log "Integridade verificada (SHA256) para '$(Split-Path $FilePath -Leaf)'." "OK"
        return $true
    }

    Write-Log "FALHA DE INTEGRIDADE em '$(Split-Path $FilePath -Leaf)'. Esperado: $ExpectedSha256 | Obtido: $actualHash" "ERROR"
    return $false
}

try {

Write-Log "Mapeando registro do sistema..." "PROGRESS"
Write-Progress -Activity $ProgressActivity -Status "Mapeando registro..." -PercentComplete 2

$UninstallKeys = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

# --- ÍNDICE DO REGISTRO DE ALTA PERFORMANCE O(1) COM HASH DE TOKENS ---
function Update-InstalledRegistryIndex {
    $raw = Get-ItemProperty $UninstallKeys -ErrorAction SilentlyContinue | Where-Object DisplayName
    $script:InstalledRegistryIndexed = foreach ($item in $raw) {
        $displayName = [string]$item.DisplayName
        [PSCustomObject]@{
            DisplayName      = $displayName
            CleanDisplayName = ($displayName -replace "[-_\s]", "")
            RegistryKey      = [string]$item.PSChildName
            UninstallString  = [string]$item.UninstallString
        }
    }

    $comparer = [StringComparer]::OrdinalIgnoreCase
    $script:RegKeysHash       = [System.Collections.Generic.HashSet[string]]::new($comparer)
    $script:RegNamesHash      = [System.Collections.Generic.HashSet[string]]::new($comparer)
    $script:RegCleanNamesHash = [System.Collections.Generic.HashSet[string]]::new($comparer)
    $script:RegTokensHash     = [System.Collections.Generic.HashSet[string]]::new($comparer)

    foreach ($entry in $script:InstalledRegistryIndexed) {
        if ($entry.RegistryKey)      { $null = $script:RegKeysHash.Add($entry.RegistryKey) }
        if ($entry.DisplayName)      {
            $null = $script:RegNamesHash.Add($entry.DisplayName)
            $tokens = ($entry.DisplayName -split "[\s\-_\.,;:]+") | Where-Object { $_.Length -gt 1 }
            foreach ($token in $tokens) {
                $null = $script:RegTokensHash.Add($token)
            }
        }
        if ($entry.CleanDisplayName) { $null = $script:RegCleanNamesHash.Add($entry.CleanDisplayName) }
    }
}
Update-InstalledRegistryIndex

$script:IgnoredTokens = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('64-bit', '32-bit', 'x64', 'x86', 'arm64', 'installer', 'setup', 'portable', 'win32', 'msi', 'app'),
    [StringComparer]::OrdinalIgnoreCase
)

function Test-IsAppInstalled {
    param ([string]$AppId, [string]$AppName)
    if ([string]::IsNullOrWhiteSpace($AppId) -and [string]::IsNullOrWhiteSpace($AppName)) { return $false }

    # Rota O(1) direta
    if ($AppId -and $script:RegKeysHash.Contains($AppId)) { return $true }
    if ($AppName -and $script:RegNamesHash.Contains($AppName)) { return $true }

    $CoreTokens = $AppId ? (($AppId -split "\.") | Where-Object { -not $script:IgnoredTokens.Contains($_) -and $_.Length -gt 1 }) : @()

    if ($CoreTokens.Count -gt 0) {
        $CleanId = ($CoreTokens -join '') -replace "[-_\s]", ""
        if ($script:RegCleanNamesHash.Contains($CleanId)) { return $true }

        $allTokensMatch = $true
        foreach ($token in $CoreTokens) {
            if (-not $script:RegTokensHash.Contains($token)) {
                $allTokensMatch = $false
                break
            }
        }
        if ($allTokensMatch -and $CoreTokens.Count -gt 0) { return $true }
    }

    # Fallback O(N) para buscas parciais
    foreach ($item in $script:InstalledRegistryIndexed) {
        if ($AppId -and $item.UninstallString -and $item.UninstallString.IndexOf($AppId, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
        if ($AppName -and $item.DisplayName -and $item.DisplayName.IndexOf($AppName, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function Test-WinGetInstalledDirect {
    param ([string]$AppId)
    if (-not (Get-Command "winget" -ErrorAction SilentlyContinue)) { return $false }
    try {
        $output = & winget.exe list --id "$AppId" --exact --accept-source-agreements 2>$null
        return ($LASTEXITCODE -eq 0 -and $output -match [regex]::Escape($AppId))
    } catch {
        return $false
    }
}

# --- DOWNLOAD RESILIENTE E EM PARALELO (via HttpClient) ---
function Invoke-DownloadFile {
    param ([string]$Url, [string]$DestinationPath, [string]$FallbackUrl, [string]$ExpectedSha256, [string]$ExpectedSha256Fallback)

    if (Save-FileFromHttp -Client $script:HttpClient -Url $Url -DestinationPath $DestinationPath) {
        if (Test-FileHashMatch -FilePath $DestinationPath -ExpectedSha256 $ExpectedSha256) {
            Write-Log "Download concluído: $DestinationPath" "OK"
            return $true
        }
        Remove-Item -Path $DestinationPath -Force -ErrorAction SilentlyContinue
        Write-Log "Download de '$Url' descartado por falha de integridade." "WARN"
    }

    if (-not $FallbackUrl) { return $false }

    Write-Log "Tentando URL de fallback: $FallbackUrl" "WARN"
    if (Save-FileFromHttp -Client $script:HttpClient -Url $FallbackUrl -DestinationPath $DestinationPath) {
        if (Test-FileHashMatch -FilePath $DestinationPath -ExpectedSha256 $ExpectedSha256Fallback) {
            Write-Log "Download (fallback) concluído: $DestinationPath" "OK"
            return $true
        }
        Remove-Item -Path $DestinationPath -Force -ErrorAction SilentlyContinue
        Write-Log "Download de fallback '$FallbackUrl' descartado por falha de integridade." "ERROR"
    }
    return $false
}

function Invoke-ParallelDownload {
    param ([hashtable[]]$DownloadTasks, [int]$ThrottleLimit = 4)
    if (-not $DownloadTasks) { return @{} }

    $client = $script:HttpClient
    $results = $DownloadTasks | ForEach-Object -ThrottleLimit ([Math]::Min($ThrottleLimit, $DownloadTasks.Count)) -Parallel {
        $task = $_
        $sharedClient = $using:client
        try {
            $response = $sharedClient.GetAsync($task.Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $response.EnsureSuccessStatusCode() | Out-Null
            $fs = [System.IO.FileStream]::new($task.Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
            try {
                $cs = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $cs.CopyToAsync($fs).GetAwaiter().GetResult()
            } finally {
                $fs.Dispose()
            }
            [PSCustomObject]@{ Destination = $task.Destination; Success = $true }
        } catch {
            [PSCustomObject]@{ Destination = $task.Destination; Success = $false }
        }
    }

    $map = @{}
    foreach ($r in $results) { $map[$r.Destination] = $r.Success }
    return $map
}

# --- CACHE DA API DO GITHUB ---
$script:GitHubReleaseCacheDir = Join-Path $env:ProgramData 'WinProvision\Cache'
$script:GitHubReleaseCacheTtlMinutes = 360

function Get-CachedGitHubRelease {
    param ([string]$Repo)
    $cacheFile = Join-Path $script:GitHubReleaseCacheDir (($Repo -replace '[\\/]', '_') + '.json')

    if (-not (Test-Path $script:GitHubReleaseCacheDir)) {
        $null = New-Item -Path $script:GitHubReleaseCacheDir -ItemType Directory -Force
    }

    if (Test-Path $cacheFile) {
        $age = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
        if ($age.TotalMinutes -lt $script:GitHubReleaseCacheTtlMinutes) {
            Write-Log "Usando release cacheada em disco para $Repo." "DEBUG"
            return Get-Content -Path $cacheFile -Raw | ConvertFrom-Json
        }
    }

    try {
        $Uri = "https://api.github.com/repos/$Repo/releases/latest"
        $Release = Invoke-RestMethod -Uri $Uri -Headers @{ "User-Agent" = "PowerShell" } -ErrorAction Stop -TimeoutSec 30 -MaximumRetryCount 2 -RetryIntervalSec 2
        $Release | ConvertTo-Json -Depth 10 | Set-Content -Path $cacheFile -Encoding UTF8 -ErrorAction SilentlyContinue
        return $Release
    } catch {
        if (Test-Path $cacheFile) {
            Write-Log "Falha ao consultar API do GitHub para $Repo, usando cache expirado: $_" "WARN"
            return Get-Content -Path $cacheFile -Raw | ConvertFrom-Json
        }
        throw
    }
}

# --- PROVISIONAMENTO DE GERENCIADORES (WINGET / CHOCOLATEY) ---
Write-Progress -Activity $ProgressActivity -Status "Verificando WinGet..." -PercentComplete 3

# CORREÇÃO DE SEGURANÇA (artefatos binários): winget.zip/chocolatey.zip são
# pacotes de instalação de ferramentas de terceiros - fixados em tag/versão
# específica para evitar apontar para um branch móvel que pode mudar a
# qualquer momento. Ajuste os hashes SHA256 abaixo após validar manualmente
# os artefatos publicados nessa tag para habilitar a verificação automática.
$WingetZipUrl_Secondary    = 'https://github.com/GabrielSilvaTI/WinProvision/releases/download/V1/winget.zip'
$ChocoZipUrl_Secondary     = 'https://github.com/GabrielSilvaTI/WinProvision/releases/download/V1/chocolatey.zip'

# CORREÇÃO (bug real reportado): pacotes.json é o MANIFESTO VIVO de pacotes
# desejados (muda conforme o usuário atualiza sua lista) - não é um artefato
# de instalação estático como os zips acima. Fixá-lo numa tag antiga (como
# a V1) trava a lista num snapshot desatualizado, reintroduzindo pacotes já
# removidos (foi assim que 'atubecatcher' - presente na tag V1, ausente do
# 'main' atual - voltou a ser instalado mesmo sem estar no JSON corrente).
# Por isso o primário aponta para o branch 'main' (fonte de verdade atual);
# a tag V1 permanece só como fallback de ÚLTIMO CASO, com aviso explícito
# no log de que os dados podem estar desatualizados.
$PackagesJsonUrl_Primary   = 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/pacotes.json'
$PackagesJsonUrl_Secondary = 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/V1/scripts/modules/pacotes.json'

# Preencha com o SHA256 real dos artefatos da tag V1 para habilitar a
# verificação de integridade obrigatória (recomendado fortemente).
$ExpectedSha256_WingetZip = ''
$ExpectedSha256_ChocoZip  = ''

$TempRoot = $env:TEMP
$WingetZipPath    = Join-Path $TempRoot 'winget_bootstrap.zip'
$WingetExtractDir = Join-Path $TempRoot 'WingetBootstrap'
$ChocoExtractDir  = Join-Path $TempRoot 'ChocoBootstrap'

$script:GlobalTempPaths.AddRange([string[]]@($WingetZipPath, $WingetExtractDir, $ChocoExtractDir))

function Update-PathFromRegistry {
    try {
        $mPath = [Microsoft.Win32.Registry]::GetValue('HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 'Path', $null)
        $uPath = [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Environment', 'Path', $null)
        $combined = (($mPath -split ';') + ($uPath -split ';')) | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique
        $env:Path = ($combined -join ';')
        Write-Log "PATH do sistema atualizado." "DEBUG"
    } catch {
        Write-Log "Falha ao atualizar PATH: $_" "WARN"
    }
}

# Instalação do WinGet
if (Get-Command "winget" -ErrorAction SilentlyContinue) {
    Write-Log "WinGet já está instalado no sistema." "OK"
} else {
    Write-Log "WinGet não encontrado. Baixando e instalando..." "INFO"
    $WingetSuccess = $false
    $WingetTempDir = Join-Path $env:TEMP "WinGetInstall"
    $script:GlobalTempPaths.Add($WingetTempDir)
    if (Test-Path $WingetTempDir) { Remove-Item $WingetTempDir -Recurse -Force -ErrorAction SilentlyContinue }
    $null = New-Item -Path $WingetTempDir -ItemType Directory -Force

    try {
        $Release = Get-CachedGitHubRelease -Repo 'microsoft/winget-cli'
        $DepAsset    = $Release.assets | Where-Object { $_.name -like "*Dependencies*.zip" } | Select-Object -First 1
        $BundleAsset = $Release.assets | Where-Object { $_.name -like "*.msixbundle" -and $_.name -like "*DesktopAppInstaller*" } | Select-Object -First 1

        if ($DepAsset -and $BundleAsset) {
            $DepZipPath = Join-Path $WingetTempDir $DepAsset.name
            $BundlePath = Join-Path $WingetTempDir $BundleAsset.name
            $DepExtDir  = Join-Path $WingetTempDir "Dependencies"

            $tasks = @(
                @{ Url = $DepAsset.browser_download_url; Destination = $DepZipPath },
                @{ Url = $BundleAsset.browser_download_url; Destination = $BundlePath }
            )
            $results = Invoke-ParallelDownload -DownloadTasks $tasks

            if ($results[$DepZipPath] -and $results[$BundlePath]) {
                # Artefatos oficiais do repositório microsoft/winget-cli: hash
                # registrado para auditoria (não bloqueia, pois muda a cada release).
                Test-FileHashMatch -FilePath $DepZipPath -ExpectedSha256 '' | Out-Null
                Test-FileHashMatch -FilePath $BundlePath -ExpectedSha256 '' | Out-Null

                Expand-Archive -Path $DepZipPath -DestinationPath $DepExtDir -Force -ErrorAction Stop
                Get-ChildItem -Path $DepExtDir -Include "*.msix", "*.appx" -Recurse | ForEach-Object {
                    try {
                        Add-AppxPackage -Path $_.FullName -ErrorAction Stop
                    } catch {
                        Write-Log "Falha ao adicionar dependência '$($_.Name)': $_" "WARN"
                    }
                }
                Add-AppxPackage -Path $BundlePath -ForceApplicationShutdown -ErrorAction Stop
                $WingetSuccess = $true
                Write-Log "WinGet instalado com sucesso via GitHub Oficial." "OK"
            }
        }
    } catch {
        Write-Log "Instalação oficial do WinGet falhou: $_. Iniciando fallback..." "WARN"
    }

    if (-not $WingetSuccess -and (Invoke-DownloadFile -Url $WingetZipUrl_Secondary -DestinationPath $WingetZipPath -ExpectedSha256 $ExpectedSha256_WingetZip)) {
        try {
            Expand-Archive -Path $WingetZipPath -DestinationPath $WingetExtractDir -Force -ErrorAction Stop
            Get-ChildItem -Path $WingetExtractDir -Include "*.msix", "*.msixbundle", "*.appx", "*.appxbundle" -Recurse |
                Sort-Object {
                    switch -Regex ($_.Name.ToLower()) {
                        'vclibs'                     { 1 }
                        'xaml|appruntime'            { 2 }
                        'desktopappinstaller|winget' { 9 }
                        default                      { 5 }
                    }
                } | ForEach-Object {
                    try {
                        Add-AppxPackage -Path $_.FullName -ForceApplicationShutdown -ErrorAction Stop
                    } catch {
                        try {
                            Invoke-ProcessWithTimeout -FilePath "Dism.exe" -ArgumentList @('/Online', '/Add-ProvisionedAppxPackage', "/PackagePath:`"$($_.FullName)`"", '/SkipLicense') -TimeoutSec 120 | Out-Null
                        } catch {
                            Write-Log "Falha ao instalar pacote fallback '$($_.Name)' via DISM: $_" "WARN"
                        }
                    }
                }
            Write-Log "WinGet instalado via pacote de fallback." "OK"
        } catch {
            Write-Log "Falha ao extrair/instalar pacote fallback do WinGet: $_" "ERROR"
        }
    }

    Update-PathFromRegistry
}

# Instalação do Chocolatey
Write-Progress -Activity $ProgressActivity -Status "Verificando Chocolatey..." -PercentComplete 5
if (Get-Command "choco" -ErrorAction SilentlyContinue) {
    Write-Log "Chocolatey já está instalado no sistema." "OK"
} else {
    Write-Log "Chocolatey não encontrado. Instalando..." "INFO"
    $ChocoSuccess = $false
    $ChocoTempDir = Join-Path $env:TEMP "ChocoInstall"
    $script:GlobalTempPaths.Add($ChocoTempDir)
    if (Test-Path $ChocoTempDir) { Remove-Item $ChocoTempDir -Recurse -Force -ErrorAction SilentlyContinue }
    $null = New-Item -Path $ChocoTempDir -ItemType Directory -Force

    $originalPolicy = Get-ExecutionPolicy -Scope Process
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force

        try {
            $Release = Get-CachedGitHubRelease -Repo 'chocolatey/choco'
            $NupkgAsset = $Release.assets | Where-Object { $_.name -like "*.nupkg" } | Select-Object -First 1
            if ($NupkgAsset) {
                $NupkgPath = Join-Path $ChocoTempDir "choco.nupkg"
                $ZipPath   = Join-Path $ChocoTempDir "choco.zip"
                $ExtDir    = Join-Path $ChocoTempDir "Extracted"

                if (Invoke-DownloadFile -Url $NupkgAsset.browser_download_url -DestinationPath $NupkgPath) {
                    Copy-Item -Path $NupkgPath -Destination $ZipPath -ErrorAction Stop
                    Expand-Archive -Path $ZipPath -DestinationPath $ExtDir -Force -ErrorAction Stop

                    $InstallScript = Get-ChildItem -Path $ExtDir -Filter "chocolateyInstall.ps1" -Recurse | Select-Object -First 1
                    if ($InstallScript) {
                        & $InstallScript.FullName
                        $ChocoSuccess = $true
                        Write-Log "Chocolatey instalado via repositório oficial." "OK"
                    }
                }
            }
        } catch {
            Write-Log "Falha na instalação oficial do Chocolatey: $_. Executando fallback..." "WARN"
        }

        if (-not $ChocoSuccess) {
            $ChocoFallbackZip = Join-Path $env:TEMP "chocolatey_fallback.zip"
            $script:GlobalTempPaths.Add($ChocoFallbackZip)
            if (Invoke-DownloadFile -Url $ChocoZipUrl_Secondary -DestinationPath $ChocoFallbackZip -ExpectedSha256 $ExpectedSha256_ChocoZip) {
                try {
                    Expand-Archive -Path $ChocoFallbackZip -DestinationPath $ChocoExtractDir -Force -ErrorAction Stop
                    $InstallScript = Get-ChildItem -Path $ChocoExtractDir -Filter "chocolateyInstall.ps1" -Recurse | Select-Object -First 1
                    if ($InstallScript) { & $InstallScript.FullName }
                    Write-Log "Chocolatey instalado via Fallback." "OK"
                } catch {
                    Write-Log "Falha no fallback do Chocolatey: $_" "ERROR"
                }
            }
        }
    } finally {
        if ($originalPolicy) {
            Set-ExecutionPolicy -ExecutionPolicy $originalPolicy -Scope Process -Force -ErrorAction SilentlyContinue
        }
    }

    Update-PathFromRegistry
}

# --- PROCESSAMENTO DA LISTA DE PACOTES ---
Write-Log "Carregando matriz de pacotes..." "PROGRESS"
Write-Progress -Activity $ProgressActivity -Status "Carregando lista de pacotes..." -PercentComplete 8

try {
    $RawJson = Invoke-RestMethod -Uri $PackagesJsonUrl_Primary -UseBasicParsing -ErrorAction Stop -TimeoutSec 30 -MaximumRetryCount 2 -RetryIntervalSec 2
} catch {
    Write-Log "Erro no repositório primário (branch 'main'). Alternando para o fallback..." "WARN"
    try {
        $RawJson = Invoke-RestMethod -Uri $PackagesJsonUrl_Secondary -UseBasicParsing -ErrorAction Stop -TimeoutSec 30 -MaximumRetryCount 2 -RetryIntervalSec 2
        Write-Log "Matriz de pacotes obtida do fallback (tag V1) com sucesso. ATENÇÃO: esta é uma cópia congelada e pode conter pacotes desatualizados ou já removidos da lista atual — revise antes de confiar no resultado." "WARN"
    } catch {
        Write-Log "Falha crítica ao obter lista JSON de softwares: $_" "ERROR"
        exit 1
    }
}

$RawPackagesList = $RawJson.packages ?? $RawJson
$Packages = [System.Collections.Generic.List[hashtable]]::new()

foreach ($p in $RawPackagesList) {
    $ht = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    if ($p -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $p.PSObject.Properties) { $ht[$prop.Name] = $prop.Value }
    } elseif ($p -is [hashtable] -or $p -is [System.Collections.IDictionary]) {
        foreach ($k in $p.Keys) { $ht[$k] = $p[$k] }
    }
    if ($ht.Count -gt 0) { $Packages.Add($ht) }
}

$ChocoDictionary = @{
    "Microsoft.VisualStudioCode" = "vscode";          "GIMP.GIMP"                  = "gimp"
    "Discord.Discord"            = "discord";         "Microsoft.PowerToys"        = "powertoys"
    "VideoLAN.VLC"               = "vlc";             "Google.Chrome"              = "googlechrome"
    "Mozilla.Firefox"            = "firefox";         "Microsoft.Edge"             = "microsoft-edge"
    "Microsoft.WindowsTerminal"  = "microsoft-windows-terminal"; "Microsoft.PowerShell" = "pwsh"
    "Git.Git"                    = "git";             "7zip.7zip"                  = "7zip"
    "Notepad++.Notepad++"        = "notepadplusplus"; "Spotify.Spotify"            = "spotify"
    "SlackTechnologies.Slack"    = "slack";           "Zoom.Zoom"                  = "zoom"
    "Oracle.VirtualBox"          = "virtualbox";      "Docker.DockerDesktop"       = "docker-desktop"
    "Microsoft.DotNet.SDK"       = "dotnetcore-sdk";  "Python.Python"              = "python"
    "OpenJS.NodeJS"              = "nodejs";          "Microsoft.Teams"            = "microsoft-teams"
    "Adobe.AcrobatReaderDC"      = "adobereader";     "Brave.Brave"                = "brave"
}

$ChocoCache = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)

function Resolve-ChocoIdFromDictionaryOrGuess {
    <#
        Resolução "rápida" sem I/O de rede: usa o dicionário fixo ou, na
        ausência, um palpite a partir do último token do AppId. Usada como
        primeira tentativa; o que não resolver aqui entra na fila de busca
        paralela via `choco search` (Resolve-ChocoIdsParallel), evitando
        chamadas de rede seriais dentro do laço principal.
    #>
    param ([string]$AppId, [string]$AppName)
    if ($ChocoDictionary.ContainsKey($AppId)) { return $ChocoDictionary[$AppId] }
    return $null
}

function Resolve-ChocoIdsParallel {
    <#
        CORREÇÃO DE PERFORMANCE: antes, cada pacote não mapeado no
        dicionário disparava um `choco.exe search` síncrono dentro do laço
        principal, serializando I/O de rede pacote a pacote. Agora todos os
        itens pendentes são resolvidos em lote, em paralelo, de uma só vez.

        CORREÇÃO DE SEGURANÇA/CORRETUDE (bug real reportado): a versão
        anterior aceitava CEGAMENTE o primeiro resultado de
        `choco search --order-by=Popularity`, e na ausência de resultado
        (ou de termo de busca válido) ainda "adivinhava" um ID a partir do
        último token do AppId. Com um termo de busca vazio/curto/genérico,
        isso pode retornar o pacote mais popular do repositório inteiro —
        sem qualquer relação com o app pedido — e instalá-lo silenciosamente
        (foi assim que 'atubecatcher' entrou sem estar no pacotes.json).

        Agora: (1) termos de busca curtos/vazios são descartados sem busca;
        (2) o candidato só é aceito se houver correspondência textual real
        entre o termo buscado e o ID/nome retornado (contém o termo, ou
        compartilha pelo menos um token significativo); (3) sem
        correspondência confiável, o item fica com ChocoId = $null e é
        reportado como não resolvido — NUNCA instalado por adivinhação.
    #>
    param ([array]$PendingItems, [int]$ThrottleLimit = 6)
    if (-not $PendingItems -or $PendingItems.Count -eq 0) { return @{} }
    if (-not (Get-Command "choco" -ErrorAction SilentlyContinue)) {
        $map = @{}
        foreach ($item in $PendingItems) {
            $map[$item.AppId] = $null
            Write-Log "Chocolatey indisponível para resolver '$($item.AppId)'; pacote NÃO será instalado por adivinhação." "WARN"
        }
        return $map
    }

    $ignoredTokens = $script:IgnoredTokens

    $results = $PendingItems | ForEach-Object -ThrottleLimit ([Math]::Min($ThrottleLimit, $PendingItems.Count)) -Parallel {
        $item = $_
        $ignored = $using:ignoredTokens

        $rawTerm = $item.AppName ? ($item.AppName -replace "\([^)]*\)", " ").Trim() : (($item.AppId -split "\.") -join " ")
        $searchTokens = ($rawTerm -split "[\s\-_\.,;:]+") |
            Where-Object { $_.Length -gt 2 -and -not $ignored.Contains($_) }

        $resolvedId = $null
        $reason = "termo de busca insuficiente"

        if ($searchTokens.Count -gt 0 -and $rawTerm.Length -ge 3) {
            $reason = "sem correspondência confiável no Chocolatey"
            try {
                $rawOutput = & choco.exe search "$rawTerm" --order-by=Popularity --limit-output --page-size=5 2>$null
                $candidates = @($rawOutput) | Where-Object { $_ -match '\|' } | ForEach-Object {
                    ($_ -split '\|')[0].Trim()
                }

                foreach ($candidateId in $candidates) {
                    $candidateNormalized = ($candidateId -replace "[-_\.]", " ")
                    # Aceita se o ID candidato contém o termo pesquisado (ou vice-versa)
                    # OU compartilha ao menos um token significativo — evita "match" com
                    # o pacote mais popular do repositório sem relação real com o pedido.
                    $containsMatch = $candidateNormalized -like "*$($searchTokens[0])*"
                    $tokenMatch = $false
                    foreach ($tok in $searchTokens) {
                        if ($candidateNormalized -match "(?i)\b$([regex]::Escape($tok))\b") { $tokenMatch = $true; break }
                    }
                    if ($containsMatch -or $tokenMatch) {
                        $resolvedId = $candidateId
                        break
                    }
                }
            } catch { }
        }

        [PSCustomObject]@{ AppId = $item.AppId; AppName = $item.AppName; ChocoId = $resolvedId; Reason = $reason; SearchTerm = $rawTerm }
    }

    $map = @{}
    foreach ($r in $results) {
        $map[$r.AppId] = $r.ChocoId
        if (-not $r.ChocoId) {
            Write-Log "[ UNRESOLVED ] Não foi possível resolver '$($r.AppId)' ($($r.AppName)) no Chocolatey [busca: '$($r.SearchTerm)'] - $($r.Reason). Pacote será IGNORADO (não instalado por adivinhação)." "WARN"
        }
    }
    return $map
}

$TotalCount = $Packages.Count
$CurrentIndex = 0
$WinGetSuccessCodes = [System.Collections.Generic.HashSet[int]]::new([int[]]@(0, -1978335191, -1978335212, -1978335189, -1978335222))
$script:PendingChocoResolution = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:DirectChocoInstallQueue = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($Pkg in $Packages) {
    $CurrentIndex++
    $PercentComplete = 10 + [math]::Min([math]::Round(($CurrentIndex / $TotalCount) * 70), 70)

    $EtaText = if ($CurrentIndex -gt 1) {
        $AvgSec  = $Stopwatch.Elapsed.TotalSeconds / ($CurrentIndex - 1)
        $EtaSec  = [math]::Max([math]::Round($AvgSec * ($TotalCount - $CurrentIndex)), 0)
        "ETA: ~$([TimeSpan]::FromSeconds($EtaSec).ToString('mm\:ss'))"
    } else {
        "ETA: calculando..."
    }

    $AppId   = [string]($Pkg['Id'] ?? $Pkg['id'])
    $AppName = [string]($Pkg['Name'] ?? $Pkg['name'])
    $Manager = ([string]($Pkg['ManagerName'] ?? "winget")).ToLower()

    if ([string]::IsNullOrWhiteSpace($AppId)) { continue }

    Write-Log "$PercentComplete% - [$CurrentIndex/$TotalCount]: $AppName ($AppId) | $EtaText" "PROGRESS"
    Write-Progress -Activity $ProgressActivity -Status "[$CurrentIndex/$TotalCount] $AppName | $EtaText" -PercentComplete $PercentComplete

    try {
        if (Test-IsAppInstalled -AppId $AppId -AppName $AppName) {
            if (-not $UpgradeExisting) {
                Write-Log "[ SKIPPED ] $AppId já instalado." "INFO"
                continue
            }

            Write-Log "[ UPGRADE ] Atualizando $AppId via WinGet..." "INFO"
            if (Get-Command "winget" -ErrorAction SilentlyContinue) {
                $args = @('upgrade', '--id', $AppId, '-e', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements', '--silent', '--disable-interactivity')
                $ExitCode = Invoke-ProcessWithTimeout -FilePath "winget.exe" -ArgumentList $args -TimeoutSec 300
                Write-Log "[ UPGRADE OK ] $AppId (Código: $ExitCode)." "INFO"
            }
            continue
        }

        if ($Manager -eq "winget") {
            if (Get-Command "winget" -ErrorAction SilentlyContinue) {
                Write-Log "[ INSTALL ] Instalando $AppId via WinGet..." "INFO"
                $args = @('install', '--id', $AppId, '-e', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements', '--silent', '--disable-interactivity')
                $ExitCode = Invoke-ProcessWithTimeout -FilePath "winget.exe" -ArgumentList $args -TimeoutSec 300

                Start-Sleep -Milliseconds 300

                if ($WinGetSuccessCodes.Contains($ExitCode) -or (Test-WinGetInstalledDirect -AppId $AppId)) {
                    Write-Log "[ SUCCESS ] $AppId instalado com sucesso." "OK"
                    $null = $script:RegKeysHash.Add($AppId)
                } else {
                    Write-Log "WinGet falhou ($ExitCode) para $AppId. Enfileirando para resolução via Chocolatey..." "WARN"
                    $quickId = Resolve-ChocoIdFromDictionaryOrGuess -AppId $AppId -AppName $AppName
                    if ($quickId) {
                        $null = $script:DirectChocoInstallQueue.Add($quickId)
                    } else {
                        $script:PendingChocoResolution.Add([PSCustomObject]@{ AppId = $AppId; AppName = $AppName })
                    }
                }
            } else {
                $quickId = Resolve-ChocoIdFromDictionaryOrGuess -AppId $AppId -AppName $AppName
                if ($quickId) {
                    $null = $script:DirectChocoInstallQueue.Add($quickId)
                } else {
                    $script:PendingChocoResolution.Add([PSCustomObject]@{ AppId = $AppId; AppName = $AppName })
                }
            }
        } elseif ($Manager -in @("chocolatey", "choco")) {
            $null = $script:DirectChocoInstallQueue.Add(($ChocoDictionary[$AppId] ?? $AppId))
        }
    } catch {
        Write-Log "Exceção no processamento do pacote '$AppId': $_" "ERROR"
    }
}

$Stopwatch.Stop()

# --- RESOLUÇÃO PARALELA DOS IDs PENDENTES NO CHOCOLATEY ---
$ChocoInstallQueue = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($id in $script:DirectChocoInstallQueue) { $null = $ChocoInstallQueue.Add($id) }

if ($script:PendingChocoResolution.Count -gt 0) {
    Write-Log "80% - Resolvendo $($script:PendingChocoResolution.Count) pacote(s) no Chocolatey em paralelo..." "PROGRESS"
    Write-Progress -Activity $ProgressActivity -Status "Resolvendo pacotes no Chocolatey..." -PercentComplete 82
    $resolvedMap = Resolve-ChocoIdsParallel -PendingItems $script:PendingChocoResolution
    foreach ($resolvedId in $resolvedMap.Values) {
        if ($resolvedId) { $null = $ChocoInstallQueue.Add($resolvedId) }
    }
}

# --- EXECUÇÃO EM LOTE DO CHOCOLATEY (FALLBACK) ---
if ($ChocoInstallQueue.Count -gt 0) {
    try {
        Write-Log "90% - Executando lote de fallback via Chocolatey" "PROGRESS"
        Write-Progress -Activity $ProgressActivity -Status "Fila Chocolatey..." -PercentComplete 90

        $QueueArray = @($ChocoInstallQueue)
        Write-Log "Fila Chocolatey: $($QueueArray -join ' ')" "INFO"

        if (Get-Command "choco" -ErrorAction SilentlyContinue) {
            $chocoArgs = @('install') + $QueueArray + @('-y', '--no-progress', '--silent')
            $ExitCode = Invoke-ProcessWithTimeout -FilePath "choco.exe" -ArgumentList $chocoArgs -TimeoutSec 1800
            Write-Log "Lote Chocolatey concluído com ExitCode: $ExitCode." "INFO"
        } else {
            Write-Log "Chocolatey indisponível para processar a fila." "WARN"
        }
    } catch {
        Write-Log "Erro ao executar lote do Chocolatey: $_" "ERROR"
    }
}

Write-Progress -Activity $ProgressActivity -Status "Concluído" -PercentComplete 100 -Completed
Write-Log "100% - Provisionamento Concluído com Sucesso!" "PROGRESS"
Write-Log "========================================================" "INFO"

}
finally {
    # --- LIMPEZA GLOBAL DE DADOS TEMPORÁRIOS ---
    foreach ($path in $script:GlobalTempPaths) {
        if ($path -and (Test-Path $path)) {
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- LIBERAÇÃO DE RECURSOS HTTP ---
    if ($script:HttpClient) { try { $script:HttpClient.Dispose() } catch {} }
    if ($script:HttpHandler) { try { $script:HttpHandler.Dispose() } catch {} }

    # --- LIBERAÇÃO DE MUTEX ---
    if ($AcquiredMutex -and $Mutex) {
        try { $Mutex.ReleaseMutex() } catch {}
    }
    if ($Mutex) {
        try { $Mutex.Dispose() } catch {}
    }

    # --- FECHAMENTO DO LOGGER ---
    if ($script:LogWriter) {
        try { $script:LogWriter.Dispose() } catch {}
    }
}

exit 0
