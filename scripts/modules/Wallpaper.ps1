<#
.SYNOPSIS
    WinProvision - Provisionamento de Wallpaper em Apresentacao de Slides (Slideshow).
.DESCRIPTION
    100% autonomo e compativel com UserOnce (sessao interativa) e Windows Sandbox.
    Invocar sempre como arquivo:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "WinProvision_Wallpaper.ps1" -LogPath "C:\caminho\log.log"
.NOTES
    Versao : 1.7.0 (Compativel com Orchestrator, retry de download, validacao de ZIP)
        - Aceita -LogPath do Orchestrator para compartilhar o mesmo arquivo de log
        - Emite linhas [PROGRESS] NN% lidas pela barra de progresso do Orchestrator
        - Download com timeout e retry, alinhado ao padrao do Bootstrap
        - Validacao de integridade do ZIP antes da extracao
        - TLS restrito a 1.2/1.3, alinhado ao Orchestrator
#>

[CmdletBinding()]
param(
    # Quando informado pelo Orchestrator, o modulo escreve no mesmo log compartilhado
    [string]$LogPath
)

# ==============================================================================
#  VERIFICACAO DE AMBIENTE E SEGURANCA
# ==============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

if ($PSVersionTable.PSVersion.Major -lt 5) { exit 2 }

# Forca TLS 1.2/1.3, alinhado ao Orchestrator (protocolos legados removidos)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

# ==============================================================================
#  CONFIGURACAO
# ==============================================================================
$Script:TargetDir           = "$env:SystemRoot\Web\Wallpaper\OEM"
$Script:ZipPath             = "$env:TEMP\WinProvision_Wallpaper_$PID.zip"
$Script:DownloadUrl         = "https://github.com/GabrielSilvaTI/WinProvision/releases/download/V1/Wallpaper.zip"
$Script:LogDir              = "$env:SystemRoot\Logs\CloudProvisioning"
$Script:LogFile             = if ($LogPath) { $LogPath } else { "$Script:LogDir\Wallpaper_$(Get-Date -Format 'yyyyMMdd_HHmmss').log" }
$Script:StartTime           = Get-Date
$Script:SlideshowIntervalMs = 600000   # 10 minutos
$Script:SlideshowShuffle    = 1        # 1 = embaralhar
$Script:MaxRetries          = 3
$Script:RetryDelaySec       = 5
$Script:DownloadTimeoutSec  = 60

# ==============================================================================
#  LOGGING
# ==============================================================================
$Script:LogFileDir = Split-Path -Path $Script:LogFile -Parent
if ($Script:LogFileDir -and -not (Test-Path $Script:LogFileDir)) {
    New-Item -ItemType Directory -Path $Script:LogFileDir -Force -ErrorAction SilentlyContinue | Out-Null
}

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

function Write-ModuleProgress {
    param([int]$Percent, [string]$Status)
    Write-Log "$Percent% - $Status" "PROGRESS"
}

# ==============================================================================
#  FUNCOES CORE
# ==============================================================================
function Get-WallpaperPackage {
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    for ($attempt = 1; $attempt -le $Script:MaxRetries; $attempt++) {
        try {
            Write-Log "Baixando pacote ZIP (tentativa $attempt/$Script:MaxRetries)..." "INFO"
            Invoke-WebRequest -Uri $Script:DownloadUrl -OutFile $Script:ZipPath -UseBasicParsing -TimeoutSec $Script:DownloadTimeoutSec -ErrorAction Stop

            if (-not (Test-Path $Script:ZipPath) -or (Get-Item $Script:ZipPath).Length -eq 0) {
                throw "Arquivo ZIP baixado esta vazio ou ausente."
            }

            # Validacao de integridade: abre o pacote antes de extrair para nao falhar no meio da extracao
            $TestZip = $null
            try {
                $TestZip = [System.IO.Compression.ZipFile]::OpenRead($Script:ZipPath)
            } catch {
                throw "Arquivo ZIP corrompido: $($_.Exception.Message)"
            } finally {
                if ($TestZip) { $TestZip.Dispose() }
            }

            return $true
        } catch {
            Write-Log "Falha no download/validacao (tentativa $attempt/$Script:MaxRetries): $($_.Exception.Message)" "WARN"
            Remove-Item $Script:ZipPath -Force -ErrorAction SilentlyContinue
            if ($attempt -lt $Script:MaxRetries) { Start-Sleep -Seconds $Script:RetryDelaySec }
        }
    }
    return $false
}

function Install-WallpaperAsset {
    Write-Log "Instalando assets OEM..." "STEP"
    Write-ModuleProgress -Percent 10 -Status "Verificando assets existentes"

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
        Write-ModuleProgress -Percent 50 -Status "Assets ja presentes"
        return $true
    }

    Write-ModuleProgress -Percent 20 -Status "Baixando pacote de wallpapers"
    try {
        $Downloaded = Get-WallpaperPackage
        if (-not $Downloaded) {
            Write-Log "Nao foi possivel baixar/validar o pacote ZIP apos $Script:MaxRetries tentativas." "ERROR"
            return $false
        }

        Write-ModuleProgress -Percent 40 -Status "Extraindo pacote"
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Script:ZipPath, $Script:TargetDir)
        Write-Log "Extracao concluida." "OK"
        Write-ModuleProgress -Percent 50 -Status "Extracao concluida"
        return $true
    } catch {
        Write-Log "Falha ao extrair: $_" "ERROR"
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
    Write-ModuleProgress -Percent 70 -Status "Registrando tipo COM"
    Register-WallpaperType

    # 1. Tenta API COM (Slideshow)
    $Err = [WinProvision.Wallpaper.WallpaperHelper]::ApplySlideshow($Script:TargetDir, [uint32]$Script:SlideshowShuffle, [uint32]$Script:SlideshowIntervalMs)
    if ($Err -ne [string]::Empty) { Write-Log "Aviso COM: $Err" "WARN" }

    Write-ModuleProgress -Percent 85 -Status "Aplicando chaves de registro"

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

    Write-ModuleProgress -Percent 95 -Status "Configuracao aplicada"
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
    Write-ModuleProgress -Percent 0 -Status "Iniciando"
    $AssetsOk = Install-WallpaperAsset

    if ($AssetsOk) {
        Set-SlideshowConfig
        Write-Log "Provisionamento concluido com sucesso." "OK"
        Write-ModuleProgress -Percent 100 -Status "Concluido"
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
