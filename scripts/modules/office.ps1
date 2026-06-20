# Módulo de Instalação do Office via Office Tool Plus
# Garantir encoding UTF-8 com BOM ao salvar este arquivo

$OtpZipUrl = "https://github.com/YerongAI/Office-Tool/releases/latest/download/Office_Tool_with_runtime_x64.zip"
$TempDir = Join-Path -Path $env:TEMP -ChildPath "OTP_Provisioning"
$ZipFile = Join-Path -Path $TempDir -ChildPath "OTP.zip"
$ExePath = Join-Path -Path $TempDir -ChildPath "OfficeTool.Console.exe"

try {
    if (Test-Path -Path $TempDir) { Remove-Item -Path $TempDir -Recurse -Force }
    $null = New-Item -Path $TempDir -ItemType Directory

    Write-Output "Baixando Office Tool Plus..."
    Invoke-WebRequest -Uri $OtpZipUrl -OutFile $ZipFile -UseBasicParsing

    Write-Output "Extraindo OTP..."
    Expand-Archive -Path $ZipFile -DestinationPath $TempDir -Force

    Write-Output "Iniciando deployment do Office 365..."
    $ProcessArgs = "deploy /add O365HomePremRetail_pt-br /channel Current /edition 64 /display False /enableupdates True"
    
    $Process = Start-Process -FilePath $ExePath -ArgumentList $ProcessArgs -Wait -PassThru -NoNewWindow
    
    if ($Process.ExitCode -eq 0) {
        Write-Output "Office instalado com sucesso."
    } else {
        throw "Falha na instalacao do Office. Exit Code: $($Process.ExitCode)"
    }
} catch {
    Write-Error "Erro no modulo Office: $_"
    exit 1
} finally {
    if (Test-Path -Path $TempDir) { Remove-Item -Path $TempDir -Recurse -Force }
}
