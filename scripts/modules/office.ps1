# Módulo de Instalação do Office via Office Tool Plus
# Garantir encoding UTF-8 com BOM ao salvar este arquivo

$OtpApiUrl = "https://api.github.com/repos/YerongAI/Office-Tool/releases/latest"
$FallbackUrl = "https://github.com/GabrielSilvaTI/WinProvision/releases/download/V1/OTP.zip"

# Alterado para SystemRoot\Temp para garantir total compatibilidade com contextos SYSTEM/MDM/SCCM
$TempDir = Join-Path -Path $env:SystemRoot -ChildPath "Temp\OTP_Provisioning"
$ZipFile = Join-Path -Path $TempDir -ChildPath "OTP.zip"
$ExePath = Join-Path -Path $TempDir -ChildPath "Office Tool Plus.Console.exe"

# Verificar se o Office já está instalado
$OfficeInstalled = $false
$OfficeRegPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration"
)
foreach ($RegPath in $OfficeRegPaths) {
    if (Test-Path -Path $RegPath) {
        $ProductIds = (Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue).ProductReleaseIds
        if ($ProductIds) {
            $OfficeInstalled = $true
            Write-Output "Office ja esta instalado nesta maquina (ProductReleaseIds: $ProductIds). Instalacao ignorada."
            break
        }
    }
}

if ($OfficeInstalled) {
    exit 0
}

try {
    if (Test-Path -Path $TempDir) { Remove-Item -Path $TempDir -Recurse -Force }
    $null = New-Item -Path $TempDir -ItemType Directory

    $WebClient = New-Object System.Net.WebClient
    $WebClient.Headers.Add("User-Agent", "WinProvision")

    # Tentar obter o release mais recente do OTP via API do GitHub
    $DownloadSuccess = $false
    try {
        Write-Output "Consultando release mais recente do OTP..."
        $ReleaseInfo = $WebClient.DownloadString($OtpApiUrl) | ConvertFrom-Json
        $Asset = $ReleaseInfo.assets | Where-Object { $_.name -like "Office_Tool_with_runtime_*_x64.zip" } | Select-Object -First 1
        if (-not $Asset) {
            throw "Nao foi possivel localizar o asset x64 com runtime no release $($ReleaseInfo.tag_name)."
        }
        Write-Output "Baixando Office Tool Plus $($ReleaseInfo.tag_name)..."
        $WebClient.DownloadFile($Asset.browser_download_url, $ZipFile)
        $DownloadSuccess = $true
    } catch {
        Write-Output "Falha ao baixar OTP pela API do GitHub: $_"
        Write-Output "Tentando fallback..."
    }

    # Fallback: baixar do link fixo caso a tentativa principal falhe
    if (-not $DownloadSuccess) {
        try {
            Write-Output "Baixando OTP via fallback..."
            $WebClient.DownloadFile($FallbackUrl, $ZipFile)
            $DownloadSuccess = $true
        } catch {
            throw "Falha tambem no fallback: $_"
        }
    }

    $WebClient.Dispose()

    Write-Output "Extraindo OTP..."
    Expand-Archive -Path $ZipFile -DestinationPath $TempDir -Force

    # Descobrir a pasta real onde o executável está trabalhando
    $WorkingFolder = $TempDir
    if (-not (Test-Path -Path $ExePath)) {
        $Found = Get-ChildItem -Path $TempDir -Filter "Office Tool Plus.Console.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $Found) {
            throw "Executavel do OTP nao encontrado apos extracao em $TempDir."
        }
        $ExePath = $Found.FullName
        $WorkingFolder = $Found.DirectoryName
    }

    Write-Output "Iniciando deployment do Office 365 (pode levar de 15 a 60 minutos)..."
    $ProcessArgs = "deploy /add O365HomePremRetail_pt-br /channel Current /edition 64 /display false /enableupdates true"

    # Logs apontando dinamicamente para a pasta de execução ativa
    $StdOutLog = Join-Path -Path $WorkingFolder -ChildPath "deploy_stdout.log"
    $StdErrLog = Join-Path -Path $WorkingFolder -ChildPath "deploy_stderr.log"

    # Removido o caractere de quebra de linha (backtick) para evitar trailing whitespaces invisíveis
    $Process = Start-Process -FilePath $ExePath -ArgumentList $ProcessArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $StdOutLog -RedirectStandardError $StdErrLog

    if ($Process.ExitCode -eq 0) {
        Write-Output "Office instalado com sucesso."
        if (Test-Path -Path $TempDir) { Remove-Item -Path $TempDir -Recurse -Force }
    } else {
        throw "Falha na instalacao do Office. Exit Code: $($Process.ExitCode). Logs salvos em $WorkingFolder."
    }
} catch {
    Write-Error "Erro no modulo Office: $_"
    Write-Output "Arquivos de diagnostico preservados em $TempDir"
    exit 1
}
