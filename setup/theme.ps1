<#
.SYNOPSIS
    Personalização do sistema WinProvision.
    Aplica tema escuro e wallpaper de forma persistente.

.PARAMETER WallpaperPath
    Caminho do wallpaper a aplicar.
    Fallback automático para imagens padrão do Windows se não encontrado.

.NOTES
    Versão : 1.0.0
    Requer : PowerShell 5.1+ / Windows 10 1809+
    Contexto: Funciona em sessão de usuário interativa (não SYSTEM).
              Para FirstLogon, agende para rodar na primeira sessão do usuário.
#>

param(
    [string]$WallpaperPath = "C:\Windows\Web\Wallpaper\Windows\img19.jpg"
)

$ErrorActionPreference = "Continue"

$Script:Version   = "1.0.0"
$Script:StartTime = Get-Date
$Script:LogDir    = "$env:SystemRoot\Logs\CloudProvisioning"
$Script:LogFile   = "$Script:LogDir\Personalization_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

if (-not (Test-Path $Script:LogDir)) {
    New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
}

# ══════════════════════════════════════════════════════════════════════════════
# LOGGING
# ══════════════════════════════════════════════════════════════════════════════

function Write-Log {
    param(
        [string]$Msg,
        [ValidateSet("INFO","WARN","ERROR","OK","STEP")][string]$Level = "INFO"
    )
    $ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $prefix = switch ($Level) {
        "OK"    { "[  OK  ]" } "WARN"  { "[ WARN ]" }
        "ERROR" { "[ERROR ]" } "STEP"  { "[ STEP ]" }
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
# ETAPA 1 — TEMA ESCURO
# ══════════════════════════════════════════════════════════════════════════════

function Set-DarkTheme {
    Write-Log "Aplicando tema escuro..." "STEP"

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
    foreach ($entry in $values.GetEnumerator()) {
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
    }
    return $allOk
}

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 2 — WALLPAPER
# ══════════════════════════════════════════════════════════════════════════════

function Set-Wallpaper {
    param([string]$Path)
    Write-Log "Aplicando wallpaper..." "STEP"

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
    }

    if (-not $resolved) {
        Write-Log "Nenhum wallpaper encontrado nos caminhos testados." "WARN"
        $candidates | ForEach-Object { Write-Log "  Testado: $_" "INFO" }
        return $false
    }

    if ($resolved -ne $Path) {
        Write-Log "Wallpaper original não encontrado. Usando fallback: $resolved" "WARN"
    } else {
        Write-Log "Wallpaper: $resolved" "INFO"
    }

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
    # SPIF_UPDATEINIFILE (1) | SPIF_SENDCHANGE (2) = 3
    $result = [WinProvision.User32]::SystemParametersInfo(20, 0, $resolved, 3)
    if ($result) {
        Write-Log "Wallpaper aplicado com sucesso: $(Split-Path $resolved -Leaf)" "OK"
    } else {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Log "SystemParametersInfo falhou (Win32 erro: $err)." "WARN"
        return $false
    }

    return $true
}

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 3 — NOTIFICAÇÃO DO SHELL (sem matar o Explorer)
# ══════════════════════════════════════════════════════════════════════════════

function Update-Shell {
    Write-Log "Notificando shell sobre alterações..." "STEP"

    # Envia WM_SETTINGCHANGE (0x001A) para HWND_BROADCAST (0xFFFF)
    # Isso faz o Explorer recarregar as configurações de tema e wallpaper
    # SEM matar e reiniciar o processo — sem tela preta, sem interrupção.
    $HWND_BROADCAST   = [IntPtr]0xFFFF
    $WM_SETTINGCHANGE = 0x001A
    $SMTO_ABORTIFHUNG = 0x0002
    $result           = [UIntPtr]::Zero

    [WinProvision.User32]::SendMessageTimeout(
        $HWND_BROADCAST,
        $WM_SETTINGCHANGE,
        [UIntPtr]::Zero,
        "ImmersiveColorSet",   # Sinaliza mudança de tema escuro/claro
        $SMTO_ABORTIFHUNG,
        2000,
        [ref]$result
    ) | Out-Null

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
}

# ══════════════════════════════════════════════════════════════════════════════
# EXECUÇÃO PRINCIPAL
# ══════════════════════════════════════════════════════════════════════════════

Write-Log "════════════════════════════════════════════════"
Write-Log " WinProvision Personalization  v$Script:Version"
Write-Log " Usuário  : $env:USERNAME"
Write-Log " Log      : $Script:LogFile"
Write-Log "════════════════════════════════════════════════"

Set-DarkTheme
Set-Wallpaper -Path $WallpaperPath
Update-Shell

$duration = ((Get-Date) - $Script:StartTime).ToString("mm\:ss")
Write-Log "════════════════════════════════════════════════"
Write-Log " Personalização concluída em $duration."
Write-Log "════════════════════════════════════════════════"

exit 0
