# Módulo de Otimização e Atualização Inteligente
# Garantir encoding UTF-8 com BOM ao salvar este arquivo

$WorkingDir = "C:\Optimization_Provisioning"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    if (Test-Path -Path $WorkingDir) { Remove-Item -Path $WorkingDir -Recurse -Force }
    $null = New-Item -Path $WorkingDir -ItemType Directory

    # -------------------------------------------------------------------------
    # 1. ATUALIZAÇÃO DE APLICATIVOS (WINGET & CHOCOLATEY)
    # -------------------------------------------------------------------------
    Write-Output "[1/4] Atualizando pacotes e aplicativos do sistema..."

    # Winget
    $WingetCmd  = Get-Command winget -ErrorAction SilentlyContinue
    $WingetPath = if ($WingetCmd) { $WingetCmd.Source } else { $null }
    if ($WingetPath) {
        & winget upgrade --all --silent --accept-package-agreements --accept-source-agreements --include-unknown | Out-Null
        Write-Output "  [OK] Atualizacao via Winget concluida."
    } else {
        Write-Output "  [Aviso] Winget nao encontrado."
    }

    # Chocolatey
    $ChocoCmd = Get-Command choco -ErrorAction SilentlyContinue
    if ($ChocoCmd) {
        & choco upgrade all -y --silent | Out-Null
        Write-Output "  [OK] Atualizacao via Chocolatey concluida."
    } else {
        Write-Output "  [Aviso] Chocolatey nao encontrado."
    }

    # -------------------------------------------------------------------------
    # 2. GERENCIAMENTO INTELIGENTE DE DRIVERS (WINDOWS UPDATE)
    # -------------------------------------------------------------------------
    Write-Output "[2/4] Iniciando busca inteligente por drivers recomendados pelo fabricante..."

    $UpdateJob = Start-Job -ScriptBlock {
        try {
            $UpdateSession  = New-Object -ComObject Microsoft.Update.Session
            $UpdateSearcher = $UpdateSession.CreateUpdateSearcher()
            $UpdateSearcher.ServerSelection = 2 # ssWindowsUpdate

            $SearchResult = $UpdateSearcher.Search("IsInstalled=0")
            $RelevantUpdates = $SearchResult.Updates | Where-Object {
                $_.Type -eq "Driver" -or $_.MsrcSeverity -eq "Critical"
            }

            if (-not $RelevantUpdates -or @($RelevantUpdates).Count -eq 0) {
                return @{ Count = 0 }
            }

            $Pending = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($Update in $RelevantUpdates) {
                if (-not $Update.EulaAccepted) { $Update.AcceptEula() | Out-Null }
                $Pending.Add($Update) | Out-Null
            }

            $Downloader         = $UpdateSession.CreateUpdateDownloader()
            $Downloader.Updates = $Pending
            $null               = $Downloader.Download()

            $ToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($Update in $Pending) {
                if ($Update.IsDownloaded) { $ToInstall.Add($Update) | Out-Null }
            }

            if ($ToInstall.Count -eq 0) {
                return @{ Count = $Pending.Count; Installed = 0; ResultCode = -1 }
            }

            $Installer         = $UpdateSession.CreateUpdateInstaller()
            $Installer.Updates = $ToInstall
            $InstallResult     = $Installer.Install()

            return @{ Count = $Pending.Count; Installed = $ToInstall.Count; ResultCode = $InstallResult.ResultCode }
        } catch {
            return @{ Count = -1; Error = $_.ToString() }
        }
    }

    $JobResult = $UpdateJob | Wait-Job -Timeout 1800
    if (-not $JobResult) {
        Stop-Job -Job $UpdateJob
        Write-Output "Busca/instalacao de drivers excedeu o tempo limite (30 min) e foi interrompida."
    } else {
        $Result = Receive-Job -Job $UpdateJob
        if ($Result.Count -eq -1) {
            Write-Output "Erro durante busca de drivers: $($Result.Error)"
        } elseif ($Result.Count -eq 0) {
            Write-Output "Todos os drivers ja estao na versao homologada mais recente para este hardware."
        } else {
            Write-Output "Encontrados $($Result.Count) drivers/atualizacoes pendentes. Instalados: $($Result.Installed). ResultCode: $($Result.ResultCode)"
        }
    }
    Remove-Job -Job $UpdateJob -Force -ErrorAction SilentlyContinue

    # -------------------------------------------------------------------------
    # 3. OTIMIZAÇÕES DE REGISTRO E APLICAÇÃO IMEDIATA
    # -------------------------------------------------------------------------
    Write-Output "[3/4] Aplicando otimizacoes de latencia e debloat no Registro do Windows..."

    # Compressão de Memória
    try {
        Disable-MMAgent -MemoryCompression -ErrorAction Stop | Out-Null
        [System.GC]::Collect()
        Write-Output "  [OK] Compressao de memoria desativada (Live)."
    } catch {
        Write-Output "  [AVISO] Nao foi possivel desativar compressao de memoria: $_"
    }

    # Menu de Contexto Clássico do Windows 11
    $ContextKey = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
    if (-not (Test-Path -Path $ContextKey)) {
        $null = New-Item -Path $ContextKey -Force
        Set-ItemProperty -Path $ContextKey -Name "(Default)" -Value "" -Force
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Write-Output "  [OK] Menu de contexto classico restaurado e aplicado."
    } else {
        Write-Output "  [OK] Menu de contexto classico ja configurado."
    }

    # Telemetria
    $TelemetryKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
    if (-not (Test-Path -Path $TelemetryKey)) { $null = New-Item -Path $TelemetryKey -Force }
    Set-ItemProperty -Path $TelemetryKey -Name "AllowTelemetry" -Value 0 -Type DWord -Force
    Write-Output "  [OK] Telemetria desativada."

    # Apps em Segundo Plano
    $AppPrivacyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"
    if (-not (Test-Path -Path $AppPrivacyKey)) { $null = New-Item -Path $AppPrivacyKey -Force }
    Set-ItemProperty -Path $AppPrivacyKey -Name "LetAppsRunInBackground" -Value 2 -Type DWord -Force
    Write-Output "  [OK] Apps em segundo plano bloqueados."

    # Busca Bing no Menu Iniciar
    $SearchKey = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"
    if (-not (Test-Path -Path $SearchKey)) { $null = New-Item -Path $SearchKey -Force }
    Set-ItemProperty -Path $SearchKey -Name "DisableSearchBoxSuggestions" -Value 1 -Type DWord -Force
    Write-Output "  [OK] Busca Bing no Iniciar desativada."

    # Windows Update Controlado (Notificar antes de baixar)
    $AuKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    if (-not (Test-Path -Path $AuKey)) { $null = New-Item -Path $AuKey -Force }
    Set-ItemProperty -Path $AuKey -Name "NoAutoUpdate" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $AuKey -Name "AUOptions"    -Value 2 -Type DWord -Force
    Write-Output "  [OK] Windows Update configurado para modo controlado."

    # ID de Anúncios
    $AdvertisingKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
    if (-not (Test-Path -Path $AdvertisingKey)) { $null = New-Item -Path $AdvertisingKey -Force }
    Set-ItemProperty -Path $AdvertisingKey -Name "Enabled" -Value 0 -Type DWord -Force
    Write-Output "  [OK] ID de anuncios desativado."

    # -------------------------------------------------------------------------
    # 4. LIMPEZA RESIDUAL E FINALIZAÇÃO
    # -------------------------------------------------------------------------
    Write-Output "[4/4] Removendo pastas temporarias de instalacao do WinProvision..."

    if (Test-Path -Path $WorkingDir) { Remove-Item -Path $WorkingDir -Recurse -Force }

    $OtherDirs = @(
        (Join-Path -Path $env:SystemRoot -ChildPath "Temp\OTP_Provisioning"),
        "C:\WinProvision_MAS",
        "C:\WinProvision_Temp"
    )
    foreach ($Dir in $OtherDirs) {
        if (Test-Path -Path $Dir) {
            Remove-Item -Path $Dir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Output "  [OK] Diretorio residual limpo: $Dir"
        }
    }

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "  WinProvision concluido com sucesso."
    Write-Output "  Todas as otimizacoes e atualizacoes foram aplicadas."
    Write-Output "  O sistema esta pronto para utilizacao imediata."
    Write-Output "============================================================"

} catch {
    Write-Error "Erro no modulo de Otimizacao/Drivers: $_"
    exit 1
}
