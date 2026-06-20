# Módulo de Instalação do Office via Office Tool Plus
# Dependências: Deve ser chamado pelo Orquestrador

$OtpZipUrl = "https://github.com/YerongAI/Office-Tool/releases/latest/download/Office_Tool_with_runtime_x64.zip"
$TempDir = "$env:TEMP\OTP_Provisioning"
$ZipFile = "$TempDir\OTP.zip"
$ExePath = "$TempDir\OfficeTool.Console.exe"

try {
    # 1. Preparação
    if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force }
    New-Item -Path $TempDir -ItemType Directory | Out-Null

    # 2. Download da versão mais atualizada
    Write-Output "Baixando Office Tool Plus..."
    Invoke-WebRequest -Uri $OtpZipUrl -OutFile $ZipFile -UseBasicParsing

    # 3. Extração
    Write-Output "Extraindo OTP..."
    Expand-Archive -Path $ZipFile -DestinationPath $TempDir -Force

    # 4. Execução do Deploy (Comando CLI)
    # Comando solicitado: deploy /add O365HomePremRetail_pt-br /channel Current /edition 64 /display False /enableupdates True
    Write-Output "Iniciando deployment do Office 365..."
    $ProcessArgs = "deploy /add O365HomePremRetail_pt-br /channel Current /edition 64 /display False /enableupdates True"
    
    $Process = Start-Process -FilePath $ExePath -ArgumentList $ProcessArgs -Wait -PassThru -NoNewWindow
    
    if ($Process.ExitCode -eq 0) {
        Write-Output "Office instalado com sucesso."
    } else {
        throw "Falha na instalação do Office. Exit Code: $($Process.ExitCode)"
    }

} catch {
    Write-Error "Erro no módulo Office: $_"
    exit 1
} finally {
    # 5. Limpeza (Remover arquivos após o uso)
    if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force }
}
