# Módulo de Ativação via MAS (Microsoft Activation Scripts)
# Garantir encoding UTF-8 com BOM ao salvar este arquivo

$MasUrl = "https://dev.azure.com/massgrave/Microsoft-Activation-Scripts/_apis/git/repositories/Microsoft-Activation-Scripts/items?path=/MAS/All-In-One-Version-KL/MAS_AIO.cmd&download=true"
$WorkingDir = "C:\WinProvision_MAS"
$CmdFile = Join-Path -Path $WorkingDir -ChildPath "MAS_AIO.cmd"

try {
    if (Test-Path -Path $WorkingDir) { Remove-Item -Path $WorkingDir -Recurse -Force }
    $null = New-Item -Path $WorkingDir -ItemType Directory

    try {
        Write-Output "Tentando adicionar exclusao no Windows Defender..."
        Add-MpPreference -ExclusionPath $WorkingDir -ErrorAction Stop
    } catch {
        Write-Output "Aviso: Nao foi possivel aplicar exclusao no Defender. Prosseguindo..."
    }

    Write-Output "Baixando MAS..."
    $WebClient = New-Object System.Net.WebClient
    $WebClient.Headers.Add("User-Agent", "WinProvision")
    $WebClient.DownloadFile($MasUrl, $CmdFile)
    $WebClient.Dispose()

    if (-not (Test-Path -Path $CmdFile)) {
        throw "Script do MAS nao encontrado apos o download."
    }

    Write-Output "Iniciando ativacao do Office via MAS (Ohook)..."
    $StdOutLog = Join-Path -Path $WorkingDir -ChildPath "mas_stdout.log"
    $StdErrLog = Join-Path -Path $WorkingDir -ChildPath "mas_stderr.log"

    $CmdArgs = "/c `"$CmdFile`" /Ohook"
    $Process = Start-Process -FilePath "cmd.exe" -ArgumentList $CmdArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $StdOutLog -RedirectStandardError $StdErrLog

    try {
        Remove-MpPreference -ExclusionPath $WorkingDir -ErrorAction SilentlyContinue
    } catch {
        $null = $_
    }

    if ($Process.ExitCode -eq 0) {
        Write-Output "Ativacao concluida com sucesso."
        if (Test-Path -Path $WorkingDir) { Remove-Item -Path $WorkingDir -Recurse -Force }
    } else {
        throw "Falha na ativacao. Exit Code: $($Process.ExitCode)."
    }
} catch {
    try {
        Remove-MpPreference -ExclusionPath $WorkingDir -ErrorAction SilentlyContinue
    } catch {
        $null = $_
    }
    Write-Error "Erro no modulo MAS: $_"
    exit 1
}
