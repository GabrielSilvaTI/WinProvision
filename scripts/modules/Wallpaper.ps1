<#
.SYNOPSIS
    WinProvision - Provisionamento de Wallpaper em Apresentacao de Slides (Slideshow).
.DESCRIPTION
    100% autonomo e compativel com UserOnce (sessao interativa) e Windows Sandbox.
    Invocar sempre como arquivo:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "WinProvision_Wallpaper.ps1"
.NOTES
    Versao : 1.6.6 (Resiliente, Idempotente e CI/CD Compliant)
        - Ajustado para compliance com PSScriptAnalyzer (Singular Nouns, ShouldProcess, etc.)
        - Removido o bloco de auto-relancador (causador de travamentos de I/O em subshells)
        - Bloqueio robusto de Add-Type (evita crash de "Type Already Exists")
        - Insercao de Set-Acl obrigatorio para evitar E_FAIL no COM
        - Try/Catch global forcado sem interatividade
#>

# ==============================================================================
#  VERIFICACAO DE AMBIENTE E SEGURANCA
# ==============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

if ($PSVersionTable.PSVersion.Major -lt 5) { exit 2 }

# Forca TLS 1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls

# ==============================================================================
#  CONFIGURACAO
# ==============================================================================
$Script:TargetDir           = "$env:SystemRoot\Web\Wallpaper\OEM"
$Script:ZipPath             = "$env:TEMP\WinProvision_Wallpaper_$PID.zip"
$Script:DownloadUrl         = "https://github.com/GabrielSilvaTI/WinProvision/releases/download/V1/Wallpaper.zip"
$Script:LogDir              = "$env:SystemRoot\Logs\CloudProvisioning"
$Script:LogFile             = "$Script:LogDir\Wallpaper_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$Script:StartTime           = Get-Date
$Script:SlideshowIntervalMs = 600000   # 10 minutos
$Script:SlideshowShuffle    = 1        # 1 = embaralhar

# ==============================================================================
#  LOGGING
# ==============================================================================
if (-not (Test-Path $Script:LogDir)) { New-Item -ItemType Directory -Path $Script:LogDir -Force -ErrorAction SilentlyContinue | Out-Null }

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts [$Level] $Msg"
    try {
        Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        Write-Verbose "Falha ao gravar log no arquivo: $($_.Exception.Message)"
    }
    Write-Host "[$Level] $Msg"
}

# ==============================================================================
#  FUNCOES CORE
# ==============================================================================
function Install-WallpaperAsset {
    Write-Log "Instalando assets OEM..." "STEP"

    if (-not (Test-Path $Script:TargetDir)) {
        New-Item -Path $Script:TargetDir -ItemType Directory -Force | Out-Null
    }

    # CRITICO: Garante que o usuario atual e o Explorer tenham permissao de leitura (Evita erro COM)
    try {
        $Acl = Get-Acl $Script:TargetDir
        $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule("Users", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
        $Acl.SetAccessRule($Rule)
        Set-Acl -Path $Script:TargetDir -AclObject $Acl
    } catch {
        Write-Log "Falha ao definir ACL, prosseguindo..." "WARN"
    }

    $Existing = Get-ChildItem -Path $Script:TargetDir -Include "*.jpg","*.jpeg","*.png" -Recurse -ErrorAction SilentlyContinue
    if ($Existing.Count -gt 0) {
        Write-Log "$($Existing.Count) imagens ja presentes. Download ignorado." "OK"
        return $true
    }

    try {
        Write-Log "Baixando pacote ZIP..." "INFO"
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($Script:DownloadUrl, $Script:ZipPath)

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Script:ZipPath, $Script:TargetDir)
        Write-Log "Extracao concluida." "OK"
        return $true
    } catch {
        Write-Log "Falha ao baixar/extrair: $_" "ERROR"
        return $false
    } finally {
        Remove-Item $Script:ZipPath -Force -ErrorAction SilentlyContinue
    }
}

function Register-WallpaperType {
    # Guard clause infalivel para UserOnce/Sandbox (evita travamento do Add-Type)
    if ([System.Management.Automation.PSTypeName]'WinProvision.Wallpaper.WallpaperHelper' -as [type]) {
        return
    }

    $csharp = @'
using System;
using System.Runtime.InteropServices;

namespace WinProvision.Wallpaper {
    [ComImport, Guid("B63EA76D-1F85-456F-A19C-48159EFA858B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItemArray { }

    [ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IDesktopWallpaper {
        [PreserveSig] int SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
        [PreserveSig] int GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, [MarshalAs(UnmanagedType.LPWStr)] out string wallpaper);
        [PreserveSig] int GetMonitorDevicePathAt(uint monitorIndex, [MarshalAs(UnmanagedType.LPWStr)] out string monitorID);
        [PreserveSig] int GetMonitorDevicePathCount(out uint count);
        [PreserveSig] int GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorID, out IntPtr displayRect);
        [PreserveSig] int SetBackgroundColor(uint color);
        [PreserveSig] int GetBackgroundColor(out uint color);
        [PreserveSig] int SetPosition(int position);
        [PreserveSig] int GetPosition(out int position);
        [PreserveSig] int SetSlideshow(IntPtr items);
        [PreserveSig] int GetSlideshow(out IntPtr items);
        [PreserveSig] int SetSlideshowOptions(uint options, uint slideshowTick);
        [PreserveSig] int GetSlideshowOptions(out uint options, out uint slideshowTick);
        [PreserveSig] int AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitorID, int direction);
        [PreserveSig] int GetStatus(out uint state);
        [PreserveSig] int Enable([MarshalAs(UnmanagedType.Bool)] bool enable);
    }

    [ComImport, Guid("C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD"), ClassInterface(ClassInterfaceType.None)]
    internal class DesktopWallpaperCoClass { }

    internal static class NativeMethods {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
        internal static extern int SHCreateItemFromParsingName(string pszPath, IntPtr pbc, ref Guid riid, out IntPtr ppv);

        [DllImport("shell32.dll", PreserveSig = true)]
        internal static extern int SHCreateShellItemArrayFromShellItem(IntPtr psi, ref Guid riid, out IntPtr ppv);
    }

    public static class WallpaperHelper {
        public static string ApplySlideshow(string folderPath, uint shuffleOptions, uint intervalMs) {
            Guid iidShellItem = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
            Guid iidShellItemArray = new Guid("B63EA76D-1F85-456F-A19C-48159EFA858B");
            IntPtr pShellItem = IntPtr.Zero;
            IntPtr pItemArray = IntPtr.Zero;
            object wallpaperObj = null;

            try {
                int hr = NativeMethods.SHCreateItemFromParsingName(folderPath, IntPtr.Zero, ref iidShellItem, out pShellItem);
                if (hr != 0 || pShellItem == IntPtr.Zero) return "Falha no SHCreateItemFromParsingName: " + hr;

                hr = NativeMethods.SHCreateShellItemArrayFromShellItem(pShellItem, ref iidShellItemArray, out pItemArray);
                if (hr != 0 || pItemArray == IntPtr.Zero) return "Falha no SHCreateShellItemArrayFromShellItem: " + hr;

                wallpaperObj = new DesktopWallpaperCoClass();
                IDesktopWallpaper wp = (IDesktopWallpaper)wallpaperObj;

                hr = wp.SetSlideshow(pItemArray);
                if (hr != 0) return "SetSlideshow falhou: " + hr;

                wp.SetSlideshowOptions(shuffleOptions, intervalMs);
                wp.SetPosition(4); // Fill

                return string.Empty;
            } catch (Exception ex) {
                return "Excecao COM Interna: " + ex.Message;
            } finally {
                if (pShellItem != IntPtr.Zero) { Marshal.Release(pShellItem); }
                if (pItemArray != IntPtr.Zero) { Marshal.Release(pItemArray); }
                if (wallpaperObj != null)      { Marshal.ReleaseComObject(wallpaperObj); }
            }
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, string pvParam, uint fWinIni);
    }
}
'@
    Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction Stop
}

function Set-SlideshowConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Log "Aplicando Slideshow via API COM e Registro..." "STEP"
    Register-WallpaperType

    # 1. Tenta API COM (Slideshow)
    $Err = [WinProvision.Wallpaper.WallpaperHelper]::ApplySlideshow($Script:TargetDir, [uint32]$Script:SlideshowShuffle, [uint32]$Script:SlideshowIntervalMs)
    if ($Err -ne [string]::Empty) { Write-Log "Aviso COM: $Err" "WARN" }

    # 2. Reforca via Registro (Garante que o Explorer assuma o controle)
    $RegPaths = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers",
        "HKCU:\Control Panel\Personalization\Desktop Slideshow",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\DesktopSpotlight\Settings"
    )
    foreach ($Path in $RegPaths) { if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null } }

    Set-ItemProperty -Path $RegPaths[0] -Name "BackgroundType" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $RegPaths[0] -Name "SlideshowEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $RegPaths[1] -Name "Interval" -Value $Script:SlideshowIntervalMs -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $RegPaths[1] -Name "Shuffle" -Value $Script:SlideshowShuffle -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $RegPaths[2] -Name "EnabledState" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
}

function Set-SpotlightFallback {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Log "Ativando Windows Spotlight (Fallback)..." "WARN"
    $cdk = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    if (-not (Test-Path $cdk)) { New-Item $cdk -Force | Out-Null }
    Set-ItemProperty -Path $cdk -Name "RotatingLockScreenEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
}

# ==============================================================================
#  EXECUCAO PRINCIPAL (Sem interatividade)
# ==============================================================================
try {
    Write-Log "Iniciando WinProvision Wallpaper" "INFO"
    $AssetsOk = Install-WallpaperAsset

    if ($AssetsOk) {
        Set-SlideshowConfig
        Write-Log "Provisionamento concluido com sucesso." "OK"
        exit 0
    } else {
        Set-SpotlightFallback
        exit 1
    }
} catch {
    Write-Log "ERRO CRITICO GLOBAL: $($_.Exception.Message)" "ERROR"
    Set-SpotlightFallback
    exit 2
}
