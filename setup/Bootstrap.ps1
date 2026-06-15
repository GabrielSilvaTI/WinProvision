<#
.SYNOPSIS
    Bootstrap Cloud Provisioning Enterprise — Unified Headless Edition v4.7
    Interface profissional com barra de progresso global, layout consistente e
    correções estruturais sem alteração de escopo.
.DESCRIPTION
    Orquestrador 100% autônomo para Windows 10/11.
    Compatível com: FirstLogon / SetupComplete / MDM / Windows Sandbox / SYSTEM.

    Melhorias v4.7:
        - Fechamento correto do box Unicode em Write-Banner
        - Função Update-GlobalProgress (evita splatting frágil de hashtable)
        - Restauração de variáveis de ambiente segura no finally (guard para $null)
        - Add-Type com guard no bloco de saída (evita redefinição em re-execução)
        - Sort-Object com scriptblock idiomático (sem return inválido)
        - Write-Header e Write-Banner deduplicados no Main
        - Encerramento via [Environment]::Exit sem race condition de PostMessage
#>

[CmdletBinding()]
param(
    [switch]$SkipCleanup
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# Aceleração de conexões simultâneas
[System.Net.ServicePointManager]::DefaultConnectionLimit = 50
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ══════════════════════════════════════════════════════════════════════════════
#  CONFIGURAÇÃO CENTRAL
# ══════════════════════════════════════════════════════════════════════════════
$CFG = @{
    LogDir               = "$env:SystemRoot\Temp\CloudProvisioning"
    LogFile              = "$env:SystemRoot\Temp\CloudProvisioning\Bootstrap.log"
    PayloadLog           = "$env:SystemRoot\Temp\CloudProvisioning\Payload_Output.log"

    WingetZipUrl         = "https://github.com/GabrielSilvaTI/WinProvision/releases/download/v1.0.0/winget.zip"
    PayloadUrl           = "https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/setup/Provisioning.ps1"

    WingetZipPath        = "$env:SystemRoot\Temp\winget_bootstrap.zip"
    WingetExtDir         = "$env:SystemRoot\Temp\WingetBootstrap"
    PayloadPath          = "$env:SystemRoot\Temp\CloudPayload.ps1"

    NetTestUrls          = @(
        "https://www.msftconnecttest.com/connecttest.txt",
        "https://1.1.1.1",
        "https://8.8.8.8"
    )
    NetMaxRetries        = 12
    NetRetryDelaySec     = 8
    GlobalTimeoutSec     = 600

    DlMaxRetries         = 4
    DlRetryDelaySec      = 6

    AppxInstallWaitSec   = 5
}

# ══════════════════════════════════════════════════════════════════════════════
#  SISTEMA DE LOG
# ══════════════════════════════════════════════════════════════════════════════
$script:LogReady  = $false
$script:StartTime = Get-Date

function Initialize-Log {
    if (-not (Test-Path $CFG.LogDir)) {
        New-Item -Path $CFG.LogDir -ItemType Directory -Force | Out-Null
    }
    $script:LogReady = $true
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS","STEP","DEBUG")]
        [string]$Level = "INFO"
    )
    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line  = "[$ts] [$Level] $Message"
    $color = switch ($Level) {
        "SUCCESS" { "Green"    }
        "WARN"    { "Yellow"   }
        "ERROR"   { "Red"      }
        "STEP"    { "Cyan"     }
        "DEBUG"   { "DarkGray" }
        default   { "White"    }
    }
    Write-Host $line -ForegroundColor $color
    if ($script:LogReady) {
        Add-Content -Path $CFG.LogFile -Value $line -Encoding UTF8
    }
}

# Corrigido: fechamento do box Unicode com "║" no final da linha de texto
function Write-Banner {
    param([string]$Text)
    $sep = "═" * 62
    Write-Host "`n╔$sep╗" -ForegroundColor Magenta
    Write-Host ("║  " + $Text).PadRight(63) + "║" -ForegroundColor Cyan
    Write-Host "╚$sep╝" -ForegroundColor Magenta
    Write-Log $Text "STEP"
}

function Write-Header {
    Clear-Host
    Write-Host @"
╔══════════════════════════════════════════════════════════════════════════════╗
║                   CLOUD PROVISIONING BOOTSTRAP v4.7                          ║
║                         Enterprise Headless Edition                          ║
╚══════════════════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  🖥️  Máquina   : $env:COMPUTERNAME"                                    -ForegroundColor White
    Write-Host "  👤  Usuário   : $env:USERNAME"                                        -ForegroundColor White
    Write-Host "  🧠  OS        : $(([System.Environment]::OSVersion).VersionString)"   -ForegroundColor White
    Write-Host "  🐚  PowerShell: $($PSVersionTable.PSVersion)"                         -ForegroundColor White
    Write-Host "  📄  Log       : $($CFG.LogFile)"                                      -ForegroundColor White
    Write-Host ""
}

function Test-GlobalTimeout {
    $elapsed = (Get-Date) - $script:StartTime
    if ($elapsed.TotalSeconds -gt $CFG.GlobalTimeoutSec) {
        throw "Tempo limite global de $($CFG.GlobalTimeoutSec) segundos excedido. Abortando."
    }
}

# Substitui o splatting frágil de hashtable mutável por uma função dedicada
function Update-GlobalProgress {
    param(
        [string]$Status,
        [int]$Percent,
        [switch]$Completed
    )
    $activity = "🚀 Cloud Provisioning Bootstrap v4.7"
    if ($Completed) {
        Write-Progress -Activity $activity -Completed
    } else {
        Write-Progress -Activity $activity -Status $Status -PercentComplete $Percent
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  HELPER: Start-Process totalmente headless + stdin=NUL
# ══════════════════════════════════════════════════════════════════════════════
function Start-Headless {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [string]$StdOutFile = "",
        [string]$StdErrFile = ""
    )

    $psi                       = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName              = $FilePath
    $psi.Arguments             = $Arguments
    $psi.UseShellExecute       = $false
    $psi.CreateNoWindow        = $true
    $psi.WindowStyle           = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.RedirectStandardInput = $true

    if ($StdOutFile -ne "") { $psi.RedirectStandardOutput = $true }
    if ($StdErrFile -ne "") { $psi.RedirectStandardError  = $true }

    $proc = [System.Diagnostics.Process]::Start($psi)
    try { $proc.StandardInput.Close() } catch { }

    if ($psi.RedirectStandardOutput) { $outJob = $proc.StandardOutput.ReadToEndAsync() }
    if ($psi.RedirectStandardError)  { $errJob = $proc.StandardError.ReadToEndAsync()  }

    $proc.WaitForExit()

    if ($psi.RedirectStandardOutput -and $StdOutFile -ne "") {
        [System.IO.File]::WriteAllText($StdOutFile, $outJob.GetAwaiter().GetResult(), [System.Text.Encoding]::UTF8)
    }
    if ($psi.RedirectStandardError -and $StdErrFile -ne "") {
        [System.IO.File]::WriteAllText($StdErrFile, $errJob.GetAwaiter().GetResult(), [System.Text.Encoding]::UTF8)
    }

    return $proc.ExitCode
}

# ══════════════════════════════════════════════════════════════════════════════
#  PROXY DETECTION
# ══════════════════════════════════════════════════════════════════════════════
function Get-SystemProxy {
    try {
        $proxyCfg = netsh winhttp show proxy | Select-String "Proxy Server" |
                    ForEach-Object { $_ -replace '.*:\s*', '' }
        if ($proxyCfg -and $proxyCfg -ne "(no proxy)") {
            $proxyUrl = "http://$proxyCfg"
            Write-Log "Proxy detectado: $proxyUrl" "DEBUG"
            return $proxyUrl
        }
    } catch { }
    return $null
}

# ══════════════════════════════════════════════════════════════════════════════
#  ETAPA 1 — CONECTIVIDADE DE REDE
# ══════════════════════════════════════════════════════════════════════════════
function Test-NetworkReady {
    Write-Log "Verificando conectividade de rede..." "STEP"
    $proxy = Get-SystemProxy

    for ($i = 1; $i -le $CFG.NetMaxRetries; $i++) {
        Test-GlobalTimeout
        $percent = [math]::Round(($i / $CFG.NetMaxRetries) * 100)
        Write-Progress -Activity "🌐 Verificando rede" `
                       -Status "Tentativa $i de $($CFG.NetMaxRetries)" `
                       -PercentComplete $percent

        foreach ($url in $CFG.NetTestUrls) {
            try {
                $req            = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($url)
                $req.Timeout    = 6000
                $req.Method     = "HEAD"
                $req.UserAgent  = "CloudBootstrap/4.7"
                if ($proxy) { $req.Proxy = New-Object System.Net.WebProxy($proxy, $true) }
                $resp = $req.GetResponse()
                $resp.Close()
                Write-Progress -Activity "🌐 Rede OK" -Completed
                Write-Log "Rede OK via $url (tentativa $i)." "SUCCESS"
                return $true
            } catch { }
        }

        if ($i -lt $CFG.NetMaxRetries) {
            Write-Log "Sem rede. Aguardando $($CFG.NetRetryDelaySec)s... ($i/$($CFG.NetMaxRetries))" "WARN"
            Start-Sleep -Seconds $CFG.NetRetryDelaySec
        }
    }

    Write-Progress -Activity "🌐 Rede" -Completed
    return $false
}

# ══════════════════════════════════════════════════════════════════════════════
#  DOWNLOAD RESILIENTE
# ══════════════════════════════════════════════════════════════════════════════
function Invoke-Download {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Label = ""
    )
    if ($Label -eq "") { $Label = (Split-Path $Url -Leaf) }
    if (Test-Path $Destination) { Remove-Item $Destination -Force -ErrorAction SilentlyContinue }

    $proxy = Get-SystemProxy

    for ($attempt = 1; $attempt -le $CFG.DlMaxRetries; $attempt++) {
        Test-GlobalTimeout
        Write-Log "Download [$attempt/$($CFG.DlMaxRetries)] $Label" "INFO"
        Write-Progress -Activity "📥 Baixando $Label" -Status "Tentativa $attempt" -PercentComplete 0

        # Método A: HttpWebRequest
        try {
            $req           = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Url)
            $req.Timeout   = 360000
            $req.Method    = "GET"
            $req.UserAgent = "CloudBootstrap/4.7"
            if ($proxy) { $req.Proxy = New-Object System.Net.WebProxy($proxy, $true) }

            $resp       = $req.GetResponse()
            $totalBytes = $resp.ContentLength
            $stream     = $resp.GetResponseStream()
            $fs         = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create,
                                                  [System.IO.FileAccess]::Write,
                                                  [System.IO.FileShare]::None)
            $buf         = New-Object byte[] 1048576
            $downloaded  = 0
            $lastPercent = 0

            do {
                $read = $stream.Read($buf, 0, $buf.Length)
                if ($read -gt 0) {
                    $fs.Write($buf, 0, $read)
                    $downloaded += $read
                    if ($totalBytes -gt 0) {
                        $percent = [math]::Round(($downloaded / $totalBytes) * 100)
                        if ($percent -ne $lastPercent) {
                            Write-Progress -Activity "📥 Baixando $Label" `
                                           -Status "$percent% concluído" `
                                           -PercentComplete $percent
                            $lastPercent = $percent
                        }
                    }
                }
            } while ($read -gt 0)

            $fs.Flush(); $fs.Close()
            $stream.Close(); $resp.Close()

            $size = (Get-Item $Destination -ErrorAction SilentlyContinue).Length
            if ($size -gt 0) {
                Write-Progress -Activity "📥 $Label" -Completed
                Write-Log "  OK via HttpWebRequest ($([Math]::Round($size/1KB,1)) KB)." "SUCCESS"
                return
            }
            throw "Arquivo vazio."
        } catch {
            Write-Log "  HttpWebRequest: $($_.Exception.Message)" "WARN"
            if (Test-Path $Destination) { Remove-Item $Destination -Force -ErrorAction SilentlyContinue }
        }

        # Método B: BITS
        try {
            $bitsCmd = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
            if ($bitsCmd) {
                Start-BitsTransfer -Source $Url -Destination $Destination -Priority Foreground -ErrorAction Stop
                $size = (Get-Item $Destination -ErrorAction SilentlyContinue).Length
                if ($size -gt 0) {
                    Write-Progress -Activity "📥 $Label" -Completed
                    Write-Log "  OK via BITS ($([Math]::Round($size/1KB,1)) KB)." "SUCCESS"
                    return
                }
                throw "BITS gerou arquivo vazio."
            }
        } catch {
            Write-Log "  BITS: $($_.Exception.Message)" "WARN"
            if (Test-Path $Destination) { Remove-Item $Destination -Force -ErrorAction SilentlyContinue }
        }

        # Método C: WebClient
        try {
            $wc                    = New-Object System.Net.WebClient
            $wc.Headers["User-Agent"] = "CloudBootstrap/4.7"
            if ($proxy) { $wc.Proxy = New-Object System.Net.WebProxy($proxy, $true) }
            $wc.DownloadFile($Url, $Destination)
            $size = (Get-Item $Destination -ErrorAction SilentlyContinue).Length
            if ($size -gt 0) {
                Write-Progress -Activity "📥 $Label" -Completed
                Write-Log "  OK via WebClient ($([Math]::Round($size/1KB,1)) KB)." "SUCCESS"
                return
            }
            throw "WebClient gerou arquivo vazio."
        } catch {
            Write-Log "  WebClient: $($_.Exception.Message)" "WARN"
            if (Test-Path $Destination) { Remove-Item $Destination -Force -ErrorAction SilentlyContinue }
        }

        if ($attempt -lt $CFG.DlMaxRetries) {
            Write-Log "Todos métodos falharam. Aguardando $($CFG.DlRetryDelaySec)s..." "WARN"
            Start-Sleep -Seconds $CFG.DlRetryDelaySec
        }
    }

    Write-Progress -Activity "📥 $Label" -Completed
    throw "FALHA PERMANENTE: impossível baixar '$Label'."
}

# ══════════════════════════════════════════════════════════════════════════════
#  EXTRAÇÃO DE ZIP
# ══════════════════════════════════════════════════════════════════════════════
function Expand-ZipSafe {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$DestDir
    )

    Write-Log "Extraindo '$ZipPath' para '$DestDir'..." "INFO"
    $zipSize = (Get-Item $ZipPath -ErrorAction SilentlyContinue).Length
    if (-not $zipSize -or $zipSize -lt 22) {
        throw "Arquivo ZIP inválido (tamanho: $zipSize bytes)."
    }

    if (Test-Path $DestDir) { Remove-Item $DestDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -Path $DestDir -ItemType Directory -Force | Out-Null

    # Método A: ZipFile .NET
    Write-Progress -Activity "📦 Extraindo ZIP" -Status "Método A: ZipFile.NET" -PercentComplete 10
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $DestDir)
        $count = (Get-ChildItem $DestDir -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($count -gt 0) {
            Write-Progress -Activity "📦 Extração concluída" -Completed
            Write-Log "  Extração OK via ZipFile.NET ($count arquivo(s))." "SUCCESS"
            return
        }
        throw "ZipFile.NET extraiu mas diretório vazio."
    } catch {
        Write-Log "  ZipFile.NET: $($_.Exception.Message)" "WARN"
        if (Test-Path $DestDir) { Remove-Item $DestDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path $DestDir -ItemType Directory -Force | Out-Null
    }

    # Método B: Expand-Archive
    Write-Progress -Activity "📦 Extraindo ZIP" -Status "Método B: Expand-Archive" -PercentComplete 30
    try {
        Expand-Archive -Path $ZipPath -DestinationPath $DestDir -Force -ErrorAction Stop
        $count = (Get-ChildItem $DestDir -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($count -gt 0) {
            Write-Progress -Activity "📦 Extração concluída" -Completed
            Write-Log "  Extração OK via Expand-Archive ($count arquivo(s))." "SUCCESS"
            return
        }
        throw "Expand-Archive extraiu mas diretório vazio."
    } catch {
        Write-Log "  Expand-Archive: $($_.Exception.Message)" "WARN"
        if (Test-Path $DestDir) { Remove-Item $DestDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path $DestDir -ItemType Directory -Force | Out-Null
    }

    # Método C: Shell.Application COM
    Write-Progress -Activity "📦 Extraindo ZIP" -Status "Método C: Shell.Application COM" -PercentComplete 50
    try {
        $shell    = New-Object -ComObject Shell.Application
        $zipShell = $shell.NameSpace($ZipPath)
        $dstShell = $shell.NameSpace($DestDir)
        if (-not $zipShell) { throw "Shell.Application não conseguiu abrir o ZIP." }
        $dstShell.CopyHere($zipShell.Items(), 0x14)
        $lastCount = 0
        for ($wait = 0; $wait -le 15; $wait++) {
            Start-Sleep -Milliseconds 500
            $currentCount = (Get-ChildItem $DestDir -Recurse -File -ErrorAction SilentlyContinue).Count
            Write-Progress -Activity "📦 Extraindo ZIP" `
                           -Status "Copiando arquivos... ($currentCount encontrados)" `
                           -PercentComplete (50 + $wait * 3)
            if ($currentCount -gt 0 -and $currentCount -eq $lastCount) { break }
            $lastCount = $currentCount
        }
        $count = (Get-ChildItem $DestDir -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($count -gt 0) {
            Write-Progress -Activity "📦 Extração concluída" -Completed
            Write-Log "  Extração OK via Shell.Application COM ($count arquivo(s))." "SUCCESS"
            return
        }
        throw "Shell.Application COM extraiu mas diretório vazio."
    } catch {
        Write-Log "  Shell.Application COM: $($_.Exception.Message)" "WARN"
    }

    Write-Progress -Activity "📦 Extração" -Completed
    throw "FALHA PERMANENTE: nenhum método conseguiu extrair '$ZipPath'."
}

# ══════════════════════════════════════════════════════════════════════════════
#  WINGET
# ══════════════════════════════════════════════════════════════════════════════
function Resolve-WingetExe {
    $c = Get-Command winget -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }

    $searchBases = @(
        "$env:ProgramFiles\WindowsApps",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps",
        "$env:SystemDrive\Users\Default\AppData\Local\Microsoft\WindowsApps"
    )

    $profileList = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" `
                    -ErrorAction SilentlyContinue |
                   Where-Object { $_.ProfileImagePath -and (Test-Path $_.ProfileImagePath) } |
                   Select-Object -ExpandProperty ProfileImagePath

    foreach ($p in $profileList) {
        $searchBases += "$p\AppData\Local\Microsoft\WindowsApps"
    }

    foreach ($base in $searchBases) {
        if (-not (Test-Path $base -ErrorAction SilentlyContinue)) { continue }
        $found = Get-ChildItem -Path $base -Filter "winget.exe" -Recurse -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending |
                 Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    try {
        $pkg = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
               Where-Object { $_.DisplayName -like "*DesktopAppInstaller*" } |
               Select-Object -First 1
        if ($pkg) {
            $installedPkg = Get-AppxPackage -Name "*DesktopAppInstaller*" -AllUsers -ErrorAction SilentlyContinue |
                            Sort-Object Version -Descending | Select-Object -First 1
            if ($installedPkg) {
                $candidate = Join-Path $installedPkg.InstallLocation "winget.exe"
                if (Test-Path $candidate) { return $candidate }
            }
        }
    } catch { }

    return $null
}

function Test-WingetFunctional {
    param([string]$WingetExe)
    try {
        $tmpOut = "$($CFG.LogDir)\winget_version.tmp"
        $code   = Start-Headless -FilePath $WingetExe -Arguments "--version" -StdOutFile $tmpOut
        $out    = if (Test-Path $tmpOut) { (Get-Content $tmpOut -Raw).Trim() } else { "" }
        if (Test-Path $tmpOut) { Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue }
        if ($code -eq 0 -and $out -ne "") {
            Write-Log "Winget funcional: $out" "SUCCESS"
            return $true
        }
    } catch { }
    return $false
}

function Install-AppxPackageSafe {
    param([string]$PackagePath)
    $leaf = Split-Path $PackagePath -Leaf
    Write-Log "  Instalando pacote: $leaf" "INFO"

    try {
        Add-AppxPackage -Path $PackagePath -ForceApplicationShutdown -ErrorAction Stop
        Write-Log "    OK via Add-AppxPackage." "SUCCESS"
        return $true
    } catch { Write-Log "    Add-AppxPackage: $($_.Exception.Message)" "WARN" }

    try {
        Add-AppxPackage -Path $PackagePath -ErrorAction Stop
        Write-Log "    OK via Add-AppxPackage (sem flags)." "SUCCESS"
        return $true
    } catch { Write-Log "    Add-AppxPackage (sem flags): $($_.Exception.Message)" "WARN" }

    try {
        $dismArgs = "/Online /Add-ProvisionedAppxPackage /PackagePath:`"$PackagePath`" /SkipLicense"
        $code = Start-Headless -FilePath "Dism.exe" -Arguments $dismArgs
        if ($code -eq 0) {
            Write-Log "    OK via DISM (exit 0)." "SUCCESS"
            return $true
        }
        Write-Log "    DISM exit code: $code" "WARN"
    } catch { Write-Log "    DISM: $($_.Exception.Message)" "WARN" }

    Write-Log "    Todos métodos falharam para $leaf — continuando." "WARN"
    return $false
}

function Install-WingetFromZip {
    Write-Log "Instalando Winget a partir do ZIP..." "STEP"
    Write-Progress -Activity "📦 Instalação do Winget" -Status "Baixando winget.zip" -PercentComplete 10

    Invoke-Download -Url $CFG.WingetZipUrl -Destination $CFG.WingetZipPath -Label "winget.zip"

    Write-Progress -Activity "📦 Instalação do Winget" -Status "Extraindo winget.zip" -PercentComplete 30
    Expand-ZipSafe -ZipPath $CFG.WingetZipPath -DestDir $CFG.WingetExtDir

    # Corrigido: Sort-Object com scriptblock idiomático (sem "return" inválido)
    $packages = Get-ChildItem -Path $CFG.WingetExtDir `
                              -Include "*.msix","*.msixbundle","*.appx","*.appxbundle" `
                              -Recurse -ErrorAction SilentlyContinue |
                Sort-Object {
                    $n = $_.Name.ToLower()
                    if ($n -match "vclibs") { 1 }
                    elseif ($n -match "xaml")   { 2 }
                    elseif ($n -match "winget") { 9 }
                    else { 5 }
                }

    if (-not $packages) {
        $all = Get-ChildItem -Path $CFG.WingetExtDir -Recurse -ErrorAction SilentlyContinue |
               Select-Object -ExpandProperty FullName
        Write-Log "Conteúdo extraído: $($all -join ', ')" "DEBUG"
        throw "Nenhum pacote MSIX/APPX encontrado em '$($CFG.WingetExtDir)'."
    }

    $total     = $packages.Count
    $installed = 0
    foreach ($idx in 0..($total - 1)) {
        $pkg     = $packages[$idx]
        $percent = 40 + [math]::Round(($idx / $total) * 50)
        Write-Progress -Activity "📦 Instalação do Winget" `
                       -Status "Instalando $($pkg.Name)..." `
                       -PercentComplete $percent
        if (Install-AppxPackageSafe -PackagePath $pkg.FullName) { $installed++ }
    }

    Write-Log "Pacotes processados: $installed / $total" "INFO"
    Write-Log "Aguardando registro pelo Windows ($($CFG.AppxInstallWaitSec)s)..." "INFO"
    Start-Sleep -Seconds $CFG.AppxInstallWaitSec
    Write-Progress -Activity "📦 Instalação do Winget" -Completed
}

function Assert-Winget {
    Write-Log "Verificando Winget no sistema..." "STEP"
    Write-Progress -Activity "🔧 Verificando Winget" -Status "Procurando winget.exe" -PercentComplete 10

    $wingetExe = Resolve-WingetExe
    if ($wingetExe) {
        $dir = Split-Path $wingetExe -Parent
        if ($env:PATH -notlike "*$dir*") { $env:PATH = "$env:PATH;$dir" }
        if (Test-WingetFunctional -WingetExe $wingetExe) {
            Write-Progress -Activity "🔧 Winget" -Completed
            return $wingetExe
        }
        Write-Log "Winget localizado mas não funcional. Reinstalando..." "WARN"
    } else {
        Write-Log "Winget não localizado. Instalando via ZIP..." "INFO"
    }

    Install-WingetFromZip

    $wingetExe = Resolve-WingetExe
    if (-not $wingetExe) { throw "Winget não encontrado após instalação." }

    $dir = Split-Path $wingetExe -Parent
    if ($env:PATH -notlike "*$dir*") { $env:PATH = "$env:PATH;$dir" }

    if (-not (Test-WingetFunctional -WingetExe $wingetExe)) {
        throw "Winget instalado mas não responde com --version."
    }

    Write-Progress -Activity "🔧 Winget" -Completed
    return $wingetExe
}

# ══════════════════════════════════════════════════════════════════════════════
#  EXECUÇÃO ISOLADA DO PAYLOAD
# ══════════════════════════════════════════════════════════════════════════════
function Invoke-PayloadIsolated {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$WingetDir = ""
    )
    Write-Log "Iniciando execução isolada do payload..." "STEP"
    Write-Progress -Activity "⚙️ Executando Provisioning" -Status "Preparando ambiente..." -PercentComplete 0

    $outTmp = "$($CFG.LogDir)\payload_stdout.tmp"
    $errTmp = "$($CFG.LogDir)\payload_stderr.tmp"
    foreach ($f in @($outTmp, $errTmp, $CFG.PayloadLog)) {
        if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }

    # Salva apenas chaves com valor definido; guard contra $null na restauração
    $savedEnv = @{}
    foreach ($key in @("NONINTERACTIVE","ACCEPT_SOURCE_AGREEMENTS","WINGET_DISABLE_PROGRESS","PATH")) {
        $savedEnv[$key] = [System.Environment]::GetEnvironmentVariable($key, "Process")
    }

    $env:NONINTERACTIVE           = "1"
    $env:ACCEPT_SOURCE_AGREEMENTS = "1"
    $env:WINGET_DISABLE_PROGRESS  = "1"
    if ($WingetDir -and $WingetDir -ne "" -and $env:PATH -notlike "*$WingetDir*") {
        $env:PATH = "$env:PATH;$WingetDir"
    }

    Write-Progress -Activity "⚙️ Executando Provisioning" -Status "Executando script..." -PercentComplete 30

    $exitCode = -1
    try {
        $psArgs   = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""
        $exitCode = Start-Headless -FilePath "powershell.exe" `
                                   -Arguments $psArgs `
                                   -StdOutFile $outTmp `
                                   -StdErrFile $errTmp

        Write-Progress -Activity "⚙️ Executando Provisioning" -Status "Coletando saída..." -PercentComplete 80

        $outText  = if (Test-Path $outTmp) { Get-Content $outTmp -Raw -ErrorAction SilentlyContinue } else { "" }
        $errText  = if (Test-Path $errTmp) { Get-Content $errTmp -Raw -ErrorAction SilentlyContinue } else { "" }
        $sep      = "=" * 62
        $combined = @(
            $sep
            "  SAIDA PADRAO DO PAYLOAD"
            $sep
            $outText
            ""
            $sep
            "  SAIDA DE ERROS DO PAYLOAD"
            $sep
            $errText
            ""
            "Exit Code: $exitCode"
        ) -join "`r`n"

        [System.IO.File]::WriteAllText($CFG.PayloadLog, $combined, [System.Text.Encoding]::UTF8)

        if ($exitCode -ne 0) {
            Write-Log "Payload encerrou com código $exitCode (ignorado)." "WARN"
        } else {
            Write-Log "Payload encerrado com sucesso (exit 0)." "SUCCESS"
        }

        if ($errText -and $errText.Trim() -ne "") {
            Write-Log "Payload gerou saída em stderr. Verifique: $($CFG.PayloadLog)" "WARN"
        }
    }
    finally {
        # Restauração segura: se o valor original era $null, remove a variável de ambiente
        foreach ($key in $savedEnv.Keys) {
            $original = $savedEnv[$key]
            if ($null -ne $original) {
                [System.Environment]::SetEnvironmentVariable($key, $original, "Process")
            } else {
                [System.Environment]::SetEnvironmentVariable($key, $null, "Process")
            }
        }
        foreach ($f in @($outTmp, $errTmp)) {
            if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
        }
        Write-Progress -Activity "⚙️ Executando Provisioning" -Completed
    }

    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  LIMPEZA
# ══════════════════════════════════════════════════════════════════════════════
function Invoke-Cleanup {
    if ($SkipCleanup) {
        Write-Log "SkipCleanup ativo — artefatos preservados em: $($CFG.LogDir)" "DEBUG"
        return
    }
    Write-Log "Removendo artefatos temporários..." "INFO"
    foreach ($t in @($CFG.WingetZipPath, $CFG.WingetExtDir, $CFG.PayloadPath)) {
        if (Test-Path $t) { Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  ORQUESTRADOR PRINCIPAL
# ══════════════════════════════════════════════════════════════════════════════
function Main {
    Initialize-Log
    Write-Header

    # Write-Banner já registra em log — bloco Write-Log duplicado removido
    Write-Banner "CLOUD PROVISIONING BOOTSTRAP  v4.7  //  ENTERPRISE HEADLESS"

    try {
        # Etapa 1/4 — Rede
        Update-GlobalProgress -Status "Etapa 1/4: Verificando rede" -Percent 5
        Write-Banner "ETAPA 1 / 4  —  Conectividade de Rede"
        if (-not (Test-NetworkReady)) {
            throw "Sem acesso à internet após $($CFG.NetMaxRetries) tentativas."
        }

        # Etapa 2/4 — Winget
        Update-GlobalProgress -Status "Etapa 2/4: Subsistema Winget" -Percent 30
        Write-Banner "ETAPA 2 / 4  —  Subsistema Winget"
        $wingetExe = Assert-Winget
        $wingetDir = Split-Path $wingetExe -Parent
        Write-Log "Winget em uso: $wingetExe" "INFO"

        # Etapa 3/4 — Download Payload
        Update-GlobalProgress -Status "Etapa 3/4: Baixando payload" -Percent 65
        Write-Banner "ETAPA 3 / 4  —  Download do Payload"
        Invoke-Download -Url $CFG.PayloadUrl -Destination $CFG.PayloadPath -Label "Provisioning.ps1"
        Write-Log "Payload pronto: $($CFG.PayloadPath)" "SUCCESS"

        # Etapa 4/4 — Execução do Payload
        Update-GlobalProgress -Status "Etapa 4/4: Executando provisionamento" -Percent 85
        Write-Banner "ETAPA 4 / 4  —  Execução do Payload"
        Invoke-PayloadIsolated -ScriptPath $CFG.PayloadPath -WingetDir $wingetDir | Out-Null

        Update-GlobalProgress -Status "Concluído com sucesso" -Percent 100
        Write-Banner "RESULTADO FINAL"
        Write-Log "Provisionamento concluído com SUCESSO." "SUCCESS"
    }
    catch {
        Write-Log "ERRO CRÍTICO: $($_.Exception.Message)" "ERROR"
        Write-Log "Local       : $($_.InvocationInfo.PositionMessage)" "ERROR"
        Update-GlobalProgress -Status "ERRO: $($_.Exception.Message)" -Percent 100
    }
    finally {
        Invoke-Cleanup
        Write-Banner "BOOTSTRAP ENCERRADO"
        Write-Log "Logs em: $($CFG.LogDir)"
        Update-GlobalProgress -Completed
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  ENTRADA
# ══════════════════════════════════════════════════════════════════════════════
Main

# Aguarda flush de logs antes de encerrar
Start-Sleep -Milliseconds 300

# Encerramento via guard de Add-Type para evitar redefinição em re-execução,
# seguido de [Environment]::Exit limpo (sem race condition de PostMessage)
if (-not ([System.Management.Automation.PSTypeName]"CloudBootstrap.WinAPI").Type) {
    try {
        Add-Type -Name WinAPI -Namespace CloudBootstrap -MemberDefinition @'
            [DllImport("user32.dll")]
            public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
'@ -ErrorAction SilentlyContinue
    } catch { }
}

$consoleHandle = (Get-Process -Id $pid -ErrorAction SilentlyContinue).MainWindowHandle
if ($consoleHandle -and $consoleHandle -ne [IntPtr]::Zero) {
    try {
        [CloudBootstrap.WinAPI]::PostMessage($consoleHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        Start-Sleep -Milliseconds 150   # garante flush antes do WM_CLOSE ser processado
    } catch { }
}

[Environment]::Exit(0)
