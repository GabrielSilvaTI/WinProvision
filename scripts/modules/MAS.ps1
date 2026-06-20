# Módulo de Ativação via MAS (Microsoft Activation Scripts)
# Garantir encoding UTF-8 com BOM ao salvar este arquivo

$MasUrl = "https://dev.azure.com/massgrave/Microsoft-Activation-Scripts/_apis/git/repositories/Microsoft-Activation-Scripts/items?path=/MAS/All-In-One-Version-KL/MAS_AIO.cmd&download=true"
# Alterado para a raiz do C:\ para contornar a restrição de pasta temporária do MAS
$WorkingDir = "C:\MAS_Provisioning"
$CmdFile = Join-Path -Path $WorkingDir -ChildPath "MAS_AIO.cmd"

try {
    if (Test-Path -Path $WorkingDir) { Remove-Item -Path $WorkingDir -Recurse -Force }
    $null = New-Item -Path $WorkingDir -ItemType Directory

    Write-Output "Adicionando exclusao no Windows Defender para o diretorio de trabalho..."
    Add-MpPreference -ExclusionPath $WorkingDir

    Write-Output "Baixando MAS (Microsoft Activation Scripts)..."
    $WebClient = New-Object System.Net.WebClient
    $WebClient.Headers.Add("User-Agent", "WinProvision")
    $WebClient.DownloadFile($MasUrl, $CmdFile)
    $WebClient.Dispose()

    if (-not (Test-Path -Path $CmdFile)) {
        throw "Script do MAS nao encontrado apos o download em $WorkingDir."
    }

    Write-Output "Iniciando ativacao do Office via MAS (Ohook)..."
    $StdOutLog = Join-Path -Path $WorkingDir -ChildPath "mas_stdout.log"
    $StdErrLog = Join-Path -Path $WorkingDir -ChildPath "mas_stderr.log"

    # Executando fora do TEMP, passando o argumento /Ohook
    $Process = Start-Process -FilePath $CmdFile -ArgumentList "/Ohook" -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $StdOutLog -RedirectStandardError $StdErrLog

    if ($Process.ExitCode -eq 0) {
        Write-Output "Ativacao concluida com sucesso."
        # Limpeza completa após o sucesso
        if (Test-Path -Path $WorkingDir) { Remove-Item -Path $WorkingDir -Recurse -Force }
    } else {
        throw "Falha na ativacao. Exit Code: $($Process.ExitCode). Logs guardados em $WorkingDir."
    }
} catch {
    Write-Error "Erro no modulo MAS: $_"
    Write-Output "Arquivos de diagnostico preservados em $WorkingDir para analise."
    exit 1
}