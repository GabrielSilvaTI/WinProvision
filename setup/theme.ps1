<#
.SYNOPSIS
    Personalização do sistema WinProvision.
    Aplica tema escuro e wallpaper de forma persistente.

.DESCRIPTION
    Compatível com FirstLogon (sessão interativa do usuário).
    Utiliza API nativa SystemParametersInfo para aplicar wallpaper sem reiniciar o Explorer.
    Notifica o shell via WM_SETTINGCHANGE para aplicar mudanças em tempo real.

.PARAMETER WallpaperPath
    Caminho do wallpaper a aplicar.
    Fallback automático para imagens padrão do Windows se não encontrado.

.NOTES
    Versão : 1.1.0 (Enhanced Edition)
    Requer : PowerShell 5.1+ / Windows 10 1809+
    Contexto: Funciona em sessão de usuário interativa (não SYSTEM).
#>

param(
    [string]$WallpaperPath = "C:\Windows\Web\Wallpaper\Windows\img19.jpg"
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

$Script:Version   = "1.1.0"
$Script:StartTime = Get-Date
$Script:LogDir    = "$env:SystemRoot\Logs\CloudProvisioning"
$Script:LogFile   = "$Script:LogDir\Personalization_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

if (-not (Test-Path $Script:LogDir)) {
    New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
}

# ══════════════════════════════════════════════════════════════════════════════
# LOGGING APRIMORADO COM ÍCONES E CORES
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
    Write-Host "  🖼️  Wallpaper  : $(Split-Path $WallpaperPath -Leaf)" -ForegroundColor White
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
# ASSINATURA NATIVA: SystemParametersInfo
# Registrada uma única vez com nome único para evitar conflito se o script
# rodar mais de uma vez na mesma sessão PS.
# ══════════════════════════════════════════════════════════════════════════════

if (-not ([System.Management.Automation.PSTypeName]"WinProvision.User32").Type) {
    Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;
        namespace WinProvision {
            public class User32 {
                // SPI_SETDESKWALLPAPER = 0x0014 (20)
                // SPIF_UPDATEINIFILE   = 0x0001
                // SPIF_SENDCHANGE      = 0x0002
                [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
                public static extern bool SystemParametersInfo(
                    uint uiAction,
                    uint uiParam,
                    string pvParam,
                    uint fWinIni
                );

                // Notifica o shell sobre mudanças de configuração
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
# ETAPA 1 — TEMA ESCURO (COM BARRA DE PROGRESSO)
# ══════════════════════════════════════════════════════════════════════════════

function Set-DarkTheme {
    Write-Banner "ETAPA 1/3 — APLICANDO TEMA ESCURO"
    Write-Progress -Activity "🎨 Personalização" -Status "Aplicando tema escuro" -PercentComplete 10

    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"

    # Garante que a chave existe (pode não existir em perfis novos)
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
        "AppsUseLightTheme"    = 0   # Apps em modo escuro
        "SystemUsesLightTheme" = 0   # Barra de tarefas e Menu Iniciar escuros
        "EnableTransparency"   = 1   # Mantém transparência (efeito Mica/Acrylic)
    }

    $allOk = $true
    $step = 0
    foreach ($entry in $values.GetEnumerator()) {
        $step++
        Write-Progress -Activity "🎨 Personalização" -Status "Configurando $($entry.Key)" -PercentComplete (10 + ($step * 5))
        try {
            Set-ItemProperty -Path $regPath -Name $entry.Key -Value $entry.Value `
                -Type DWord -ErrorAction Stop
            Write-Log "  $($entry.Key) = $($entry.Value)" "INFO"
        } catch {
            Write-Log "  Falha ao definir $($entry.Key): $_" "WARN"
            $allOk = $false
        }
    }

    if ($allOk) {
        Write-Log "Tema escuro aplicado." "OK"
        Write-Progress -Activity "🎨 Personalização" -Status "Tema escuro OK" -PercentComplete 30
    } else {
        Write-Progress -Activity "🎨 Personalização" -Status "Tema escuro com falhas parciais" -PercentComplete 30
    }
    return $allOk
}

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 2 — WALLPAPER (COM BARRA DE PROGRESSO)
# ══════════════════════════════════════════════════════════════════════════════

function Set-Wallpaper {
    param([string]$Path)
    Write-Banner "ETAPA 2/3 — APLICANDO WALLPAPER"
    Write-Progress -Activity "🎨 Personalização" -Status "Procurando wallpaper" -PercentComplete 35

    # Cadeia de fallback — procura o wallpaper pedido, depois alternativas
    $candidates = @(
        $Path,
        "C:\Windows\Web\Wallpaper\Windows\img0.jpg",    # Wallpaper padrão Win 11
        "C:\Windows\Web\Wallpaper\Windows\img19.jpg",   # Alternativa Win 11
        "C:\Windows\Web\Wallpaper\Theme1\img1.jpg"      # Alternativa Win 10
    ) | Where-Object { $_ } | Select-Object -Unique

    $resolved = $null
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            $resolved = $candidate
            break
        }
        Write-Progress -Activity "🎨 Personalização" -Status "Testando: $(Split-Path $candidate -Leaf)" -PercentComplete 40
    }

    if (-not $resolved) {
        Write-Log "Nenhum wallpaper encontrado nos caminhos testados." "WARN"
        $candidates | ForEach-Object { Write-Log "  Testado: $_" "INFO" }
        Write-Progress -Activity "🎨 Personalização" -Status "Wallpaper não encontrado" -PercentComplete 50
        return $false
    }

    if ($resolved -ne $Path) {
        Write-Log "Wallpaper original não encontrado. Usando fallback: $resolved" "WARN"
    } else {
        Write-Log "Wallpaper: $resolved" "INFO"
    }

    Write-Progress -Activity "🎨 Personalização" -Status "Configurando registro" -PercentComplete 50

    # Persiste o caminho no registro (garante que sobrevive a logoff/logon)
    try {
        $regPath = "HKCU:\Control Panel\Desktop"
        Set-ItemProperty -Path $regPath -Name "Wallpaper"       -Value $resolved -ErrorAction Stop
        Set-ItemProperty -Path $regPath -Name "WallpaperStyle"  -Value "10"      -ErrorAction Stop  # Preenchimento
        Set-ItemProperty -Path $regPath -Name "TileWallpaper"   -Value "0"       -ErrorAction Stop
        Write-Log "Caminho persistido no registro." "INFO"
    } catch {
        Write-Log "Aviso ao persistir no registro: $_" "WARN"
    }

    # Aplica imediatamente via API nativa
    Write-Progress -Activity "🎨 Personalização" -Status "Aplicando wallpaper via API" -PercentComplete 60
    $result = [WinProvision.User32]::SystemParametersInfo(20, 0, $resolved, 3)
    if ($result) {
        Write-Log "Wallpaper aplicado com sucesso: $(Split-Path $resolved -Leaf)" "OK"
        Write-Progress -Activity "🎨 Personalização" -Status "Wallpaper aplicado" -PercentComplete 70
    } else {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Log "SystemParametersInfo falhou (Win32 erro: $err)." "WARN"
        Write-Progress -Activity "🎨 Personalização" -Status "Falha ao aplicar wallpaper" -PercentComplete 70
        return $false
    }

    return $true
}

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 3 — NOTIFICAÇÃO DO SHELL (sem matar o Explorer)
# ══════════════════════════════════════════════════════════════════════════════

function Update-Shell {
    Write-Banner "ETAPA 3/3 — NOTIFICANDO SHELL"
    Write-Progress -Activity "🎨 Personalização" -Status "Notificando Explorer" -PercentComplete 80

    # Envia WM_SETTINGCHANGE (0x001A) para HWND_BROADCAST (0xFFFF)
    # Isso faz o Explorer recarregar as configurações de tema e wallpaper
    # SEM matar e reiniciar o processo — sem tela preta, sem interrupção.
    $HWND_BROADCAST   = [IntPtr]0xFFFF
    $WM_SETTINGCHANGE = 0x001A
    $SMTO_ABORTIFHUNG = 0x0002
    $result           = [UIntPtr]::Zero

    Write-Progress -Activity "🎨 Personalização" -Status "Enviando WM_SETTINGCHANGE (tema)" -PercentComplete 85
    [WinProvision.User32]::SendMessageTimeout(
        $HWND_BROADCAST,
        $WM_SETTINGCHANGE,
        [UIntPtr]::Zero,
        "ImmersiveColorSet",   # Sinaliza mudança de tema escuro/claro
        $SMTO_ABORTIFHUNG,
        2000,
        [ref]$result
    ) | Out-Null

    Write-Progress -Activity "🎨 Personalização" -Status "Enviando WM_SETTINGCHANGE (wallpaper)" -PercentComplete 90
    # Segunda notificação para mudança de wallpaper/desktop
    [WinProvision.User32]::SendMessageTimeout(
        $HWND_BROADCAST,
        $WM_SETTINGCHANGE,
        [UIntPtr]::Zero,
        "Environment",
        $SMTO_ABORTIFHUNG,
        2000,
        [ref]$result
    ) | Out-Null

    Write-Log "Shell notificado. Tema e wallpaper devem refletir imediatamente." "OK"
    Write-Log "Se o tema não aplicar visualmente, um logoff/logon completa a mudança." "INFO"
    Write-Progress -Activity "🎨 Personalização" -Status "Concluído!" -PercentComplete 100
}

# ══════════════════════════════════════════════════════════════════════════════
# EXECUÇÃO PRINCIPAL (COM CABEÇALHO E RESUMO FINAL)
# ══════════════════════════════════════════════════════════════════════════════

Write-Header

Write-Log "════════════════════════════════════════════════"
Write-Log " WinProvision Personalization  v$Script:Version"
Write-Log " Início   : $($Script:StartTime.ToString('dd/MM/yyyy HH:mm:ss'))"
Write-Log " Usuário  : $env:USERNAME"
Write-Log "════════════════════════════════════════════════"

$themeOk = Set-DarkTheme
$wallpaperOk = Set-Wallpaper -Path $WallpaperPath
Update-Shell

$duration = ((Get-Date) - $Script:StartTime).ToString("mm\:ss")

# Resumo final estilizado
Write-Host "`n╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                              RESUMO FINAL                                     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Log "════════════════════════════════════════════════"
Write-Log " Tempo total : $duration min"
Write-Log " Tema escuro : $(if ($themeOk) { 'Aplicado' } else { 'Falha' })"
Write-Log " Wallpaper   : $(if ($wallpaperOk) { 'Aplicado' } else { 'Falha' })"
Write-Log " Log completo: $Script:LogFile"
Write-Log "════════════════════════════════════════════════"

if ($themeOk -and $wallpaperOk) {
    Write-Host "`n✅ Personalização concluída com sucesso!" -ForegroundColor Green
} else {
    Write-Host "`n⚠️ Personalização concluída com falhas parciais. Verifique o log." -ForegroundColor Yellow
}

Write-Host "`n⏱️  Aguardando 3 segundos antes de fechar...`n" -ForegroundColor Gray
Start-Sleep -Seconds 3

# Força o fechamento imediato (funciona em contexto de usuário também)
try {
    [Console]::SetIn([System.IO.StreamReader]::Null)
    $Host.UI.RawUI.FlushInputBuffer()
    [Environment]::Exit(0)
}
catch {
    Stop-Process -Id $pid -Force
}
