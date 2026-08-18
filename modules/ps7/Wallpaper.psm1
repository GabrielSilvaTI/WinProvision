# ==============================================================================
# Módulo: WinProvision.Wallpaper
# Descrição: Gerencia o download e a aplicação de papéis de parede OEM / Slideshow
# ==============================================================================

#Requires -Version 7.0

# ------------------------------------------------------------------------------
# FUNÇÕES PRIVADAS (Internas do Módulo)
# ------------------------------------------------------------------------------

function Assert-Administrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Este cmdlet requer privilégios elevados de ADMINISTRADOR para ser executado."
    }
}

function Register-WallpaperComType {
    [CmdletBinding()]
    param()

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
    }
}
'@
    Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction Stop
}

function Set-SlideshowRegistryInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegHive,

        [Parameter(Mandatory = $true)]
        [string]$TargetDir,

        [Parameter(Mandatory = $true)]
        [byte[]]$SlideshowBytes,

        [Parameter(Mandatory = $true)]
        [int]$IntervalMs,

        [Parameter(Mandatory = $true)]
        [int]$Shuffle,

        [System.IO.FileInfo]$FirstImage
    )

    $WallpapersKey   = "$RegHive\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers"
    $ControlPanelKey = "$RegHive\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel"
    $SlideshowKey    = "$RegHive\Control Panel\Personalization\Desktop Slideshow"
    $DesktopKey      = "$RegHive\Control Panel\Desktop"

    foreach ($Path in @($WallpapersKey, $ControlPanelKey, $SlideshowKey, $DesktopKey)) {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    }

    Set-ItemProperty -Path $WallpapersKey -Name "BackgroundType" -Value 2 -Type DWord -Force
    Set-ItemProperty -Path $WallpapersKey -Name "SlideshowDirectoryPath" -Value $TargetDir -Type String -Force
    Set-ItemProperty -Path $WallpapersKey -Name "SlideshowEnabled" -Value 1 -Type DWord -Force

    Set-ItemProperty -Path $ControlPanelKey -Name "SlideshowDirectoryPath1" -Value $SlideshowBytes -Type Binary -Force

    Set-ItemProperty -Path $SlideshowKey -Name "Interval" -Value $IntervalMs -Type DWord -Force
    Set-ItemProperty -Path $SlideshowKey -Name "Shuffle" -Value $Shuffle -Type DWord -Force

    Set-ItemProperty -Path $DesktopKey -Name "WallpaperStyle" -Value "10" -Type String -Force
    Set-ItemProperty -Path $DesktopKey -Name "TileWallpaper" -Value "0" -Type String -Force
    if ($FirstImage) {
        Set-ItemProperty -Path $DesktopKey -Name "Wallpaper" -Value $FirstImage.FullName -Type String -Force
    }
}

function Invoke-LiveSlideshowApplyInternal {
    [CmdletBinding()]
    param(
        [string]$TargetDir,
        [int]$Shuffle,
        [int]$IntervalMs
    )

    try {
        Register-WallpaperComType
        $comError = [WinProvision.Wallpaper.WallpaperHelper]::ApplySlideshow($TargetDir, [uint32]$Shuffle, [uint32]$IntervalMs)
        if ($comError -ne [string]::Empty) {
            Write-Warning "Aviso ao aplicar slideshow via COM: $comError"
        }
        else {
            Write-Verbose "Slideshow aplicado em tempo real na sessão atual via COM."
        }
    }
    catch {
        Write-Warning "Não foi possível aplicar o slideshow via COM: $($_.Exception.Message)"
    }

    try {
        rundll32.exe user32.dll,UpdatePerUserSystemParameters ,1 ,True
    }
    catch {
        Write-Warning "Não foi possível forçar a atualização do Explorer: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------------------
# FUNÇÕES PÚBLICAS (Exportadas pelo Módulo)
# ------------------------------------------------------------------------------

function Set-Wallpaper {
    <#
    .SYNOPSIS
        Baixa e configura imagens OEM como slideshow de papel de parede no Windows.
    .DESCRIPTION
        Esta função faz o download de papéis de parede a partir de um repositório GitHub,
        aplica permissões no diretório de destino e define o slideshow no registro do Windows (HKCU, HKLM e Default User),
        forçando a atualização em tempo real via COM.
    .PARAMETER TargetDir
        Diretório onde as imagens serão salvas. Padrão: C:\Windows\Web\Wallpaper\OEM
    .PARAMETER IntervalMs
        Intervalo de troca em milissegundos. Padrão: 600000 (10 minutos)
    .PARAMETER Shuffle
        1 para ativar ordem aleatória, 0 para desativar. Padrão: 1
    .PARAMETER GitHubRepoUser
        Usuário do GitHub proprietário do repositório.
    .PARAMETER GitHubRepoName
        Nome do repositório no GitHub.
    .PARAMETER CommitHash
        Hash do commit específico para download dos arquivos raw.
    .EXAMPLE
        Set-Wallpaper -IntervalMs 300000 -Shuffle 1
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$TargetDir = "C:\Windows\Web\Wallpaper\OEM",

        [int]$IntervalMs = 600000,

        [ValidateSet(0, 1)]
        [int]$Shuffle = 1,

        [string]$GitHubRepoUser = "GabrielSilvaTI",
        [string]$GitHubRepoName = "WinProvision",
        [string]$CommitHash     = "5e068f89c7775332b2a2559d805e38bd96680ca7"
    )

    begin {
        Assert-Administrator
    }

    process {
        if (-not $PSCmdlet.ShouldProcess($TargetDir, "Configurar Wallpaper OEM e Slideshow")) {
            return $true
        }

        # Rastreia sucesso/falha para o contrato do orquestrador (Invoke-ModuleFunction
        # chama sem parâmetros e espera um retorno bool/Success). Falhas não críticas
        # (ex: Default User) não interrompem a função, mas marcam o retorno final.
        $moduleSuccess = $true

        # 1. Criação do diretório e aplicação de ACL
        if (-not (Test-Path -Path $TargetDir)) {
            New-Item -Path $TargetDir -ItemType Directory -Force | Out-Null
        }

        try {
            $sidUsers   = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-545")
            $Acl        = Get-Acl -Path $TargetDir
            $AccessRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $sidUsers,
                "ReadAndExecute",
                "ContainerInherit, ObjectInherit",
                "None",
                "Allow"
            )
            $Acl.SetAccessRule($AccessRule)
            Set-Acl -Path $TargetDir -AclObject $Acl
        } catch {
            Write-Warning "Aviso ao aplicar ACL em '$TargetDir': $_"
        }

        # 2. Download das imagens
        $folderPath   = "wallpapers"
        $rawBaseUrl   = "https://raw.githubusercontent.com/$GitHubRepoUser/$GitHubRepoName/$CommitHash/$folderPath"
        $manifestUrl  = "$rawBaseUrl/wallpapers.json"
        $downloadedCount = 0

        try {
            $imageNames = Invoke-RestMethod -Uri $manifestUrl -Method Get

            if (-not $imageNames -or $imageNames.Count -eq 0) {
                Write-Error "Nenhuma imagem listada em wallpapers.json."
                return $false
            }

            foreach ($imageName in $imageNames) {
                $downloadUrl = "$rawBaseUrl/$imageName"
                $outputPath  = Join-Path -Path $TargetDir -ChildPath $imageName
                Write-Verbose "Baixando: $imageName..."

                try {
                    Invoke-WebRequest -Uri $downloadUrl -OutFile $outputPath -UseBasicParsing
                    $downloadedCount++
                }
                catch {
                    Write-Warning "Falha ao baixar '$imageName': $($_.Exception.Message)"
                }
            }

            if ($downloadedCount -eq 0) {
                Write-Error "Nenhuma imagem pôde ser baixada com sucesso."
                return $false
            }

            Write-Verbose "Download concluído: $downloadedCount de $($imageNames.Count) imagem(ns)."
        } catch {
            Write-Error "Erro ao conectar e baixar imagens do GitHub: $_"
            return $false
        }

        $firstImage = Get-ChildItem -Path $TargetDir -File | Where-Object { $_.Extension -match '\.(jpg|jpeg|png)$' } | Select-Object -First 1
        $slideshowBytes = [System.Text.Encoding]::Unicode.GetBytes($TargetDir) + [byte[]]@(0x00, 0x00)

        # 3. Registro HKLM
        try {
            Write-Verbose "Aplicando chave HKLM..."
            $hklmPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationAutomation"
            if (-not (Test-Path $hklmPath)) { New-Item -Path $hklmPath -Force | Out-Null }
            Set-ItemProperty -Path $hklmPath -Name "DesktopImageFolder" -Value $TargetDir -Type String -Force
        }
        catch {
            Write-Warning "Falha ao aplicar chave HKLM: $($_.Exception.Message)"
        }

        # 4. Registro HKCU (Usuário Atual) + COM
        try {
            Write-Verbose "Aplicando registro do usuário atual (HKCU)..."
            Set-SlideshowRegistryInternal -RegHive "HKCU:" -TargetDir $TargetDir -SlideshowBytes $slideshowBytes -IntervalMs $IntervalMs -Shuffle $Shuffle -FirstImage $firstImage
            Invoke-LiveSlideshowApplyInternal -TargetDir $TargetDir -Shuffle $Shuffle -IntervalMs $IntervalMs
        }
        catch {
            Write-Error "Falha ao aplicar registro do usuário atual (HKCU): $($_.Exception.Message)"
            $moduleSuccess = $false
        }

        # 5. Registro Default User (Perfis Futuros)
        $defaultUserHive = "C:\Users\Default\NTUSER.DAT"
        if (Test-Path $defaultUserHive) {
            try {
                reg load "HKU\DefaultUser" "$defaultUserHive" | Out-Null

                if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
                    New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null
                }

                Set-SlideshowRegistryInternal -RegHive "HKU:\DefaultUser" -TargetDir $TargetDir -SlideshowBytes $slideshowBytes -IntervalMs $IntervalMs -Shuffle $Shuffle -FirstImage $firstImage
            }
            catch {
                Write-Warning "Não foi possível configurar o perfil padrão (Default User): $($_.Exception.Message)"
            }
            finally {
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                reg unload "HKU\DefaultUser" 2>$null | Out-Null
            }
        } else {
            Write-Warning "Hive do usuário padrão não encontrada em '$defaultUserHive'."
        }

        if ($moduleSuccess) {
            Write-Information "Wallpapers OEM e Slideshow configurados com sucesso!" -InformationAction Continue
        }
        else {
            Write-Warning "Wallpapers OEM e Slideshow configurados com falhas parciais — veja os avisos acima."
        }
        return $moduleSuccess
    }
}

Export-ModuleMember -Function Set-Wallpaper
