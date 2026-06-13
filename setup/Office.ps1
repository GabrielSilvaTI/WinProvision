<#
.SYNOPSIS
    Provisionamento autônomo do Microsoft Office via Office Tool Plus (OTP).

.DESCRIPTION
    Compatível com SetupComplete, FirstLogon, RunOnce e Windows Sandbox.
    Cadeia de fallback de download direto via .NET WebClient (sem depender do IE).
    Instalação com limite de tempo estrito (10 minutos) para I/O.
    Ativação permanente e invisível em memória via Massgrave (Ohook).

.PARAMETER OfficeArgs
    Argumentos para o console do OTP.
    Padrão: Office 365 Home Premium PT-BR, 64-bit, canal Current, silencioso.

.PARAMETER MaxInstallMinutes
    Timeout máximo para a etapa de instalação do Office. Padrão: 10 min.

.NOTES
    Versão : 1.4.0 (Final Enterprise Build)
    Requer : PowerShell 5.1+ / Windows 10 1809+ / .NET 4.5+
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

$Script:Version   = "1.4.0"
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
# REGIÃO 1 — LOGGING
# ══════════════════════════════════════════════════════════════════════════════

function Write-Log {
    param(
        [string]$Msg,
        [ValidateSet("INFO","WARN","ERROR","OK","STEP")][string]$Level = "INFO"
    )
    $ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $prefix = switch ($Level) {
        "OK"    { "[  OK  ]" }
        "WARN"  { "[ WARN ]" }
        "ERROR" { "[ERROR ]" }
        "STEP"  { "[ STEP ]" }
        default { "[ INFO ]" }
    }
    $line = "$ts $prefix $Msg"
    try { Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
    $color = switch ($Level) {
        "OK"    { "Green"  } "WARN"  { "Yellow" }
        "ERROR" { "Red"    } "STEP"  { "Cyan"   }
        default { "Gray"   }
    }
    Write-Host $line -ForegroundColor $color
}

function Assert-Deadline {
    if ((Get-Date) -gt $Script:Deadline) {
        Write-Log "Timeout global atingido. Abortando." "ERROR"
        exit 3
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 2 — PREPARAÇÃO DE DIRETÓRIOS
# ══════════════════════════════════════════════════════════════════════════════

function Initialize-WorkDir {
    Write-Log "Preparando ambiente de trabalho..." "STEP"
    if (Test-Path $Script:WorkDir) {
        try { Remove-Item -Path $Script:WorkDir -Recurse -Force -ErrorAction Stop }
        catch { Write-Log "Aviso ao limpar WorkDir anterior: $_" "WARN" }
    }
    foreach ($dir in @($Script:LogDir, $Script:WorkDir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        catch { Write-Log "Não foi possível criar: $dir — $_" "ERROR"; exit 1 }
    }
    Write-Log "Diretórios prontos." "OK"
}

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 3 — REDE
# ══════════════════════════════════════════════════════════════════════════════

function Wait-Network {
    param([int]$MaxAttempts = 20, [int]$IntervalSec = 4)
    Write-Log "Aguardando conectividade de rede..." "STEP"
    $targets = @("1.1.1.1", "8.8.8.8", "cloudflare.com")
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        foreach ($target in $targets) {
            $tcp = $null
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $ar  = $tcp.BeginConnect($target, 443, $null, $null)
                if ($ar.AsyncWaitHandle.WaitOne(2000, $false) -and $tcp.Connected) {
                    Write-Log "Rede OK via $target." "OK"
                    return $true
                }
            } catch { }
            finally { if ($tcp) { try { $tcp.Close() } catch { } } }
        }
        Write-Log "Tentativa $i/$MaxAttempts sem conectividade. Aguardando ${IntervalSec}s..."
        Start-Sleep -Seconds $IntervalSec
    }
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
    Write-Log "Todas as $MaxRetry tentativas falharam para: $Label" "WARN"
    return $false
}

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 5 — VALIDAÇÃO E EXTRAÇÃO DO ZIP
# ══════════════════════════════════════════════════════════════════════════════

function Expand-OtpZip {
    param([string]$ZipPath, [string]$DestDir)
    Write-Log "Validando ZIP: $(Split-Path $ZipPath -Leaf)..." "STEP"

    try {
        $bytes = [System.IO.File]::ReadAllBytes($ZipPath)
        if ($bytes.Count -lt 4 -or $bytes[0] -ne 0x50 -or $bytes[1] -ne 0x4B) {
            Write-Log "Assinatura ZIP inválida. URL pode ter retornado erro HTTP." "WARN"
            return $false
        }
        Write-Log "ZIP válido (assinatura PK confirmada)." "OK"
    } catch {
        Write-Log "Não foi possível ler o ZIP para validação: $_" "WARN"
        return $false
    }

    Write-Log "Extraindo para: $DestDir" "STEP"
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        if (Test-Path $DestDir) { Remove-Item $DestDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $DestDir)
        $count = (Get-ChildItem $DestDir -Recurse -File).Count
        Write-Log "Extração concluída: $count arquivos." "OK"
        return $true
    } catch {
        Write-Log "Falha na extração: $_" "WARN"
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
# REGIÃO 7 — INSTALAÇÃO DO OFFICE (COM TIMEOUT RIGOROSO)
# ══════════════════════════════════════════════════════════════════════════════

function Install-Office {
    param([string]$ExePath, [string]$Arguments)
    Write-Log "Iniciando instalação silenciosa do Office..." "STEP"
    Write-Log "  Executável : $ExePath"    "INFO"
    Write-Log "  Argumentos : $Arguments"  "INFO"
    Write-Log "  Timeout    : $MaxInstallMinutes min" "INFO"
    
    try {
        $proc = Start-Process -FilePath $ExePath -ArgumentList $Arguments `
                    -WindowStyle Hidden -PassThru -ErrorAction Stop
        
        $timeoutMs = $MaxInstallMinutes * 60 * 1000

        if ($proc.WaitForExit($timeoutMs)) {
            $code = $proc.ExitCode
            switch ($code) {
                0    { Write-Log "Office instalado com sucesso (exit: 0)." "OK" }
                3010 { Write-Log "Office instalado — reinicialização pendente (exit: 3010)." "WARN" }
                default {
                    Write-Log "Instalação concluída com código: $code" "WARN"
                    Write-Log "Ref: https://learn.microsoft.com/office/troubleshoot/installation/error-codes-office-deployment-tool" "INFO"
                }
            }
            return $code
        } else {
            Write-Log "ERRO CRÍTICO: Timeout de $MaxInstallMinutes minutos excedido!" "ERROR"
            Write-Log "Abortando o instalador do Office à força para liberar o sistema..." "WARN"
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
            return 258 
        }
    } catch {
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

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 9 — ORQUESTRADOR DE FALLBACK
# ══════════════════════════════════════════════════════════════════════════════

function Get-OtpFromAnywhere {
    $totalSources = $Script:OtpSources.Count
    for ($i = 0; $i -lt $totalSources; $i++) {
        $source = $Script:OtpSources[$i]
        Write-Log "══ Fonte $($i+1)/$totalSources — $($source.label) ══" "STEP"
        Assert-Deadline

        $exe = switch ($source.type) {
            "zip"        { Invoke-ZipSource       -Source $source }
            "github-api" { Invoke-GitHubApiSource -Source $source }
            default      { Write-Log "Tipo de fonte desconhecido." "WARN"; $null }
        }

        if ($exe) {
            Write-Log "✔ OTP obtido via: $($source.label)" "OK"
            return $exe
        }
        if ($i -lt $totalSources - 1) { Write-Log "  Fonte falhou. Acionando fallback..." "WARN" }
    }
    Write-Log "Todas as $totalSources fontes falharam. Impossível obter o OTP." "ERROR"
    return $null
}

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 10 — ATIVAÇÃO MAS (MASSGRAVE OHOOK)
# ══════════════════════════════════════════════════════════════════════════════

function Invoke-MasActivation {
    Write-Log "Iniciando ativação do Office via MAS (Massgrave / Ohook)..." "STEP"
    try {
        $masScript = $null
        try {
            Write-Log "Baixando payload oficial do MAS..." "INFO"
            $masScript = Invoke-RestMethod -Uri "https://get.activated.win" -UseBasicParsing -ErrorAction Stop
        } catch {
            Write-Log "Falha na rota padrão. Tentando fallback via DoH (DNS over HTTPS)..." "WARN"
            $masScript = curl.exe -s --doh-url https://1.1.1.1/dns-query https://get.activated.win | Out-String
        }

        if ($masScript -and $masScript.Length -gt 1000 -and $masScript -notmatch "(?i)^<!DOCTYPE|^<html") {
            Write-Log "Payload validado com sucesso. Injetando ativador em memória..." "INFO"
            $sb = [scriptblock]::Create($masScript)
            & $sb /Ohook /S
            Write-Log "Ativação MAS (Ohook) concluída com sucesso." "OK"
            return $true
        } else {
            Write-Log "O servidor MAS retornou conteúdo inválido ou bloqueado." "ERROR"
            return $false
        }
    } catch {
        Write-Log "Falha crítica ao orquestrar a execução do MAS: $_" "ERROR"
        return $false
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# REGIÃO 11 — LIMPEZA SELETIVA
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
# EXECUÇÃO PRINCIPAL
# ══════════════════════════════════════════════════════════════════════════════

Write-Log "════════════════════════════════════════════════"
Write-Log " Office Provisioning via OTP  v$Script:Version"
Write-Log " Início   : $($Script:StartTime.ToString('dd/MM/yyyy HH:mm:ss'))"
Write-Log " Fontes   : $($Script:OtpSources.Count) disponíveis (com fallback via GitHub)"
Write-Log " WorkDir  : $Script:WorkDir"
Write-Log " Log      : $Script:LogFile"
Write-Log "════════════════════════════════════════════════"

# 1 — Diretórios
Initialize-WorkDir

# 2 — Rede
if (-not (Wait-Network)) {
    Write-Log "ABORTADO: Sem conectividade." "ERROR"
    exit 1
}

# 3 — Obtém OTP pela cadeia de fallback
$otpExe = Get-OtpFromAnywhere
if (-not $otpExe) {
    Write-Log "ABORTADO: Nenhuma fonte produziu um executável OTP válido." "ERROR"
    Remove-WorkDir -Success $false
    exit 1
}

# 4 — Instala Office
$exitCode = Install-Office -ExePath $otpExe -Arguments $OfficeArgs

# 5 — Ativação MAS (apenas se a instalação foi bem-sucedida ou pendente de reinício)
if ($exitCode -eq 0 -or $exitCode -eq 3010) {
    if (-not (Invoke-MasActivation)) {
        Write-Log "AVISO: A instalação concluiu, mas o script MAS falhou." "WARN"
    }
}

# 6 — Limpeza
$success = ($exitCode -eq 0 -or $exitCode -eq 3010)
Remove-WorkDir -Success $success

# 7 — Resultado
$duration = ((Get-Date) - $Script:StartTime).ToString("mm\:ss")
Write-Log "════════════════════════════════════════════════"
Write-Log " Concluído em $duration min. Código de saída: $exitCode"
Write-Log " Log completo: $Script:LogFile"
Write-Log "════════════════════════════════════════════════"

exit $exitCode
