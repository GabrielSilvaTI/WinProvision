# Módulo de Ativação via MAS (Microsoft Activation Scripts)
# Garantir encoding UTF-8 com BOM ao salvar este arquivo

$MasUrl = "https://dev.azure.com/massgrave/Microsoft-Activation-Scripts/_apis/git/repositories/Microsoft-Activation-Scripts/items?path=/MAS/All-In-One-Version-KL/MAS_AIO.cmd&download=true"

# Retornado para a raiz fora de caminhos temporários devido às restrições nativas do MAS
$WorkingDir = "C:\WinProvision_MAS"
$CmdFile = Join-Path -Path $WorkingDir -ChildPath "MAS_AIO.cmd"

try {
    if (Test-Path -Path $WorkingDir) { Remove-Item -Path $WorkingDir -Recurse -Force }
    $null = New-Item -Path $WorkingDir -ItemType Directory

    # Tratamento robusto para o Windows Defender (Evita o erro fatal HRESULT 0x800106ba)
    try {
        Write-Output "Tentando adicionar exclusao no Windows Defender para o diretorio de trabalho..."
        Add-MpPreference -ExclusionPath $WorkingDir -ErrorAction Stop
    } catch {
        Write-Output "Aviso: Nao foi possivel aplicar exclusao no Defender (Servico inativo ou ausente). Prosseguindo..."
    }

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

    # Executa chamando explicitamente o cmd.exe corporativo (/c) fora de pastas temporárias
    # Parâmetros unificados em linha única para prevenir erros de Trailing Whitespace no linter
    $CmdArgs = "/c `"$CmdFile`" /Ohook"
    $Process = Start-Process -FilePath "cmd.exe" -ArgumentList $CmdArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $StdOutLog -RedirectStandardError $StdErrLog

    # Remove a exclusão de forma segura caso ela tenha sido criada com sucesso anteriormente
    try { Remove-MpPreference -ExclusionPath $WorkingDir -ErrorAction SilentlyContinue } catch {}

    if ($Process.ExitCode -eq 0) {
        Write-Output "Ativacao concluida com sucesso."
        if (Test-Path -Path $WorkingDir) { Remove-Item -Path $WorkingDir -Recurse -Force }
    } else {
        throw "Falha na ativacao. Exit Code: $($Process.ExitCode). Logs guardados em $WorkingDir."
    }
} catch {
    # Garante a limpeza da regra do Defender e do diretório mesmo em caso de erro crítico
    try { Remove-MpPreference -ExclusionPath $WorkingDir -ErrorAction SilentlyContinue } catch {}
    Write-Error "Erro no modulo MAS: $_"
    Write-Output "Arquivos de diagnostico preservados em $WorkingDir para analise."
    exit 1
}
