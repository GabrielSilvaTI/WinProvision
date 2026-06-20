# Módulo de Pré-requisitos: Validação e Instalação Offline/Headless de WinGet e Chocolatey
# Garantir encoding UTF-8 com BOM ao salvar este arquivo
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288

    Write-Output "========================================================"
    Write-Output "   VERIFICANDO GERENCIADORES DE PACOTE REQUISITADOS"
    Write-Output "========================================================"

    # --- 1. VERIFICAÇÃO / INSTALAÇÃO DO WINGET ---
    if (Get-Command "winget" -ErrorAction SilentlyContinue) {
        Write-Output "[  OK  ] Windows Package Manager (WinGet) ja esta presente."
    } else {
        Write-Output "[ INFO ] WinGet nao encontrado. Iniciando instalacao via ZIP..."

        $WingetZipPath = Join-Path -Path $env:TEMP -ChildPath "winget_bootstrap.zip"
        $WingetExtDir  = Join-Path -Path $env:TEMP -ChildPath "WingetBootstrap"

        if (Test-Path $WingetExtDir) { Remove-Item $WingetExtDir -Recurse -Force -ErrorAction SilentlyContinue }
        $null = New-Item -Path $WingetExtDir -ItemType Directory -Force

        # Download e extração do WinGet e suas dependências (VCLibs, UI.Xaml, AppRuntime)
        $WebClient = New-Object System.Net.WebClient
        $WebClient.DownloadFile('https://github.com/GabrielSilvaTI/WinProvision/releases/download/V1/winget.zip', $WingetZipPath)
        $WebClient.Dispose()

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($WingetZipPath, $WingetExtDir)

        # Ordenação e instalação estrita das dependências antes do pacote principal do WinGet
        $Packages = Get-ChildItem -Path $WingetExtDir -Include "*.msix","*.msixbundle","*.appx","*.appxbundle" -Recurse |
                    Sort-Object {
                        $n = $_.Name.ToLower()
                        if ($n -match "vclibs") { 1 }
                        elseif ($n -match "xaml" -or $n -match "appruntime") { 2 }
                        elseif ($n -match "desktopappinstaller" -or $n -match "winget") { 9 }
                        else { 5 }
                    }

        foreach ($Pkg in $Packages) {
            try { Add-AppxPackage -Path $Pkg.FullName -ForceApplicationShutdown -ErrorAction Stop } catch {
                try { Add-AppxPackage -Path $Pkg.FullName -ErrorAction Stop } catch {
                    Start-Process -FilePath "Dism.exe" -ArgumentList "/Online /Add-ProvisionedAppxPackage /PackagePath:`"$($Pkg.FullName)`" /SkipLicense" -Wait -NoNewWindow
                }
            }
        }

        Start-Sleep -Seconds 5
        Remove-Item $WingetZipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $WingetExtDir -Recurse -Force -ErrorAction SilentlyContinue

        if (-not (Get-Command "winget" -ErrorAction SilentlyContinue)) {
            $SearchPaths = @("$env:ProgramFiles\WindowsApps", "$env:LOCALAPPDATA\Microsoft\WindowsApps")
            foreach ($Path in $SearchPaths) {
                $Found = Get-ChildItem -Path $Path -Filter "winget.exe" -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($Found) { $env:Path += ";$(Split-Path $Found.FullName -Parent)"; break }
            }
        }
    }

    # --- 2. VERIFICAÇÃO / INSTALAÇÃO DO CHOCOLATEY ---
    if (Get-Command "choco" -ErrorAction SilentlyContinue) {
        Write-Output "[  OK  ] Chocolatey ja esta presente."
    } else {
        Write-Output "[ INFO ] Chocolatey nao encontrado. Iniciando instalacao via ZIP..."

        $ChocoZipPath = Join-Path -Path $env:TEMP -ChildPath "chocolatey_bootstrap.zip"
        $ChocoExtDir  = Join-Path -Path $env:TEMP -ChildPath "ChocoBootstrap"

        if (Test-Path $ChocoExtDir) { Remove-Item $ChocoExtDir -Recurse -Force -ErrorAction SilentlyContinue }
        $null = New-Item -Path $ChocoExtDir -ItemType Directory -Force

        # Download e extração da estrutura oficial do Chocolatey baseada nas imagens fornecidas
        $WebClient = New-Object System.Net.WebClient
        $WebClient.DownloadFile('https://github.com/GabrielSilvaTI/WinProvision/releases/download/V1/chocolatey.zip', $ChocoZipPath)
        $WebClient.Dispose()

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ChocoZipPath, $ChocoExtDir)

        # Execução do script de instalação local contido dentro da pasta extraída
        Set-ExecutionPolicy Bypass -Scope Process -Force
        $InstallScript = Get-ChildItem -Path $ChocoExtDir -Filter "chocolateyInstall.ps1" -Recurse | Select-Object -First 1
        
        if ($InstallScript) {
            & $InstallScript.FullName
        } else {
            throw "Script chocolateyInstall.ps1 nao encontrado dentro do ZIP extraido."
        }

        $env:Path += ";$env:ALLUSERSPROFILE\chocolatey\bin"

        Remove-Item $ChocoZipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $ChocoExtDir -Recurse -Force -ErrorAction SilentlyContinue

        if (-not (Get-Command "choco" -ErrorAction SilentlyContinue)) {
            throw "Falha ao registrar o Chocolatey no ambiente do sistema."
        }
    }

    Write-Output "========================================================"
    Write-Output " Todos os gerenciadores necessarios estao prontos!"
    Write-Output "========================================================"

    # --- 3. INSTALAÇÃO DOS PACOTES VIA JSON REMOTO COM FALLBACK INTELIGENTE ---
    $JsonUrl = "https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/pacotes.json"
    $Packages = (Invoke-RestMethod -Uri $JsonUrl -UseBasicParsing).packages

    foreach ($Pkg in $Packages) {
        $Manager = $Pkg.ManagerName.ToLower()
        if ($Manager -eq "winget") {
            $Proc = Start-Process -FilePath "winget.exe" -ArgumentList "install --id `"$($Pkg.Id)`" --source winget --exact --accept-package-agreements --accept-source-agreements --disable-interactivity --silent --force" -Wait -PassThru -NoNewWindow
            
            if ($Proc.ExitCode -ne 0) {
                $ChocoAppName = ($Pkg.Id -split "\.")[-1].ToLower()
                Start-Process -FilePath "choco.exe" -ArgumentList "install `"$ChocoAppName`" -y --no-progress --silent" -Wait -NoNewWindow
            }
        } 
        elseif ($Manager -eq "chocolatey" -or $Manager -eq "choco") {
            Start-Process -FilePath "choco.exe" -ArgumentList "install `"$($Pkg.Id)`" -y --no-progress --silent" -Wait -NoNewWindow
        }
    }

} catch {
    Write-Error "Erro no modulo de Pre-requisitos: $_"
    exit 1
}