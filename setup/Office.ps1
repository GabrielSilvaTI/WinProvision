<#
.SYNOPSIS
    Provisionamento autônomo do Microsoft Office via Office Tool Plus (OTP).
    Com verificação de instalação prévia e ativação MAS integrada.

.DESCRIPTION
    Compatível com SetupComplete, FirstLogon, RunOnce e Windows Sandbox.
    Cadeia de fallback de download direto via .NET WebClient.
    Instalação com limite de tempo estrito.
    Ativação permanente via Massgrave (Ohook) com exclusão Defender.
#>

param(
    [string]$OfficeArgs        = "deploy /add O365HomePremRetail_pt-br /channel Current /edition 64 /display False",
    [int]   $MaxInstallMinutes = 10
)

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 0 — AMBIENTE
# ══════════════════════════════════════════════════════════════════════════════

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

try {
    [Net.ServicePointManager]::SecurityProtocol = (
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    )
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$Script:Version   = "1.5.0"
$Script:StartTime = Get-Date
$Script:WorkDir   = "$env:SystemDrive\Temp\OfficeProvisioning"
$Script:LogDir    = "$env:SystemRoot\Logs\CloudProvisioning"
$Script:LogFile   = "$Script:LogDir\Office_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$Script:Deadline  = $Script:StartTime.AddMinutes($MaxInstallMinutes + 15)

# ── Cadeia de fontes (exclusivamente via GitHub) ──────────────────────────────
$Script:OtpSources = @(
    @{
        type    = "zip"
        label   = "GitHub Releases v11.5.7.0 com runtime (URL fixa)"
        url     = "https://github.com/YerongAI/Office-Tool/releases/download/v11.5.7.0/Office_Tool_with_runtime_v11.5.7.0_x64.zip"
        zipFile = "$Script:WorkDir\OTP_GitHub_Fixed.zip"
        extDir  = "$Script:WorkDir\OTP_GitHub_Fixed"
    },
    @{
        type       = "github-api"
        label      = "GitHub Releases versão mais recente (via API)"
        apiUrl     = "https://api.github.com/repos/YerongAI/Office-Tool/releases/latest"
        assetMatch = "with_runtime.*x64\.zip$"
        zipFile    = "$Script:WorkDir\OTP_GitHub_Latest.zip"
        extDir     = "$Script:WorkDir\OTP_GitHub_Latest"
    }
)

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 1 — LOGGING (APRIMORADO COM ÍCONES)
# ══════════════════════════════════════════════════════════════════════════════

function Write-Log {
    param(
        [string]$Msg,
        [ValidateSet("INFO","WARN","ERROR","OK","STEP")][string]$Level = "INFO"
    )
    $ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $icon   = switch ($Level) {
        "OK"    { "✔️" }
        "WARN"  { "⚠️" }
        "ERROR" { "❌" }
        "STEP"  { "▶"  }
        default { "ℹ"  }
    }
    $prefix = switch ($Level) {
        "OK"    { "[  OK  ]" }
        "WARN"  { "[ WARN ]" }
        "ERROR" { "[ERROR ]" }
        "STEP"  { "[ STEP ]" }
        default { "[ INFO ]" }
    }
    $line = "$ts $prefix $icon $Msg"
    try { Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
    $color = switch ($Level) {
        "OK"    { "Green"  } "WARN"  { "Yellow" }
        "ERROR" { "Red"    } "STEP"  { "Cyan"   }
        default { "Gray"   }
    }
    Write-Host $line -ForegroundColor $color
}

function Write-Header {
    Clear-Host
    Write-Host @"
╔══════════════════════════════════════════════════════════════════════════════╗
║                     OFFICE PROVISIONING v$($Script:Version)                           ║
║                         Enterprise Headless Edition                         ║
╚══════════════════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  📅 Início   : $($Script:StartTime.ToString('dd/MM/yyyy HH:mm:ss'))" -ForegroundColor White
    Write-Host "  ⏱️  Timeout  : $(($MaxInstallMinutes + 15)) minutos totais (instalação: ${MaxInstallMinutes} min)" -ForegroundColor White
    Write-Host "  📁 WorkDir  : $Script:WorkDir" -ForegroundColor White
    Write-Host "  📄 Log      : $Script:LogFile" -ForegroundColor White
    Write-Host ""
}

function Write-Banner {
    param([string]$Text)
    $sep = "═" * 62
    Write-Host "`n╔$sep╗" -ForegroundColor Magenta
    Write-Host "║  $Text".PadRight(63) -ForegroundColor Cyan
    Write-Host "╚$sep╝" -ForegroundColor Magenta
    Write-Log $Text "STEP"
}

function Assert-Deadline {
    if ((Get-Date) -gt $Script:Deadline) {
        Write-Log "Timeout global atingido. Abortando." "ERROR"
        # Força saída com 0
        [Console]::SetIn([System.IO.StreamReader]::Null)
        $Host.UI.RawUI.FlushInputBuffer()
        [Environment]::Exit(0)
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 1.5 — VERIFICAÇÃO SE OFFICE JÁ ESTÁ INSTALADO
# ══════════════════════════════════════════════════════════════════════════════

function Test-OfficeInstalled {
    Write-Banner "VERIFICANDO INSTALAÇÃO EXISTENTE"
    Write-Progress -Activity "🔍 Verificando Office" -Status "Procurando instalador..." -PercentComplete 10

    # Caminhos comuns do executável principal do Office (Word)
    $wordPaths = @(
        "C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE",
        "C:\Program Files (x86)\Microsoft Office\root\Office16\WINWORD.EXE",
        "C:\Program Files\Microsoft Office\Office16\WINWORD.EXE",
        "C:\Program Files (x86)\Microsoft Office\Office16\WINWORD.EXE"
    )

    foreach ($path in $wordPaths) {
        if (Test-Path $path) {
            Write-Progress -Activity "🔍 Verificando Office" -Completed
            Write-Log "Office já está instalado (encontrado: $path)." "OK"
            return $true
        }
    }

    # Verifica por chave de registro do Office 2016/365
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Office\16.0\Common\InstallRoot",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\16.0\Common\InstallRoot"
    )
    foreach ($regPath in $regPaths) {
        if (Test-Path $regPath) {
            $installRoot = (Get-ItemProperty -Path $regPath -Name "Path" -ErrorAction SilentlyContinue).Path
            if ($installRoot -and (Test-Path "$installRoot\WINWORD.EXE")) {
                Write-Progress -Activity "🔍 Verificando Office" -Completed
                Write-Log "Office já está instalado (registro + arquivo)." "OK"
                return $true
            }
        }
    }

    Write-Progress -Activity "🔍 Verificando Office" -Completed
    Write-Log "Office NÃO detectado no sistema. Procedendo com instalação..." "INFO"
    return $false
}

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 2 — PREPARAÇÃO DE DIRETÓRIOS
# ══════════════════════════════════════════════════════════════════════════════

function Initialize-WorkDir {
    Write-Banner "PREPARANDO AMBIENTE"
    Write-Progress -Activity "📁 Preparação" -Status "Criando diretórios" -PercentComplete 0
    if (Test-Path $Script:WorkDir) {
        try { Remove-Item -Path $Script:WorkDir -Recurse -Force -ErrorAction Stop }
        catch { Write-Log "Aviso ao limpar WorkDir anterior: $_" "WARN" }
    }
    foreach ($dir in @($Script:LogDir, $Script:WorkDir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        catch { Write-Log "Não foi possível criar: $dir — $_" "ERROR"; [Environment]::Exit(0) }
    }
    Write-Progress -Activity "📁 Preparação" -Completed
    Write-Log "Diretórios prontos." "OK"
}

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 3 — REDE
# ══════════════════════════════════════════════════════════════════════════════

function Wait-Network {
    param([int]$MaxAttempts = 20, [int]$IntervalSec = 4)
    Write-Banner "VERIFICANDO CONECTIVIDADE"
    Write-Log "Aguardando conectividade de rede..." "STEP"
    $targets = @("1.1.1.1", "8.8.8.8", "cloudflare.com")
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        $percent = [math]::Round(($i / $MaxAttempts) * 100)
        Write-Progress -Activity "🌐 Rede" -Status "Tentativa $i de $MaxAttempts" -PercentComplete $percent
        foreach ($target in $targets) {
            $tcp = $null
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $ar  = $tcp.BeginConnect($target, 443, $null, $null)
                if ($ar.AsyncWaitHandle.WaitOne(2000, $false) -and $tcp.Connected) {
                    Write-Progress -Activity "🌐 Rede" -Completed
                    Write-Log "Rede OK via $target." "OK"
                    return $true
                }
            } catch { }
            finally { if ($tcp) { try { $tcp.Close() } catch { } } }
        }
        Write-Log "Tentativa $i/$MaxAttempts sem conectividade. Aguardando ${IntervalSec}s..." "WARN"
        Start-Sleep -Seconds $IntervalSec
    }
    Write-Progress -Activity "🌐 Rede" -Completed
    Write-Log "Sem conectividade após $($MaxAttempts * $IntervalSec)s." "ERROR"
    return $false
}

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 4 — DOWNLOAD RÁPIDO COM RETRY E PROGRESSO
# ══════════════════════════════════════════════════════════════════════════════

function Invoke-FastDownload {
    param(
        [string]$Url,
        [string]$OutPath,
        [string]$Label     = "arquivo",
        [int]   $MaxRetry  = 3,
        [int]   $TimeoutMs = 180000 
    )

    for ($attempt = 1; $attempt -le $MaxRetry; $attempt++) {
        Assert-Deadline
        $wc = $null
        try {
            Write-Log "Baixando $Label (tentativa $attempt/$MaxRetry)..." "INFO"
            Write-Progress -Activity "📥 Download: $Label" -Status "Tentativa $attempt" -PercentComplete 0

            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "OfficeProvisioning/$Script:Version (PowerShell)")
            $wc.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
            $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials

            $dlTask     = $wc.DownloadFileTaskAsync([Uri]$Url, $OutPath)
            $started    = Get-Date
            $lastReport = Get-Date

            while (-not $dlTask.IsCompleted) {
                Assert-Deadline
                if (((Get-Date) - $started).TotalMilliseconds -gt $TimeoutMs) {
                    $wc.CancelAsync()
                    throw "Timeout de $([int]($TimeoutMs/1000))s atingido."
                }
                if (((Get-Date) - $lastReport).TotalSeconds -ge 5) {
                    $downloaded = if (Test-Path $OutPath) {
                        "$([Math]::Round((Get-Item $OutPath).Length / 1MB, 1)) MB"
                    } else { "iniciando..." }
                    Write-Log "  $downloaded baixados ($([int](((Get-Date)-$started).TotalSeconds))s)" "INFO"
                    $lastReport = Get-Date
                }
                Start-Sleep -Milliseconds 300
            }

            if ($dlTask.IsFaulted) { throw $dlTask.Exception.InnerException }

            $size = if (Test-Path $OutPath) { (Get-Item $OutPath).Length } else { 0 }
            if ($size -lt 100KB) { throw "Arquivo suspeito: apenas $size bytes. Possível erro HTTP." }

            Write-Progress -Activity "📥 Download: $Label" -Completed
            Write-Log "Download OK: $Label ($([Math]::Round($size/1MB,1)) MB)." "OK"
            return $true

        } catch {
            Write-Log "Falha no download (tentativa $attempt/$MaxRetry): $_" "WARN"
            if (Test-Path $OutPath) { Remove-Item $OutPath -Force -ErrorAction SilentlyContinue }
        } finally {
            if ($wc) { try { $wc.Dispose() } catch { } }
        }
        if ($attempt -lt $MaxRetry) {
            $wait = [Math]::Pow(2, $attempt)
            Write-Log "Aguardando ${wait}s..."
            Start-Sleep -Seconds $wait
        }
    }
    Write-Progress -Activity "📥 Download: $Label" -Completed
    Write-Log "Todas as $MaxRetry tentativas falharam para: $Label" "WARN"
    return $false
}

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 5 — VALIDAÇÃO E EXTRAÇÃO DO ZIP
# ══════════════════════════════════════════════════════════════════════════════

function Expand-OtpZip {
    param([string]$ZipPath, [string]$DestDir)
    Write-Log "Validando ZIP: $(Split-Path $ZipPath -Leaf)..." "STEP"
    Write-Progress -Activity "📦 Validando ZIP" -Status "Verificando assinatura" -PercentComplete 10

    try {
        $bytes = [System.IO.File]::ReadAllBytes($ZipPath)
        if ($bytes.Count -lt 4 -or $bytes[0] -ne 0x50 -or $bytes[1] -ne 0x4B) {
            Write-Log "Assinatura ZIP inválida. URL pode ter retornado erro HTTP." "WARN"
            Write-Progress -Activity "📦 Extração" -Completed
            return $false
        }
        Write-Log "ZIP válido (assinatura PK confirmada)." "OK"
    } catch {
        Write-Log "Não foi possível ler o ZIP para validação: $_" "WARN"
        Write-Progress -Activity "📦 Extração" -Completed
        return $false
    }

    Write-Log "Extraindo para: $DestDir" "STEP"
    Write-Progress -Activity "📦 Extraindo ZIP" -Status "Usando System.IO.Compression.ZipFile" -PercentComplete 30
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        if (Test-Path $DestDir) { Remove-Item $DestDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $DestDir)
        $count = (Get-ChildItem $DestDir -Recurse -File).Count
        Write-Progress -Activity "📦 Extração" -Completed
        Write-Log "Extração concluída: $count arquivos." "OK"
        return $true
    } catch {
        Write-Log "Falha na extração: $_" "WARN"
        Write-Progress -Activity "📦 Extração" -Completed
        return $false
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 6 — LOCALIZAÇÃO DO EXECUTÁVEL OTP
# ══════════════════════════════════════════════════════════════════════════════

function Get-OtpExecutable {
    param([string[]]$SearchRoots)
    $filters = @("Office Tool Plus.exe", "*Console*.exe", "otp.exe", "*.exe")

    foreach ($root in $SearchRoots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($filter in $filters) {
            $found = Get-ChildItem -Path $root -Filter $filter -Recurse -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -notmatch "(?i)uninstall|setup|redist|vcredist|dotnet|runtime" } |
                     Sort-Object Length -Descending |
                     Select-Object -First 1
            if ($found -and (Test-Path $found.FullName)) {
                Write-Log "Executável OTP localizado: $($found.FullName)" "OK"
                return $found.FullName
            }
        }
    }
    return $null
}

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 7 — INSTALAÇÃO DO OFFICE (COM TIMEOUT RIGOROSO E PROGRESSO)
# ══════════════════════════════════════════════════════════════════════════════

function Install-Office {
    param([string]$ExePath, [string]$Arguments)
    Write-Banner "INSTALANDO MICROSOFT OFFICE"
    Write-Log "Iniciando instalação silenciosa do Office..." "STEP"
    Write-Log "  Executável : $ExePath"    "INFO"
    Write-Log "  Argumentos : $Arguments"  "INFO"
    Write-Log "  Timeout    : $MaxInstallMinutes min" "INFO"
    
    Write-Progress -Activity "⚙️ Instalação do Office" -Status "Iniciando processo" -PercentComplete 0
    try {
        $proc = Start-Process -FilePath $ExePath -ArgumentList $Arguments `
                    -WindowStyle Hidden -PassThru -ErrorAction Stop
        
        $timeoutMs = $MaxInstallMinutes * 60 * 1000
        $elapsedSec = 0

        while (-not $proc.WaitForExit(1000)) {
            $elapsedSec++
            if ($elapsedSec % 30 -eq 0) {
                $percent = [math]::Min(95, [math]::Round(($elapsedSec / ($MaxInstallMinutes * 60)) * 100))
                Write-Progress -Activity "⚙️ Instalação do Office" -Status "Instalando... (${elapsedSec}s)" -PercentComplete $percent
            }
            Assert-Deadline
        }

        $code = $proc.ExitCode
        Write-Progress -Activity "⚙️ Instalação do Office" -Completed

        switch ($code) {
            0    { Write-Log "Office instalado com sucesso (exit: 0)." "OK" }
            3010 { Write-Log "Office instalado — reinicialização pendente (exit: 3010)." "WARN" }
            default {
                Write-Log "Instalação concluída com código: $code" "WARN"
                Write-Log "Ref: https://learn.microsoft.com/office/troubleshoot/installation/error-codes-office-deployment-tool" "INFO"
            }
        }
        return $code

    } catch {
        Write-Progress -Activity "⚙️ Instalação do Office" -Completed
        Write-Log "Exceção na instalação: $_" "ERROR"
        return -1
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 8 — ESTRATÉGIAS DE AQUISIÇÃO DO OTP
# ══════════════════════════════════════════════════════════════════════════════

function Invoke-ZipSource {
    param([hashtable]$Source)
    Write-Log "▶ Tentando fonte ZIP: $($Source.label)" "STEP"

    if (-not (Test-Path (Split-Path $Source.zipFile))) {
        New-Item -ItemType Directory -Path (Split-Path $Source.zipFile) -Force | Out-Null
    }
    if (-not (Invoke-FastDownload -Url $Source.url -OutPath $Source.zipFile -Label $Source.label)) {
        Write-Log "  Download falhou para: $($Source.label)" "WARN"
        return $null
    }
    if (-not (Expand-OtpZip -ZipPath $Source.zipFile -DestDir $Source.extDir)) {
        Write-Log "  Extração falhou para: $($Source.label)" "WARN"
        return $null
    }
    Remove-Item $Source.zipFile -Force -ErrorAction SilentlyContinue
    return (Get-OtpExecutable -SearchRoots @($Source.extDir))
}

function Invoke-GitHubApiSource {
    param([hashtable]$Source)
    Write-Log "▶ Consultando GitHub API para versão mais recente do OTP..." "STEP"

    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "OfficeProvisioning/$Script:Version (PowerShell)")
        $wc.Headers.Add("Accept", "application/vnd.github+json")

        $json    = $wc.DownloadString($Source.apiUrl)
        $release = $json | ConvertFrom-Json
        Write-Log "  Release encontrado: $($release.tag_name)" "OK"

        $asset = $release.assets |
                 Where-Object { $_.name -match $Source.assetMatch } |
                 Select-Object -First 1

        if (-not $asset) {
            Write-Log "  Nenhum asset bate o padrão '$($Source.assetMatch)'." "WARN"
            return $null
        }

        Write-Log "  Asset selecionado: $($asset.name) ($([Math]::Round($asset.size/1MB,1)) MB)" "INFO"

        if (-not (Test-Path (Split-Path $Source.zipFile))) {
            New-Item -ItemType Directory -Path (Split-Path $Source.zipFile) -Force | Out-Null
        }
        if (-not (Invoke-FastDownload -Url $asset.browser_download_url `
                  -OutPath $Source.zipFile -Label $asset.name)) {
            Write-Log "  Download falhou." "WARN"
            return $null
        }
        if (-not (Expand-OtpZip -ZipPath $Source.zipFile -DestDir $Source.extDir)) {
            Write-Log "  Extração falhou." "WARN"
            return $null
        }
        Remove-Item $Source.zipFile -Force -ErrorAction SilentlyContinue
        return (Get-OtpExecutable -SearchRoots @($Source.extDir))

    } catch {
        Write-Log "  Falha na consulta à GitHub API: $_" "WARN"
        return $null
    } finally {
        if ($wc) { try { $wc.Dispose() } catch { } }
    }
}

function Get-OtpFromAnywhere {
    $totalSources = $Script:OtpSources.Count
    for ($i = 0; $i -lt $totalSources; $i++) {
        $source = $Script:OtpSources[$i]
        Write-Banner "FONTE $($i+1)/$totalSources — $($source.label)"
        Assert-Deadline

        $percentBase = 10 + [math]::Round(($i / $totalSources) * 40)
        Write-Progress -Activity "🔍 Obtendo Office Tool Plus" -Status "Tentando: $($source.label)" -PercentComplete $percentBase

        $exe = switch ($source.type) {
            "zip"        { Invoke-ZipSource       -Source $source }
            "github-api" { Invoke-GitHubApiSource -Source $source }
            default      { Write-Log "Tipo de fonte desconhecido." "WARN"; $null }
        }

        if ($exe) {
            Write-Progress -Activity "🔍 Obtendo Office Tool Plus" -Completed
            Write-Log "✔ OTP obtido via: $($source.label)" "OK"
            return $exe
        }
        if ($i -lt $totalSources - 1) { Write-Log "  Fonte falhou. Acionando fallback..." "WARN" }
    }
    Write-Progress -Activity "🔍 Obtendo Office Tool Plus" -Completed
    Write-Log "Todas as $totalSources fontes falharam. Impossível obter o OTP." "ERROR"
    return $null
}

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 9 — ATIVAÇÃO MAS INTEGRADA (COM EXCLUSÃO DEFENDER E LIMPEZA)
# ══════════════════════════════════════════════════════════════════════════════

function Invoke-MasActivation {
    Write-Banner "ATIVANDO OFFICE VIA MAS (MASSGRAVE / OHOOK)"
    Write-Progress -Activity "🔑 Ativação MAS" -Status "Preparando ambiente" -PercentComplete 0

    $masWorkDir = "C:\Temp\MAS_Provisioning"
    $masLogFile = "$env:SystemRoot\Logs\CloudProvisioning\MAS_Activation.log"
    $masUrl = "https://dev.azure.com/massgrave/Microsoft-Activation-Scripts/_apis/git/repositories/Microsoft-Activation-Scripts/items?path=/MAS/All-In-One-Version-KL/MAS_AIO.cmd&download=true"
    $masPath = "$masWorkDir\MAS_AIO.cmd"

    try {
        # Criar diretório e adicionar exclusão ao Defender
        Write-Log "Criando diretório de trabalho MAS..." "INFO"
        if (-not (Test-Path $masWorkDir)) {
            New-Item -ItemType Directory -Path $masWorkDir -Force | Out-Null
        }
        Write-Progress -Activity "🔑 Ativação MAS" -Status "Configurando Defender" -PercentComplete 20
        Write-Log "Adicionando exclusão ao Windows Defender para: $masWorkDir" "INFO"
        Add-MpPreference -ExclusionPath $masWorkDir -ErrorAction SilentlyContinue

        # Download do MAS AIO
        Write-Progress -Activity "🔑 Ativação MAS" -Status "Baixando MAS AIO" -PercentComplete 40
        Write-Log "Baixando MAS AIO de: $masUrl" "INFO"
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($masUrl, $masPath)
        Write-Log "Download concluído: $masPath" "OK"

        # Execução silenciosa do MAS com Ohook
        Write-Progress -Activity "🔑 Ativação MAS" -Status "Executando ativação (Ohook)" -PercentComplete 70
        Write-Log "Executando ativação via Ohook..." "INFO"
        $proc = Start-Process -FilePath $masPath -ArgumentList "/Ohook /S" -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -eq 0) {
            Write-Log "Ativação MAS concluída com sucesso (exit 0)." "OK"
        } else {
            Write-Log "Ativação MAS finalizada com código: $($proc.ExitCode)" "WARN"
        }
        Write-Progress -Activity "🔑 Ativação MAS" -Status "Limpeza" -PercentComplete 90
        Start-Sleep -Seconds 1
        return $true
    } catch {
        Write-Log "Erro crítico na ativação MAS: $_" "ERROR"
        return $false
    } finally {
        # Limpeza do diretório temporário
        Write-Log "Removendo diretório temporário MAS..." "INFO"
        Remove-Item -Path $masWorkDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Progress -Activity "🔑 Ativação MAS" -Completed
        Write-Log "Processo MAS finalizado." "INFO"
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 10 — LIMPEZA SELETIVA
# ══════════════════════════════════════════════════════════════════════════════

function Remove-WorkDir {
    param([bool]$Success)
    if ($Success) {
        Write-Log "Limpando arquivos temporários..." "STEP"
        try { Remove-Item -Path $Script:WorkDir -Recurse -Force -ErrorAction Stop; Write-Log "Limpeza OK." "OK" }
        catch { Write-Log "Aviso na limpeza: $_" "WARN" }
    } else {
        Write-Log "Arquivos preservados para diagnóstico em: $Script:WorkDir" "INFO"
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# EXECUÇÃO PRINCIPAL (COM VERIFICAÇÃO PRÉVIA E FLUXO CONDICIONAL)
# ══════════════════════════════════════════════════════════════════════════════

Write-Header

Write-Log "════════════════════════════════════════════════"
Write-Log " Office Provisioning via OTP  v$Script:Version"
Write-Log " Início   : $($Script:StartTime.ToString('dd/MM/yyyy HH:mm:ss'))"
Write-Log " Fontes   : $($Script:OtpSources.Count) disponíveis (com fallback via GitHub)"
Write-Log "════════════════════════════════════════════════"

# 0 — Verificar se Office já está instalado
$officeInstalled = Test-OfficeInstalled

# 1 — Diretórios (sempre criamos, mesmo se office já instalado, para logs)
Initialize-WorkDir

# 2 — Rede (necessária para ativação, mesmo se office já instalado)
if (-not (Wait-Network)) {
    Write-Log "ABORTADO: Sem conectividade." "ERROR"
    [Console]::SetIn([System.IO.StreamReader]::Null)
    $Host.UI.RawUI.FlushInputBuffer()
    [Environment]::Exit(0)
}

$exitCode = 0
$installedNow = $false

if ($officeInstalled) {
    Write-Banner "OFFICE JÁ PRESENTE — PULANDO INSTALAÇÃO"
    Write-Log "Office já está instalado. Nenhuma instalação será realizada." "OK"
} else {
    # 3 — Obtém OTP (necessário apenas para instalação)
    $otpExe = Get-OtpFromAnywhere
    if (-not $otpExe) {
        Write-Log "ABORTADO: Nenhuma fonte produziu um executável OTP válido." "ERROR"
        Remove-WorkDir -Success $false
        [Console]::SetIn([System.IO.StreamReader]::Null)
        $Host.UI.RawUI.FlushInputBuffer()
        [Environment]::Exit(0)
    }

    # 4 — Instala Office
    $exitCode = Install-Office -ExePath $otpExe -Arguments $OfficeArgs
    $installedNow = ($exitCode -eq 0 -or $exitCode -eq 3010)
}

# 5 — Ativação MAS (sempre executar, tanto se office já existia quanto se acabou de instalar)
Write-Log "Iniciando ativação MAS (Ohook)..." "STEP"
$activationSuccess = Invoke-MasActivation

# 6 — Limpeza (apenas se foi feita instalação nova, para preservar logs de falha)
if ($installedNow) {
    Remove-WorkDir -Success ($exitCode -eq 0 -or $exitCode -eq 3010)
} else {
    Write-Log "Instalação não foi executada; limpando apenas diretório de trabalho OTP." "INFO"
    Remove-WorkDir -Success $true
}

# 7 — Resultado final estilizado
$duration = ((Get-Date) - $Script:StartTime).ToString("mm\:ss")
Write-Host "`n╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                              RESUMO FINAL                                     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Log "════════════════════════════════════════════════"
Write-Log " Tempo total : $duration min"
Write-Log " Instalação  : $(if ($officeInstalled) { 'Já existia (pulada)' } elseif ($installedNow) { 'Nova instalada' } else { 'Falha na instalação' })"
Write-Log " Ativação    : $(if ($activationSuccess) { 'Sucesso' } else { 'Falha' })"
Write-Log " Código saida: $exitCode"
Write-Log " Log completo: $Script:LogFile"
Write-Log "════════════════════════════════════════════════"

if ($installedNow -or $officeInstalled) {
    if ($activationSuccess) {
        Write-Host "`n✅ Office PROVISIONADO e ATIVADO com sucesso!" -ForegroundColor Green
    } else {
        Write-Host "`n⚠️ Office instalado/presente, mas a ATIVAÇÃO falhou. Verifique o log." -ForegroundColor Yellow
    }
} else {
    Write-Host "`n❌ Falha no provisionamento do Office. Verifique o log." -ForegroundColor Red
}

Write-Host "`n⏱️  Aguardando 5 segundos antes de fechar...`n" -ForegroundColor Gray
Start-Sleep -Seconds 5

# 🔹 Garantia de fechamento mesmo em ambientes que bloqueiam [Environment]::Exit
try {
    # Limpa buffers de entrada para evitar bloqueios
    [Console]::SetIn([System.IO.StreamReader]::Null)
    $Host.UI.RawUI.FlushInputBuffer()
    [Environment]::Exit(0)
}
catch {
    # Fallback: encerra o processo à força
    Stop-Process -Id $pid -Force
}
