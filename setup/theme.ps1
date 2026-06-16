<#
.SYNOPSIS
    Personalização do sistema WinProvision.
    Aplica tema escuro e wallpaper (baixado do GitHub) de forma persistente.
.DESCRIPTION
    Compatível com FirstLogon (sessão interativa do usuário).
    Utiliza API nativa SystemParametersInfo para aplicar wallpaper sem reiniciar o Explorer.
    Notifica o shell via WM_SETTINGCHANGE.
    Ao final, reinicia o Explorer para garantir que todas as alterações sejam aplicadas.
.NOTES
    Versão : 2.2.0
        - Download de wallpaper com 3 métodos resilientes (HttpWebRequest, BITS, WebClient)
        - Set-DarkTheme com ordem de chaves garantida ([ordered])
        - Restart-Explorer com verificação real de processo (sem sleep cego)
    Requer : PowerShell 5.1+ / Windows 10 1809+
    Contexto: Funciona em sessão de usuário interativa (não SYSTEM).
#>

param(
    [string]$WallpaperUrl      = "https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/main/assets/Wallpaper%20OEM.png",
    [string]$WallpaperFallback = "C:\Windows\Web\Wallpaper\Windows\img19.jpg"
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

# ── Inicialização ──────────────────────────────────────────────────────────────
function Initialize-Environment {
    $Script:Version          = "2.2.0"
    $Script:StartTime        = Get-Date
    $Script:LogDir           = "$env:SystemRoot\Logs\CloudProvisioning"
    $Script:LogFile          = "$Script:LogDir\Personalization_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $Script:DownloadDir      = "$env:TEMP\WinProvision"
    $Script:LocalWallpaper   = "$Script:DownloadDir\Wallpaper_OEM.png"
    $Script:OEMWallpaperPath = "C:\Windows\Web\Wallpaper\OEM\Wallpaper_OEM.png"

    if (-not (Test-Path $Script:LogDir)) {
        New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
    }
}

# ── Logging ────────────────────────────────────────────────────────────────────
function Write-Log {
    param(
        [string]$Msg,
        [ValidateSet("INFO","WARN","ERROR","OK","STEP")][string]$Level = "INFO"
    )
    $ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $icon   = switch ($Level) {
        "OK"    { "✔️" } "WARN"  { "⚠️" }
        "ERROR" { "❌" } "STEP"  { "▶"  }
        default { "ℹ"  }
    }
    $prefix = switch ($Level) {
        "OK"    { "[  OK  ]" } "WARN"  { "[ WARN ]" }
        "ERROR" { "[ERROR ]" } "STEP"  { "[ STEP ]" }
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
║                  WINPROVISION PERSONALIZATION v$($Script:Version)                    ║
║                         Enterprise Edition                                   ║
╚══════════════════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  👤 Usuário    : $env:USERNAME"                    -ForegroundColor White
    Write-Host "  🖥️  Computador : $env:COMPUTERNAME"               -ForegroundColor White
    Write-Host "  🎨 Tema       : Escuro"                           -ForegroundColor White
    Write-Host "  🖼️  Wallpaper  : OEM (baixado do GitHub)"         -ForegroundColor White
    Write-Host "  🔄 Explorer   : Será reiniciado ao final"         -ForegroundColor White
    Write-Host "  📄 Log        : $Script:LogFile"                  -ForegroundColor White
    Write-Host ""
}

function Write-Banner {
    param([string]$Text)
    $sep = "═" * 62
    Write-Host "`n╔$sep╗" -ForegroundColor Magenta
    Write-Host ("║  " + $Text).PadRight(63) + "║" -ForegroundColor Cyan
    Write-Host "╚$sep╝" -ForegroundColor Magenta
    Write-Log $Text "STEP"
}

# ── Elevação ───────────────────────────────────────────────────────────────────
function Test-IsAdmin {
    $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Admin {
    if (-not (Test-IsAdmin)) {
        Write-Host "🔐 Este script precisa de privilégios de administrador para persistir o wallpaper na pasta OEM." -ForegroundColor Yellow
        Write-Host "⏳ Solicitando elevação..." -ForegroundColor Yellow

        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
                   + " -WallpaperUrl `"$WallpaperUrl`"" `
                   + " -WallpaperFallback `"$WallpaperFallback`""

        Start-Process PowerShell -ArgumentList $arguments -Verb RunAs
        exit 0
    }
}

# ── P/Invoke ───────────────────────────────────────────────────────────────────
function Register-User32Type {
    if (-not ([System.Management.Automation.PSTypeName]"WinProvision.User32").Type) {
        try {
            Add-Type -TypeDefinition @"
                using System;
                using System.Runtime.InteropServices;
                namespace WinProvision {
                    public class User32 {
                        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
                        public static extern bool SystemParametersInfo(
                            uint uiAction,
                            uint uiParam,
                            string pvParam,
                            uint fWinIni
                        );
                        [DllImport("user32.dll", SetLastError = true)]
                        public static extern IntPtr SendMessageTimeout(
                            IntPtr hWnd,
                            uint Msg,
                            UIntPtr wParam,
                            string lParam,
                            uint fuFlags,
                            uint uTimeout,
                            out UIntPtr lpdwResult
                        );
                    }
                }
"@ -ErrorAction Stop
            Write-Log "Tipo WinProvision.User32 registrado." "INFO"
        } catch {
            Write-Log "Falha ao registrar tipo User32: $_" "ERROR"
            throw
        }
    }
}

# ── Etapas ─────────────────────────────────────────────────────────────────────
function Prepare-OEMFolder {
    Write-Banner "PREPARANDO PASTA OEM"
    Write-Progress -Activity "🎨 Personalização" -Status "Criando diretório OEM" -PercentComplete 1

    $oemDir = Split-Path $Script:OEMWallpaperPath -Parent
    if (-not (Test-Path $oemDir)) {
        try {
            New-Item -ItemType Directory -Path $oemDir -Force | Out-Null
            Write-Log "Pasta OEM criada: $oemDir" "OK"
        } catch {
            Write-Log "Falha ao criar pasta OEM: $_" "ERROR"
            Write-Progress -Activity "🎨 Personalização" -Status "Erro ao criar OEM" -PercentComplete 1
            return $false
        }
    } else {
        Write-Log "Pasta OEM já existe." "INFO"
    }

    Write-Progress -Activity "🎨 Personalização" -Status "Pasta OEM pronta" -PercentComplete 5
    return $true
}

function Get-Wallpaper {
    Write-Banner "ETAPA 1/5 — BAIXANDO WALLPAPER DO GITHUB"
    Write-Progress -Activity "🎨 Personalização" -Status "Baixando wallpaper" -PercentComplete 10

    if (-not (Test-Path $Script:DownloadDir)) {
        New-Item -ItemType Directory -Path $Script:DownloadDir -Force | Out-Null
    }
    if (Test-Path $Script:LocalWallpaper) {
        Remove-Item $Script:LocalWallpaper -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Baixando de: $WallpaperUrl" "INFO"

    # Método A: HttpWebRequest (funciona em SYSTEM e sem proxy IE)
    try {
        $req           = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($WallpaperUrl)
        $req.Timeout   = 30000
        $req.Method    = "GET"
        $req.UserAgent = "WinProvision/2.2.0"
        $resp          = $req.GetResponse()
        $stream        = $resp.GetResponseStream()
        $fs            = [System.IO.File]::Open($Script:LocalWallpaper,
                             [System.IO.FileMode]::Create,
                             [System.IO.FileAccess]::Write,
                             [System.IO.FileShare]::None)
        $buf = New-Object byte[] 65536
        do {
            $read = $stream.Read($buf, 0, $buf.Length)
            if ($read -gt 0) { $fs.Write($buf, 0, $read) }
        } while ($read -gt 0)
        $fs.Flush(); $fs.Close()
        $stream.Close(); $resp.Close()

        $size = (Get-Item $Script:LocalWallpaper -ErrorAction SilentlyContinue).Length
        if ($size -gt 0) {
            Write-Log "Download OK via HttpWebRequest ($([Math]::Round($size/1KB,1)) KB)." "OK"
            Write-Progress -Activity "🎨 Personalização" -Status "Wallpaper baixado" -PercentComplete 20
            return $true
        }
        throw "Arquivo vazio após download."
    } catch {
        Write-Log "HttpWebRequest falhou: $_" "WARN"
        if (Test-Path $Script:LocalWallpaper) { Remove-Item $Script:LocalWallpaper -Force -ErrorAction SilentlyContinue }
    }

    # Método B: BITS
    try {
        $bitsCmd = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
        if ($bitsCmd) {
            Start-BitsTransfer -Source $WallpaperUrl -Destination $Script:LocalWallpaper -Priority Foreground -ErrorAction Stop
            $size = (Get-Item $Script:LocalWallpaper -ErrorAction SilentlyContinue).Length
            if ($size -gt 0) {
                Write-Log "Download OK via BITS ($([Math]::Round($size/1KB,1)) KB)." "OK"
                Write-Progress -Activity "🎨 Personalização" -Status "Wallpaper baixado" -PercentComplete 20
                return $true
            }
            throw "BITS gerou arquivo vazio."
        }
    } catch {
        Write-Log "BITS falhou: $_" "WARN"
        if (Test-Path $Script:LocalWallpaper) { Remove-Item $Script:LocalWallpaper -Force -ErrorAction SilentlyContinue }
    }

    # Método C: WebClient
    try {
        $wc                       = New-Object System.Net.WebClient
        $wc.Headers["User-Agent"] = "WinProvision/2.2.0"
        $wc.DownloadFile($WallpaperUrl, $Script:LocalWallpaper)
        $size = (Get-Item $Script:LocalWallpaper -ErrorAction SilentlyContinue).Length
        if ($size -gt 0) {
            Write-Log "Download OK via WebClient ($([Math]::Round($size/1KB,1)) KB)." "OK"
            Write-Progress -Activity "🎨 Personalização" -Status "Wallpaper baixado" -PercentComplete 20
            return $true
        }
        throw "WebClient gerou arquivo vazio."
    } catch {
        Write-Log "WebClient falhou: $_" "WARN"
        if (Test-Path $Script:LocalWallpaper) { Remove-Item $Script:LocalWallpaper -Force -ErrorAction SilentlyContinue }
    }

    Write-Log "Todos os métodos de download falharam. Usando fallback." "ERROR"
    Write-Progress -Activity "🎨 Personalização" -Status "Usando fallback" -PercentComplete 20
    return $false
}

function Install-WallpaperToOEM {
    Write-Banner "ETAPA 2/5 — COPIANDO PARA PASTA OEM"
    Write-Progress -Activity "🎨 Personalização" -Status "Copiando wallpaper para OEM" -PercentComplete 25

    if (-not (Test-Path $Script:LocalWallpaper)) {
        Write-Log "Arquivo temporário não encontrado." "ERROR"
        return $false
    }

    try {
        Copy-Item -Path $Script:LocalWallpaper -Destination $Script:OEMWallpaperPath -Force -ErrorAction Stop
        Write-Log "Wallpaper copiado para $Script:OEMWallpaperPath" "OK"
        Write-Progress -Activity "🎨 Personalização" -Status "Wallpaper em OEM" -PercentComplete 30
        return $true
    } catch {
        Write-Log "Falha ao copiar para OEM: $_" "ERROR"
        Write-Progress -Activity "🎨 Personalização" -Status "Falha na cópia OEM" -PercentComplete 30
        return $false
    }
}

function Set-DarkTheme {
    Write-Banner "ETAPA 3/5 — APLICANDO TEMA ESCURO"
    Write-Progress -Activity "🎨 Personalização" -Status "Aplicando tema escuro" -PercentComplete 35

    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"

    if (-not (Test-Path $regPath)) {
        try {
            New-Item -Path $regPath -Force | Out-Null
            Write-Log "Chave de registro criada: $regPath" "INFO"
        } catch {
            Write-Log "Não foi possível criar chave de registro: $_" "ERROR"
            return $false
        }
    }

    # [ordered] garante ordem de iteração e progresso visual consistente
    $values = [ordered]@{
        "AppsUseLightTheme"    = 0
        "SystemUsesLightTheme" = 0
        "EnableTransparency"   = 1
    }

    $allOk = $true
    $step  = 0
    foreach ($entry in $values.GetEnumerator()) {
        $step++
        Write-Progress -Activity "🎨 Personalização" -Status "Configurando $($entry.Key)" -PercentComplete (35 + ($step * 3))
        try {
            Set-ItemProperty -Path $regPath -Name $entry.Key -Value $entry.Value -Type DWord -ErrorAction Stop
            Write-Log "  $($entry.Key) = $($entry.Value)" "INFO"
        } catch {
            Write-Log "  Falha ao definir $($entry.Key): $_" "WARN"
            $allOk = $false
        }
    }

    if ($allOk) {
        Write-Log "Tema escuro aplicado." "OK"
        Write-Progress -Activity "🎨 Personalização" -Status "Tema escuro OK" -PercentComplete 45
    } else {
        Write-Progress -Activity "🎨 Personalização" -Status "Tema escuro com falhas" -PercentComplete 45
    }
    return $allOk
}

function Set-Wallpaper {
    param([string]$WallpaperFile)
    Write-Banner "ETAPA 4/5 — APLICANDO WALLPAPER"
    Write-Progress -Activity "🎨 Personalização" -Status "Preparando wallpaper" -PercentComplete 50

    if (-not (Test-Path $WallpaperFile)) {
        Write-Log "Wallpaper não encontrado: $WallpaperFile" "WARN"
        $candidates = @(
            "C:\Windows\Web\Wallpaper\Windows\img0.jpg",
            "C:\Windows\Web\Wallpaper\Windows\img19.jpg",
            "C:\Windows\Web\Wallpaper\Theme1\img1.jpg"
        )
        $resolved = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $resolved) {
            Write-Log "Nenhum wallpaper fallback encontrado." "ERROR"
            Write-Progress -Activity "🎨 Personalização" -Status "Falha total no wallpaper" -PercentComplete 60
            return $false
        }
        Write-Log "Usando fallback: $resolved" "WARN"
        $WallpaperFile = $resolved
    } else {
        Write-Log "Wallpaper: $WallpaperFile" "INFO"
    }

    Write-Progress -Activity "🎨 Personalização" -Status "Configurando registro" -PercentComplete 65
    try {
        $regDesktop = "HKCU:\Control Panel\Desktop"
        Set-ItemProperty -Path $regDesktop -Name "Wallpaper"      -Value $WallpaperFile -ErrorAction Stop
        Set-ItemProperty -Path $regDesktop -Name "WallpaperStyle" -Value "10"           -ErrorAction Stop
        Set-ItemProperty -Path $regDesktop -Name "TileWallpaper"  -Value "0"            -ErrorAction Stop
        Write-Log "Caminho persistido no registro." "INFO"
    } catch {
        Write-Log "Aviso ao persistir no registro: $_" "WARN"
    }

    Write-Progress -Activity "🎨 Personalização" -Status "Aplicando via API" -PercentComplete 70
    $result = [WinProvision.User32]::SystemParametersInfo(20, 0, $WallpaperFile, 3)
    if ($result) {
        Write-Log "Wallpaper aplicado com sucesso: $(Split-Path $WallpaperFile -Leaf)" "OK"
        Write-Progress -Activity "🎨 Personalização" -Status "Wallpaper aplicado" -PercentComplete 80
        return $true
    } else {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Log "SystemParametersInfo falhou (Win32 erro: $err)." "WARN"
        Write-Progress -Activity "🎨 Personalização" -Status "Falha na aplicação" -PercentComplete 80
        return $false
    }
}

function Update-Shell {
    Write-Banner "NOTIFICANDO SHELL"
    Write-Progress -Activity "🎨 Personalização" -Status "Notificando Explorer" -PercentComplete 85

    $HWND_BROADCAST   = [IntPtr]0xFFFF
    $WM_SETTINGCHANGE = 0x001A
    $SMTO_ABORTIFHUNG = 0x0002
    $result           = [UIntPtr]::Zero

    Write-Progress -Activity "🎨 Personalização" -Status "Enviando WM_SETTINGCHANGE (tema)" -PercentComplete 88
    [WinProvision.User32]::SendMessageTimeout(
        $HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero,
        "ImmersiveColorSet", $SMTO_ABORTIFHUNG, 2000, [ref]$result
    ) | Out-Null

    Write-Progress -Activity "🎨 Personalização" -Status "Enviando WM_SETTINGCHANGE (wallpaper)" -PercentComplete 90
    [WinProvision.User32]::SendMessageTimeout(
        $HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero,
        "Environment", $SMTO_ABORTIFHUNG, 2000, [ref]$result
    ) | Out-Null

    Write-Log "Shell notificado." "OK"
}

function Restart-Explorer {
    Write-Banner "ETAPA 5/5 — REINICIANDO EXPLORER"
    Write-Progress -Activity "🎨 Personalização" -Status "Encerrando Explorer" -PercentComplete 92

    Write-Log "Encerrando o processo explorer.exe..." "STEP"
    try {
        Stop-Process -Name "explorer" -Force -ErrorAction Stop
        Write-Log "Processo explorer.exe finalizado." "OK"
    } catch {
        Write-Log "Não foi possível encerrar o Explorer (pode já estar parado): $_" "WARN"
    }

    # Aguarda o processo desaparecer antes de reiniciar (máx 5s)
    $waited = 0
    while ((Get-Process -Name "explorer" -ErrorAction SilentlyContinue) -and $waited -lt 10) {
        Start-Sleep -Milliseconds 500
        $waited++
    }

    Write-Progress -Activity "🎨 Personalização" -Status "Iniciando Explorer" -PercentComplete 95
    Write-Log "Iniciando um novo explorer.exe..." "STEP"
    try {
        Start-Process "explorer.exe" -ErrorAction Stop
    } catch {
        Write-Log "Falha ao iniciar o Explorer: $_" "ERROR"
        Write-Progress -Activity "🎨 Personalização" -Status "Erro ao reiniciar Explorer" -PercentComplete 100
        return $false
    }

    # Confirma que o processo subiu (máx 8s)
    $waited = 0
    while (-not (Get-Process -Name "explorer" -ErrorAction SilentlyContinue) -and $waited -lt 16) {
        Start-Sleep -Milliseconds 500
        $waited++
    }

    if (Get-Process -Name "explorer" -ErrorAction SilentlyContinue) {
        Write-Log "Explorer reiniciado com sucesso." "OK"
        Write-Progress -Activity "🎨 Personalização" -Status "Explorer reiniciado" -PercentComplete 98
        return $true
    } else {
        Write-Log "Explorer não subiu dentro do tempo esperado." "WARN"
        Write-Progress -Activity "🎨 Personalização" -Status "Explorer pode não ter subido" -PercentComplete 98
        return $false
    }
}

# ── Encerramento seguro ────────────────────────────────────────────────────────
function Exit-Script {
    param([int]$Code = 0)
    try { $Host.UI.RawUI.FlushInputBuffer() } catch { }
    [Environment]::Exit($Code)
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
Initialize-Environment
Request-Admin
Register-User32Type
Write-Header

Write-Log "════════════════════════════════════════════════"
Write-Log " WinProvision Personalization  v$Script:Version"
Write-Log " Início   : $($Script:StartTime.ToString('dd/MM/yyyy HH:mm:ss'))"
Write-Log " Usuário  : $env:USERNAME"
Write-Log "════════════════════════════════════════════════"

$oemReady   = Prepare-OEMFolder
$downloadOk = Get-Wallpaper

if ($downloadOk -and $oemReady) {
    $copied        = Install-WallpaperToOEM
    $wallpaperFile = if ($copied) { $Script:OEMWallpaperPath } else {
        Write-Log "Falha ao copiar para OEM, utilizando fallback." "WARN"
        $WallpaperFallback
    }
} else {
    $wallpaperFile = $WallpaperFallback
}

$themeOk           = Set-DarkTheme
$wallpaperOk       = Set-Wallpaper -WallpaperFile $wallpaperFile
Update-Shell
$explorerRestarted = Restart-Explorer

$duration = ((Get-Date) - $Script:StartTime).ToString("mm\:ss")

Write-Host "`n╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                              RESUMO FINAL                                     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Log "════════════════════════════════════════════════"
Write-Log " Tempo total        : $duration min"
Write-Log " Tema escuro        : $(if ($themeOk)           { 'Aplicado' } else { 'Falha' })"
Write-Log " Wallpaper          : $(if ($wallpaperOk)       { 'Aplicado' } else { 'Falha' })"
Write-Log " Explorer reiniciado: $(if ($explorerRestarted) { 'Sim'      } else { 'Não'   })"
Write-Log " Log completo       : $Script:LogFile"
Write-Log "════════════════════════════════════════════════"

if ($themeOk -and $wallpaperOk -and $explorerRestarted) {
    Write-Host "`n✅ Personalização concluída com sucesso! Explorer reiniciado." -ForegroundColor Green
} elseif ($themeOk -and $wallpaperOk) {
    Write-Host "`n⚠️ Personalização concluída, mas houve problema ao reiniciar o Explorer. Tente reiniciar manualmente." -ForegroundColor Yellow
} else {
    Write-Host "`n⚠️ Personalização concluída com falhas parciais. Verifique o log." -ForegroundColor Yellow
}

Write-Host "`n⏱️  Aguardando 3 segundos antes de fechar...`n" -ForegroundColor Gray
Start-Sleep -Seconds 3
Exit-Script -Code 0
