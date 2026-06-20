# Módulo de Instalação do Office via Office Tool Plus
# Garantir encoding UTF-8 com BOM ao salvar este arquivo
$OtpApiUrl = "https://api.github.com/repos/YerongAI/Office-Tool/releases/latest"
$TempDir = Join-Path -Path $env:TEMP -ChildPath "OTP_Provisioning"
$ZipFile = Join-Path -Path $TempDir -ChildPath "OTP.zip"
$ExePath = Join-Path -Path $TempDir -ChildPath "Office Tool Plus.Console.exe"
try {
    if (Test-Path -Path $TempDir) { Remove-Item -Path $TempDir -Recurse -Force }
    $null = New-Item -Path $TempDir -ItemType Directory

    Write-Output "Consultando release mais recente do OTP..."
    $WebClient = New-Object System.Net.WebClient
    $WebClient.Headers.Add("User-Agent", "WinProvision")
    $ReleaseInfo = $WebClient.DownloadString($OtpApiUrl) | ConvertFrom-Json
    $Asset = $ReleaseInfo.assets | Where-Object { $_.name -like "Office_Tool_with_runtime_*_x64.zip" } | Select-Object -First 1

    if (-not $Asset) {
        throw "Nao foi possivel localizar o asset x64 com runtime no release $($ReleaseInfo.tag_name)."
    }

    Write-Output "Baixando Office Tool Plus $($ReleaseInfo.tag_name)..."
    $WebClient.DownloadFile($Asset.browser_download_url, $ZipFile)
    $WebClient.Dispose()

    Write-Output "Extraindo OTP..."
    Expand-Archive -Path $ZipFile -DestinationPath $TempDir -Force

    if (-not (Test-Path -Path $ExePath)) {
        $Found = Get-ChildItem -Path $TempDir -Filter "Office Tool Plus.Console.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $Found) {
            throw "Executavel do OTP nao encontrado apos extracao em $TempDir."
        }
        $ExePath = $Found.FullName
    }

    Write-Output "Iniciando deployment do Office 365..."
    $ProcessArgs = "deploy /add O365HomePremRetail_pt-br /channel Current /edition 64 /display false /enableupdates true"
    $StdOutLog = Join-Path -Path $TempDir -ChildPath "deploy_stdout.log"
    $StdErrLog = Join-Path -Path $TempDir -ChildPath "deploy_stderr.log"

    $Process = Start-Process -FilePath $ExePath -ArgumentList $ProcessArgs -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $StdOutLog -RedirectStandardError $StdErrLog

    if ($Process.ExitCode -eq 0) {
        Write-Output "Office instalado com sucesso."
        if (Test-Path -Path $TempDir) { Remove-Item -Path $TempDir -Recurse -Force }
    } else {
        throw "Falha na instalacao do Office. Exit Code: $($Process.ExitCode). Logs em $TempDir."
    }
} catch {
    Write-Error "Erro no modulo Office: $_"
    Write-Output "Arquivos de diagnostico preservados em $TempDir"
    exit 1
}