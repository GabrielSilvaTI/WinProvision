# Módulo de Pré-requisitos: Validação e Instalação do WinGet e Chocolatey
# Garantir encoding UTF-8 com BOM ao salvar este arquivo
try {
    # Garante TLS 1.2/1.3 e desativa alertas de confirmação globais para sessões automatizadas (UserOnce/SYSTEM)
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288
    $ConfirmPreference = 'None'

    Write-Output "========================================================"
    Write-Output "   VERIFICANDO GERENCIADORES DE PACOTE REQUISITADOS"
    Write-Output "========================================================"

    # --- 1. VERIFICAÇÃO / INSTALAÇÃO DO WINGET ---
    if (Get-Command "winget" -ErrorAction SilentlyContinue) {
        Write-Output "[  OK  ] Windows Package Manager (WinGet) ja esta presente."
    } else {
        Write-Output "[ INFO ] WinGet nao encontrado. Iniciando instalacao automatica..."

        # Força o bootstrap interno do NuGet sem interrupção de prompt
        $null = Find-PackageProvider -Name NuGet -Force -ErrorAction SilentlyContinue
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.208 -Force -Confirm:$false -ErrorAction SilentlyContinue

        if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
            $null = Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -Scope AllUsers -Confirm:$false -ErrorAction SilentlyContinue
        }

        Import-Module Microsoft.WinGet.Client -Force
        Repair-WinGetPackageManager -AllUsers -Force -Latest

        if (Get-Command "winget" -ErrorAction SilentlyContinue) {
            Write-Output "[  OK  ] WinGet instalado com sucesso."
        } else {
            throw "WinGet nao foi registrado no PATH apos a instalacao via Repair-WinGetPackageManager."
        }
    }

    # --- 2. VERIFICAÇÃO / INSTALAÇÃO DO CHOCOLATEY ---
    if (Get-Command "choco" -ErrorAction SilentlyContinue) {
        Write-Output "[  OK  ] Chocolatey ja esta presente."
    } else {
        Write-Output "[ INFO ] Chocolatey nao encontrado. Iniciando instalacao..."

        $TempDir = Join-Path -Path $env:TEMP -ChildPath "Choco_Install"
        if (Test-Path -Path $TempDir) { Remove-Item -Path $TempDir -Recurse -Force }
        $null = New-Item -Path $TempDir -ItemType Directory
        $InstallScriptPath = Join-Path -Path $TempDir -ChildPath "install.ps1"

        Set-ExecutionPolicy Bypass -Scope Process -Force

        # Baixa o script oficial para disco e executa o arquivo local.
        $WebClient = New-Object System.Net.WebClient
        $WebClient.DownloadFile('https://community.chocolatey.org/install.ps1', $InstallScriptPath)
        $WebClient.Dispose()

        if (-not (Test-Path -Path $InstallScriptPath) -or (Get-Item -Path $InstallScriptPath).Length -eq 0) {
            throw "Falha ao baixar o instalador oficial do Chocolatey."
        }

        & $InstallScriptPath

        # Atualiza a variável de ambiente PATH para a sessão atual reconhecer o comando 'choco' imediatamente
        $env:Path += ";$env:ALLUSERSPROFILE\chocolatey\bin"

        if (Get-Command "choco" -ErrorAction SilentlyContinue) {
            Write-Output "[  OK  ] Chocolatey instalado com sucesso."
        } else {
            throw "Falha ao registrar o Chocolatey no ambiente do sistema."
        }

        Remove-Item -Path $TempDir -Recurse -Force
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
            
            # Se o WinGet falhar (ExitCode diferente de 0), aplica o fallback via Chocolatey usando apenas o nome do app extraido do ID
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
