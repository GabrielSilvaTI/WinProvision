<#
.SYNOPSIS
    Personalização do sistema WinProvision.
    Aplica tema escuro e wallpaper (baixado do GitHub) de forma persistente.

.DESCRIPTION
    Compatível com FirstLogon (sessão interativa do usuário).
    Utiliza API nativa SystemParametersInfo para aplicar wallpaper sem reiniciar o Explorer.
    Notifica o shell via WM_SETTINGCHANGE.
    Ao final, reinicia o Explorer para garantir que todas as alterações sejam aplicadas.

.PARAMETER WallpaperUrl
    URL do wallpaper a ser baixado (raw do GitHub).

.PARAMETER WallpaperFallback
    Caminho do wallpaper fallback caso o download falhe.

.NOTES
    Versão : 1.3.0 (com restart do Explorer)
    Requer : PowerShell 5.1+ / Windows 10 1809+
    Contexto: Funciona em sessão de usuário interativa (não SYSTEM).
#>

param(
    [string]$WallpaperUrl = "https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/main/assets/Wallpaper%20OEM.png",
    [string]$WallpaperFallback = "C:\Windows\Web\Wallpaper\Windows\img19.jpg"
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

$Script:Version   = "1.3.0"
$Script:StartTime = Get-Date
$Script:LogDir    = "$env:SystemRoot\Logs\CloudProvisioning"
$Script:LogFile   = "$Script:LogDir\Personalization_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$Script:DownloadDir = "$env:TEMP\WinProvision"
$Script:LocalWallpaper = "$Script:DownloadDir\Wallpaper_OEM.png"

if (-not (Test-Path $Script:LogDir)) {
    New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
}

# ══════════════════════════════════════════════════════════════════════════════
# LOGGING APRIMORADO
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
║                  WINPROVISION PERSONALIZATION v$($Script:Version)                    ║
║                         Enterprise Edition                                   ║
╚══════════════════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  👤 Usuário    : $env:USERNAME" -ForegroundColor White
    Write-Host "  🖥️  Computador : $env:COMPUTERNAME" -ForegroundColor White
    Write-Host "  🎨 Tema       : Escuro" -ForegroundColor White
    Write-Host "  🖼️  Wallpaper  : OEM (baixado do GitHub)" -ForegroundColor White
    Write-Host "  🔄 Explorer   : Será reiniciado ao final" -ForegroundColor White
    Write-Host "  📄 Log        : $Script:LogFile" -ForegroundColor White
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

# ══════════════════════════════════════════════════════════════════════════════
# DOWNLOAD DO WALLPAPER
# ══════════════════════════════════════════════════════════════════════════════

function Download-Wallpaper {
    Write-Banner "ETAPA 0 — BAIXANDO WALLPAPER DO GITHUB"
    Write-Progress -Activity "🎨 Personalização" -Status "Baixando wallpaper OEM" -PercentComplete 5

    if (-not (Test-Path $Script:DownloadDir)) {
        New-Item -ItemType Directory -Path $Script:DownloadDir -Force | Out-Null
    }

    try {
        Write-Log "Baixando wallpaper de: $WallpaperUrl" "INFO"
        Invoke-WebRequest -Uri $WallpaperUrl -OutFile $Script:LocalWallpaper -UseBasicParsing -ErrorAction Stop
        if (Test-Path $Script:LocalWallpaper) {
            $size = (Get-Item $Script:LocalWallpaper).Length
            Write-Log "Download concluído: $([Math]::Round($size/1KB,1)) KB" "OK"
            Write-Progress -Activity "🎨 Personalização" -Status "Wallpaper baixado" -PercentComplete 15
            return $true
        } else {
            throw "Arquivo não encontrado após download."
        }
    } catch {
        Write-Log "Falha no download: $_" "ERROR"
        Write-Log "Usando wallpaper fallback: $WallpaperFallback" "WARN"
        Write-Progress -Activity "🎨 Personalização" -Status "Usando fallback" -PercentComplete 15
        return $false
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# ASSINATURA NATIVA: SystemParametersInfo
# ══════════════════════════════════════════════════════════════════════════════

if (-not ([System.Management.Automation.PSTypeName]"WinProvision.User32").Type) {
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
}

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 1 — TEMA ESCURO
# ══════════════════════════════════════════════════════════════════════════════

function Set-DarkTheme {
    Write-Banner "ETAPA 1/4 — APLICANDO TEMA ESCURO"
    Write-Progress -Activity "🎨 Personalização" -Status "Aplicando tema escuro" -PercentComplete 20

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

    $values = @{
        "AppsUseLightTheme"    = 0
        "SystemUsesLightTheme" = 0
        "EnableTransparency"   = 1
    }

    $allOk = $true
    $step = 0
    foreach ($entry in $values.GetEnumerator()) {
        $step++
        Write-Progress -Activity "🎨 Personalização" -Status "Configurando $($entry.Key)" -PercentComplete (20 + ($step * 3))
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
        Write-Progress -Activity "🎨 Personalização" -Status "Tema escuro OK" -PercentComplete 35
    } else {
        Write-Progress -Activity "🎨 Personalização" -Status "Tema escuro com falhas parciais" -PercentComplete 35
    }
    return $allOk
}

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 2 — WALLPAPER (COM FALLBACK)
# ══════════════════════════════════════════════════════════════════════════════

function Set-Wallpaper {
    param([string]$WallpaperFile)
    Write-Banner "ETAPA 2/4 — APLICANDO WALLPAPER"
    Write-Progress -Activity "🎨 Personalização" -Status "Preparando wallpaper" -PercentComplete 40

    if (-not (Test-Path $WallpaperFile)) {
        Write-Log "Wallpaper não encontrado: $WallpaperFile" "WARN"
        $candidates = @(
            "C:\Windows\Web\Wallpaper\Windows\img0.jpg",
            "C:\Windows\Web\Wallpaper\Windows\img19.jpg",
            "C:\Windows\Web\Wallpaper\Theme1\img1.jpg"
        )
        $resolved = $null
        foreach ($candidate in $candidates) {
            if (Test-Path $candidate) {
                $resolved = $candidate
                break
            }
        }
        if (-not $resolved) {
            Write-Log "Nenhum wallpaper fallback encontrado." "ERROR"
            Write-Progress -Activity "🎨 Personalização" -Status "Falha total no wallpaper" -PercentComplete 50
            return $false
        }
        Write-Log "Usando fallback: $resolved" "WARN"
        $WallpaperFile = $resolved
    } else {
        Write-Log "Wallpaper: $WallpaperFile" "INFO"
    }

    Write-Progress -Activity "🎨 Personalização" -Status "Configurando registro" -PercentComplete 50
    try {
        $regDesktop = "HKCU:\Control Panel\Desktop"
        Set-ItemProperty -Path $regDesktop -Name "Wallpaper"      -Value $WallpaperFile -ErrorAction Stop
        Set-ItemProperty -Path $regDesktop -Name "WallpaperStyle" -Value "10"           -ErrorAction Stop
        Set-ItemProperty -Path $regDesktop -Name "TileWallpaper"  -Value "0"            -ErrorAction Stop
        Write-Log "Caminho persistido no registro." "INFO"
    } catch {
        Write-Log "Aviso ao persistir no registro: $_" "WARN"
    }

    Write-Progress -Activity "🎨 Personalização" -Status "Aplicando via API" -PercentComplete 60
    $result = [WinProvision.User32]::SystemParametersInfo(20, 0, $WallpaperFile, 3)
    if ($result) {
        Write-Log "Wallpaper aplicado com sucesso: $(Split-Path $WallpaperFile -Leaf)" "OK"
        Write-Progress -Activity "🎨 Personalização" -Status "Wallpaper aplicado" -PercentComplete 70
        return $true
    } else {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Log "SystemParametersInfo falhou (Win32 erro: $err)." "WARN"
        Write-Progress -Activity "🎨 Personalização" -Status "Falha na aplicação" -PercentComplete 70
        return $false
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 3 — NOTIFICAÇÃO DO SHELL
# ══════════════════════════════════════════════════════════════════════════════

function Update-Shell {
    Write-Banner "ETAPA 3/4 — NOTIFICANDO SHELL"
    Write-Progress -Activity "🎨 Personalização" -Status "Notificando Explorer" -PercentComplete 80

    $HWND_BROADCAST   = [IntPtr]0xFFFF
    $WM_SETTINGCHANGE = 0x001A
    $SMTO_ABORTIFHUNG = 0x0002
    $result           = [UIntPtr]::Zero

    Write-Progress -Activity "🎨 Personalização" -Status "Enviando WM_SETTINGCHANGE (tema)" -PercentComplete 85
    [WinProvision.User32]::SendMessageTimeout(
        $HWND_BROADCAST,
        $WM_SETTINGCHANGE,
        [UIntPtr]::Zero,
        "ImmersiveColorSet",
        $SMTO_ABORTIFHUNG,
        2000,
        [ref]$result
    ) | Out-Null

    Write-Progress -Activity "🎨 Personalização" -Status "Enviando WM_SETTINGCHANGE (wallpaper)" -PercentComplete 90
    [WinProvision.User32]::SendMessageTimeout(
        $HWND_BROADCAST,
        $WM_SETTINGCHANGE,
        [UIntPtr]::Zero,
        "Environment",
        $SMTO_ABORTIFHUNG,
        2000,
        [ref]$result
    ) | Out-Null

    Write-Log "Shell notificado." "OK"
}

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 4 — REINICIAR EXPLORER (GARANTE APLICAÇÃO TOTAL)
# ══════════════════════════════════════════════════════════════════════════════

function Restart-Explorer {
    Write-Banner "ETAPA 4/4 — REINICIANDO EXPLORER"
    Write-Progress -Activity "🎨 Personalização" -Status "Finalizando aplicação" -PercentComplete 95

    Write-Log "Encerrando o processo explorer.exe..." "STEP"
    try {
        Stop-Process -Name "explorer" -Force -ErrorAction Stop
        Write-Log "Processo explorer.exe finalizado." "OK"
    } catch {
        Write-Log "Não foi possível encerrar o Explorer (pode já estar parado): $_" "WARN"
    }

    Start-Sleep -Seconds 2
    Write-Log "Iniciando um novo explorer.exe..." "STEP"
    try {
        Start-Process "explorer.exe" -ErrorAction Stop
        Write-Log "Explorer reiniciado com sucesso." "OK"
    } catch {
        Write-Log "Falha ao iniciar o Explorer: $_" "ERROR"
        Write-Progress -Activity "🎨 Personalização" -Status "Erro ao reiniciar Explorer" -PercentComplete 100
        return $false
    }

    Write-Progress -Activity "🎨 Personalização" -Status "Explorer reiniciado" -PercentComplete 98
    Start-Sleep -Seconds 2
    return $true
}

# ══════════════════════════════════════════════════════════════════════════════
# EXECUÇÃO PRINCIPAL
# ══════════════════════════════════════════════════════════════════════════════

Write-Header

Write-Log "════════════════════════════════════════════════"
Write-Log " WinProvision Personalization  v$Script:Version"
Write-Log " Início   : $($Script:StartTime.ToString('dd/MM/yyyy HH:mm:ss'))"
Write-Log " Usuário  : $env:USERNAME"
Write-Log "════════════════════════════════════════════════"

$downloadOk = Download-Wallpaper
if ($downloadOk) {
    $wallpaperFile = $Script:LocalWallpaper
} else {
    $wallpaperFile = $WallpaperFallback
}

$themeOk = Set-DarkTheme
$wallpaperOk = Set-Wallpaper -WallpaperFile $wallpaperFile
Update-Shell
$explorerRestarted = Restart-Explorer

$duration = ((Get-Date) - $Script:StartTime).ToString("mm\:ss")

# Resumo final
Write-Host "`n╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                              RESUMO FINAL                                     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Log "════════════════════════════════════════════════"
Write-Log " Tempo total       : $duration min"
Write-Log " Tema escuro       : $(if ($themeOk) { 'Aplicado' } else { 'Falha' })"
Write-Log " Wallpaper         : $(if ($wallpaperOk) { 'Aplicado' } else { 'Falha' })"
Write-Log " Explorer reiniciado: $(if ($explorerRestarted) { 'Sim' } else { 'Não' })"
Write-Log " Log completo      : $Script:LogFile"
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

# Força o fechamento imediato
try {
    [Console]::SetIn([System.IO.StreamReader]::Null)
    $Host.UI.RawUI.FlushInputBuffer()
    [Environment]::Exit(0)
}
catch {
    Stop-Process -Id $pid -Force
}
