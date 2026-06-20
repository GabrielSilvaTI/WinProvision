# Módulo de Otimização e Atualização Inteligente (Baseado no 1155 do ET + WinProvision)
# Garante atualizações de Apps, OS de forma controlada e busca inteligente de drivers

$WorkingDir = "C:\Optimization_Provisioning"
try {
    if (Test-Path -Path $WorkingDir) { Remove-Item -Path $WorkingDir -Recurse -Force }
    $null = New-Item -Path $WorkingDir -ItemType Directory

    # --- 1. ATUALIZAÇÃO INTELIGENTE DO SISTEMA E APPS (WINGET) ---
    Write-Output "Atualizando pacotes e aplicativos via Windows Package Manager (Winget)..."
    & winget upgrade --all --silent --accept-package-agreements --accept-source-agreements --include-unknown | Out-Null

    # --- 2. GERENCIAMENTO INTELIGENTE DE DRIVERS (CONFORME O HARDWARE) ---
    Write-Output "Iniciando busca inteligente por drivers recomendados pelo fabricante..."

    # Executado em Job com timeout para evitar bloqueio da COM do WUA
    $UpdateJob = Start-Job -ScriptBlock {
        $UpdateSession = New-Object -ComObject Microsoft.Update.Session
        $UpdateSearcher = $UpdateSession.CreateUpdateSearcher()
        $UpdateSearcher.ServerSelection = 2 # 2 = ssWindowsUpdate

        # "IsCritical" nao existe na lista de criterios suportados pelo Search(), e OR
        # so e permitido no nivel mais externo da string de busca. Por isso a busca
        # fica ampla (so IsInstalled=0) e o filtro de driver/criticidade e feito aqui,
        # lendo as propriedades Type e MsrcSeverity de cada update retornado.
        $SearchResult = $UpdateSearcher.Search("IsInstalled=0")
        $RelevantUpdates = $SearchResult.Updates | Where-Object {
            $_.Type -eq "Driver" -or $_.MsrcSeverity -eq "Critical"
        }

        if (-not $RelevantUpdates -or @($RelevantUpdates).Count -eq 0) {
            return @{ Count = 0 }
        }

        $Pending = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($Update in $RelevantUpdates) {
            # Aceitar EULA de cada update; sem isso o Install() ignora o item silenciosamente
            if (-not $Update.EulaAccepted) { $Update.AcceptEula() | Out-Null }
            $Pending.Add($Update) | Out-Null
        }

        $UpdateDownloader = $UpdateSession.CreateUpdateDownloader()
        $UpdateDownloader.Updates = $Pending
        $null = $UpdateDownloader.Download()

        # Instalar apenas o que realmente foi baixado
        $ToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($Update in $Pending) {
            if ($Update.IsDownloaded) { $ToInstall.Add($Update) | Out-Null }
        }

        if ($ToInstall.Count -eq 0) {
            return @{ Count = $Pending.Count; Installed = 0; ResultCode = -1 }
        }

        $UpdateInstaller = $UpdateSession.CreateUpdateInstaller()
        $UpdateInstaller.Updates = $ToInstall
        $InstallationResult = $UpdateInstaller.Install()

        return @{ Count = $Pending.Count; Installed = $ToInstall.Count; ResultCode = $InstallationResult.ResultCode }
    }

    $JobResult = $UpdateJob | Wait-Job -Timeout 1800
    if (-not $JobResult) {
        Stop-Job -Job $UpdateJob
        Write-Output "Busca/instalacao de drivers excedeu o tempo limite e foi interrompida."
    } else {
        $Result = Receive-Job -Job $UpdateJob
        if ($Result.Count -eq 0) {
            Write-Output "Todos os drivers ja estao na versao homologada mais recente para este hardware."
        } else {
            Write-Output "Encontrados $($Result.Count) drivers/atualizacoes pendentes. Instalados: $($Result.Installed). ResultCode: $($Result.ResultCode)"
        }
    }
    Remove-Job -Job $UpdateJob -Force -ErrorAction SilentlyContinue

    # --- 3. OTIMIZAÇÕES BASEADAS NO VÍDEO (1155 do ET) ---
    Write-Output "Aplicando otimizacoes de latencia e debloat no Registro do Windows..."

    # A. Desativar Compressão de Memória para mitigar latência em jogos (Conforme 1155 do ET) [00:39:19]
    Disable-MMAgent -MemoryCompression | Out-Null

    # B. Restaurar o Menu de Contexto Clássico do Windows 10 no Windows 11 (Sem clique duplo/atraso) [00:06:55]
    $ContextKey = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
    if (-not (Test-Path -Path $ContextKey)) {
        $null = New-Item -Path $ContextKey -Force
        Set-ItemProperty -Path $ContextKey -Name "(Default)" -Value "" -Force
    }

    # C. Debloat de Telemetria e Coleta de Dados em Background [00:29:13]
    $TelemetryKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
    if (-not (Test-Path -Path $TelemetryKey)) { $null = New-Item -Path $TelemetryKey -Force }
    Set-ItemProperty -Path $TelemetryKey -Name "AllowTelemetry" -Value 0 -Type DWord -Force

    # D. Impedir Aplicativos Universais de rodarem secretamente em Segundo Plano [00:33:47]
    $AppPrivacyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"
    if (-not (Test-Path -Path $AppPrivacyKey)) { $null = New-Item -Path $AppPrivacyKey -Force }
    Set-ItemProperty -Path $AppPrivacyKey -Name "LetAppsRunInBackground" -Value 2 -Type DWord -Force # 2 = Forçar Negação

    # E. Desativar Resultados do Bing no Menu Iniciar (Pesquisa Local limpa e rápida) [00:08:31]
    $SearchKey = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"
    if (-not (Test-Path -Path $SearchKey)) { $null = New-Item -Path $SearchKey -Force }
    Set-ItemProperty -Path $SearchKey -Name "DisableSearchBoxSuggestions" -Value 1 -Type DWord -Force

    # F. Configurar Windows Update para apenas 'Avisar antes de baixar' (Modo Controlado) [00:35:25]
    $AuKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    if (-not (Test-Path -Path $AuKey)) { $null = New-Item -Path $AuKey -Force }
    Set-ItemProperty -Path $AuKey -Name "NoAutoUpdate" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $AuKey -Name "AUOptions" -Value 2 -Type DWord -Force # 2 = Avisar antes de baixar

    # G. Desativar ID de Anúncios e Rastreamento de Perfil [00:36:56]
    $AdvertisingKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
    if (-not (Test-Path -Path $AdvertisingKey)) { $null = New-Item -Path $AdvertisingKey -Force }
    Set-ItemProperty -Path $AdvertisingKey -Name "Enabled" -Value 0 -Type DWord -Force

    Write-Output "Todas as otimizacoes e atualizacoes de hardware aplicadas com sucesso."
    if (Test-Path -Path $WorkingDir) { Remove-Item -Path $WorkingDir -Recurse -Force }

} catch {
    Write-Error "Erro no modulo de Otimizacao/Drivers: $_"
    exit 1
}