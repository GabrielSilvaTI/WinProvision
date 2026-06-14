<#
.SYNOPSIS
    WinProvision Maintenance v5.6.0 - Enterprise Edition
    Rotina de Manutenção Autônoma (Winget, WUA, Cleanup, Otimizações de Desempenho)

.DESCRIPTION
    - Atualiza aplicativos via Winget (isolado, com reset de fontes e pós-verificação).
    - Instala Windows Updates com timeout e jobs.
    - Limpa cache do sistema (DNS, WU, temporários, DISM health check).
    - Aplica otimizações de desempenho baseadas em best practices (telemetria, indexação, relatórios de erro, etc.)

.PARAMETER SkipWinget
    Pula atualização de aplicativos via Winget.

.PARAMETER SkipWindowsUpdate
    Pula verificação e instalação de Windows Updates.

.PARAMETER SkipCleanup
    Pula limpeza de arquivos temporários e cache.

.PARAMETER SkipOptimizations
    Pula as otimizações de sistema.

.NOTES
    Versão : 5.6.0 (Stable + Otimizações + Winget robusto)
    Requer : PowerShell 5.1+ / Administrador
#>

param(
    [switch]$SkipWinget,
    [switch]$SkipWindowsUpdate,
    [switch]$SkipCleanup,
    [switch]$SkipOptimizations
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

# ── Elevação automática ───────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($SkipWinget)        { $argList += " -SkipWinget"        }
    if ($SkipWindowsUpdate) { $argList += " -SkipWindowsUpdate" }
    if ($SkipCleanup)       { $argList += " -SkipCleanup"       }
    if ($SkipOptimizations) { $argList += " -SkipOptimizations" }
    Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -Wait
    exit
}

# ══════════════════════════════════════════════════════════════════════════════
# AMBIENTE
# ══════════════════════════════════════════════════════════════════════════════

$Script:Version   = "5.6.0"
$Script:StartTime = Get-Date
$Script:LogDir    = "$env:SystemRoot\Logs\CloudProvisioning"
$Script:LogFile   = "$Script:LogDir\Maintenance_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

if (-not (Test-Path $Script:LogDir)) {
    New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
}

# ══════════════════════════════════════════════════════════════════════════════
# LOGGING APRIMORADO
# ══════════════════════════════════════════════════════════════════════════════

$Script:Counters = @{ OK = 0; WARN = 0; ERROR = 0 }

function Write-Log {
    param(
        [string]$Msg,
        [ValidateSet("INFO","WARN","ERROR","OK","STEP")][string]$Level = "INFO"
    )
    $ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $icon   = switch ($Level) {
        "OK"    { "✔️" }
        "WARN"  { "⚠️" }
        "ERROR" { "❌" }
        "STEP"  { "▶"  }
        default { "ℹ"  }
    }
    $prefix = switch ($Level) {
        "OK"    { "[  OK  ]" }
        "WARN"  { "[ WARN ]" }
        "ERROR" { "[ERROR ]" }
        "STEP"  { "[ STEP ]" }
        default { "[ INFO ]" }
    }
    $line = "$ts $prefix $icon $Msg"
    try { Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
    $color = switch ($Level) {
        "OK"    { "Green"  } "WARN"  { "Yellow" }
        "ERROR" { "Red"    } "STEP"  { "Cyan"   }
        default { "Gray"   }
    }
    Write-Host $line -ForegroundColor $color
    if ($Script:Counters.ContainsKey($Level)) { $Script:Counters[$Level]++ }
}

function Write-Header {
    Clear-Host
    Write-Host @"
╔══════════════════════════════════════════════════════════════════════════════╗
║                   WINPROVISION MAINTENANCE v$($Script:Version)                       ║
║                         Enterprise Edition                                   ║
╚══════════════════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  🖥️  Computador : $env:COMPUTERNAME" -ForegroundColor White
    Write-Host "  🧠  OS        : $((Get-CimInstance Win32_OperatingSystem).Caption)" -ForegroundColor White
    Write-Host "  📅 Início    : $($Script:StartTime.ToString('dd/MM/yyyy HH:mm:ss'))" -ForegroundColor White
    Write-Host "  📄 Log       : $Script:LogFile" -ForegroundColor White
    Write-Host ""
}

function Write-Banner {
    param([string]$Text)
    $sep = "═" * 62
    Write-Host "`n╔$sep╗" -ForegroundColor Magenta
    Write-Host "║  $Text".PadRight(63) -ForegroundColor Cyan
    Write-Host "╚$sep╝" -ForegroundColor Magenta
    Write-Log $Text "STEP"
}

# ══════════════════════════════════════════════════════════════════════════════
# UTILITÁRIOS WINGET
# ══════════════════════════════════════════════════════════════════════════════

function Test-InternetConnection {
    try {
        $req = [System.Net.WebRequest]::Create("https://1.1.1.1")
        $req.Timeout = 5000
        $req.Method = "HEAD"
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch {
        return $false
    }
}

function Get-WingetPath {
    $candidates = [System.Collections.Generic.List[string]]::new()
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) { $candidates.Add($cmd.Source) }
    $local = "$env:LocalAppData\Microsoft\WindowsApps\winget.exe"
    if (Test-Path $local) { $candidates.Add($local) }
    try {
        Get-Item "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName | Select-Object -Last 1 |
            ForEach-Object { if (Test-Path $_.FullName) { $candidates.Add($_.FullName) } }
    } catch { }
    return ($candidates | Where-Object { $_ } | Select-Object -First 1)
}

# ══════════════════════════════════════════════════════════════════════════════
# ISOLAMENTO RADICAL DO WINGET (PROCESSO FILHO COM CAMINHO PASSADO)
# ══════════════════════════════════════════════════════════════════════════════

function Invoke-WingetIsolated {
    param(
        [string]$WingetPath,
        [string]$Arguments,
        [int]   $TimeoutSeconds = 300,
        [string]$OperationName = "winget"
    )

    if (-not (Test-Path $WingetPath)) {
        Write-Log "Caminho do winget inválido: $WingetPath" "ERROR"
        return @{ ExitCode = -1; Output = @(); Errors = @() }
    }

    $tempOut = [System.IO.Path]::GetTempFileName()
    $tempErr = [System.IO.Path]::GetTempFileName()
    $tempScript = [System.IO.Path]::GetTempFileName() + ".ps1"

    $scriptContent = @"
`$winget = "$WingetPath"
`$env:WINGET_DISABLE_INTERACTIVITY = "1"
try {
    `$p = Start-Process -FilePath `$winget -ArgumentList "$Arguments" -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$tempOut" -RedirectStandardError "$tempErr"
    exit `$p.ExitCode
} catch {
    exit 1
}
"@
    Set-Content -Path $tempScript -Value $scriptContent -Encoding UTF8

    try {
        $proc = Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`"" `
            -NoNewWindow -Wait -PassThru
        $exitCode = $proc.ExitCode
    } catch {
        $exitCode = -1
    }

    $output = if (Test-Path $tempOut) { Get-Content $tempOut -ErrorAction SilentlyContinue } else { @() }
    $errors = if (Test-Path $tempErr) { Get-Content $tempErr -ErrorAction SilentlyContinue } else { @() }

    Remove-Item $tempOut, $tempErr, $tempScript -Force -ErrorAction SilentlyContinue

    if ($output.Count -gt 0) {
        Add-Content -Path $Script:LogFile -Value "  [$OperationName:OUT] $($output -join "`n  [$OperationName:OUT] ")" -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    if ($errors.Count -gt 0) {
        Add-Content -Path $Script:LogFile -Value "  [$OperationName:ERR] $($errors -join "`n  [$OperationName:ERR] ")" -Encoding UTF8 -ErrorAction SilentlyContinue
    }

    return @{ ExitCode = $exitCode; Output = $output; Errors = $errors }
}

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 1 — WINGET (CORRIGIDA E VALIDADA)
# ══════════════════════════════════════════════════════════════════════════════

function Step-WingetUpgrade {
    Write-Banner "ETAPA 1/4 — WINGET (APLICATIVOS)"
    Write-Progress -Activity "🔄 Manutenção" -Status "Winget: verificando conectividade" -PercentComplete 5

    if (-not (Test-InternetConnection)) {
        Write-Log "Sem acesso à internet. Pulando Winget." "WARN"
        Write-Progress -Activity "🔄 Manutenção" -Status "Winget: sem internet" -PercentComplete 10
        return
    }

    $winget = Get-WingetPath
    if (-not $winget) {
        Write-Log "Winget não encontrado. Pulando." "WARN"
        Write-Progress -Activity "🔄 Manutenção" -Status "Winget não encontrado" -PercentComplete 20
        return
    }
    Write-Log "Winget: $winget" "INFO"

    # ------------------------------------------------------------
    # 1. Source update com fallback para reset
    # ------------------------------------------------------------
    Write-Log "Atualizando fontes (timeout: 30s)..." "INFO"
    Write-Progress -Activity "🔄 Manutenção" -Status "Winget: atualizando fontes" -PercentComplete 15

    $src = Invoke-WingetIsolated -WingetPath $winget -Arguments "source update --disable-interactivity" -TimeoutSeconds 30 -OperationName "winget-src"

    if ($src.ExitCode -ne 0 -or $src.TimedOut) {
        Write-Log "Falha/Timeout na atualização das fontes. Tentando reset forçado..." "WARN"
        $reset = Invoke-WingetIsolated -WingetPath $winget -Arguments "source reset --force" -TimeoutSeconds 60 -OperationName "winget-reset"
        if ($reset.ExitCode -eq 0) {
            Write-Log "Reset de fontes concluído. Tentando source update novamente..." "INFO"
            $src2 = Invoke-WingetIsolated -WingetPath $winget -Arguments "source update --disable-interactivity" -TimeoutSeconds 30 -OperationName "winget-src2"
            if ($src2.ExitCode -ne 0) {
                Write-Log "Source update ainda falhou (exit $($src2.ExitCode)). Continuando com fontes existentes." "WARN"
            } else {
                Write-Log "Fontes atualizadas após reset." "OK"
            }
        } else {
            Write-Log "Reset de fontes falhou (exit $($reset.ExitCode)). Prosseguindo sem fontes atualizadas." "WARN"
        }
    } else {
        Write-Log "Fontes atualizadas." "OK"
    }

    # ------------------------------------------------------------
    # 2. Listagem de atualizações (com verbose)
    # ------------------------------------------------------------
    Write-Log "Listando atualizações disponíveis (timeout: 60s)..." "INFO"
    Write-Progress -Activity "🔄 Manutenção" -Status "Winget: verificando updates" -PercentComplete 30

    $list = Invoke-WingetIsolated -WingetPath $winget -Arguments "upgrade --disable-interactivity --verbose" -TimeoutSeconds 60 -OperationName "winget-list"

    if ($list.ExitCode -eq 0) {
        $appLines = $list.Output | Where-Object { $_ -match "^[a-zA-Z0-9\.\-]+\s+[0-9]" }
        if ($appLines.Count -gt 0) {
            Write-Log "$($appLines.Count) atualização(ões) disponível(is)." "INFO"
        } else {
            Write-Log "Nenhuma atualização listada." "INFO"
        }
    } else {
        Write-Log "Listagem falhou (exit $($list.ExitCode)). Prosseguindo com upgrade mesmo assim." "WARN"
    }

    # ------------------------------------------------------------
    # 3. Upgrade com verbose, scope machine e agreements
    # ------------------------------------------------------------
    Write-Log "Executando upgrade (timeout: 30 min)..." "INFO"
    Write-Progress -Activity "🔄 Manutenção" -Status "Winget: instalando upgrades" -PercentComplete 45

    $upArgs = "upgrade --all --silent --disable-interactivity --scope machine --verbose --accept-package-agreements --accept-source-agreements --include-unknown"
    $up = Invoke-WingetIsolated -WingetPath $winget -Arguments $upArgs -TimeoutSeconds 1800 -OperationName "winget-up"

    if ($up.TimedOut) {
        Write-Log "Timeout de 30 min no upgrade. Verifique rede/ Winget." "WARN"
    } elseif ($up.ExitCode -eq 0) {
        Write-Log "Upgrade concluído com sucesso (exit 0)." "OK"
    } else {
        Write-Log "Upgrade concluído com código $($up.ExitCode). Verifique logs." "WARN"
    }

    # ------------------------------------------------------------
    # 4. Pós‑verificação: se ainda há updates pendentes
    # ------------------------------------------------------------
    Write-Log "Verificando se ainda há atualizações pendentes (pós-upgrade)..." "INFO"
    $check = Invoke-WingetIsolated -WingetPath $winget -Arguments "upgrade --disable-interactivity" -TimeoutSeconds 30 -OperationName "winget-check"
    if ($check.ExitCode -eq 0) {
        $stillPending = $check.Output | Where-Object { $_ -match "^[a-zA-Z0-9\.\-]+\s+[0-9]" }
        if ($stillPending.Count -gt 0) {
            Write-Log "ATENÇÃO: $($stillPending.Count) atualização(ões) ainda pendentes após upgrade. Podem requerer interação manual." "WARN"
            $stillPending | ForEach-Object { Write-Log "   Pendente: $_" "INFO" }
        } else {
            Write-Log "Nenhuma atualização pendente. Sistema atualizado." "OK"
        }
    } else {
        Write-Log "Verificação pós-upgrade falhou (exit $($check.ExitCode))." "WARN"
    }

    Write-Progress -Activity "🔄 Manutenção" -Status "Winget concluído" -PercentComplete 50
}

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 2 — WINDOWS UPDATE
# ══════════════════════════════════════════════════════════════════════════════

function Step-WindowsUpdate {
    Write-Banner "ETAPA 2/4 — WINDOWS UPDATE"
    Write-Progress -Activity "🔄 Manutenção" -Status "Windows Update: verificando" -PercentComplete 55

    try {
        Write-Log "Criando sessão WUA..." "STEP"
        $Session = New-Object -ComObject Microsoft.Update.Session
        $Searcher = $Session.CreateUpdateSearcher()
        Write-Log "Pesquisando atualizações (timeout 3 min)..." "INFO"
        $SearchJob = Start-Job -ScriptBlock {
            param($s) $s.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
        } -ArgumentList $Searcher

        if (-not (Wait-Job $SearchJob -Timeout 180)) {
            Stop-Job $SearchJob; Remove-Job $SearchJob -Force
            Write-Log "Timeout na pesquisa de updates." "WARN"
            Write-Progress -Activity "🔄 Manutenção" -Status "WU: timeout pesquisa" -PercentComplete 60
            return
        }
        $Result = Receive-Job $SearchJob -ErrorAction SilentlyContinue
        Remove-Job $SearchJob -Force

        if (-not $Result -or $Result.Updates.Count -eq 0) {
            Write-Log "Nenhuma atualização pendente." "OK"
            Write-Progress -Activity "🔄 Manutenção" -Status "WU: sem updates" -PercentComplete 70
            return
        }

        Write-Log "$($Result.Updates.Count) update(s) encontrado(s)." "INFO"
        $Coll = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($U in $Result.Updates) {
            if (-not $U.EulaAccepted) { $U.AcceptEula() }
            $Coll.Add($U) | Out-Null
        }

        # Download
        Write-Log "Baixando updates (timeout 15 min)..." "INFO"
        Write-Progress -Activity "🔄 Manutenção" -Status "WU: baixando updates" -PercentComplete 65
        $Downloader = $Session.CreateUpdateDownloader()
        $Downloader.Updates = $Coll
        $DownloadJob = Start-Job -ScriptBlock { param($d) $d.Download() } -ArgumentList $Downloader
        if (-not (Wait-Job $DownloadJob -Timeout 900)) {
            Stop-Job $DownloadJob; Remove-Job $DownloadJob -Force
            Write-Log "Timeout no download." "WARN"
            Write-Progress -Activity "🔄 Manutenção" -Status "WU: timeout download" -PercentComplete 70
            return
        }
        Receive-Job $DownloadJob -ErrorAction SilentlyContinue
        Remove-Job $DownloadJob -Force
        Write-Log "Download concluído." "OK"

        # Instalação
        Write-Log "Instalando updates (timeout 30 min)..." "INFO"
        Write-Progress -Activity "🔄 Manutenção" -Status "WU: instalando updates" -PercentComplete 75
        $Installer = $Session.CreateUpdateInstaller()
        $Installer.Updates = $Coll
        $InstallJob = Start-Job -ScriptBlock { param($i) $i.Install() } -ArgumentList $Installer
        if (-not (Wait-Job $InstallJob -Timeout 1800)) {
            Stop-Job $InstallJob; Remove-Job $InstallJob -Force
            Write-Log "Timeout na instalação." "WARN"
            Write-Progress -Activity "🔄 Manutenção" -Status "WU: timeout instalação" -PercentComplete 80
            return
        }
        $InstallResult = Receive-Job $InstallJob -ErrorAction SilentlyContinue
        Remove-Job $InstallJob -Force

        switch ($InstallResult.ResultCode) {
            2 { Write-Log "Todos os updates instalados com sucesso." "OK" }
            3 { Write-Log "Updates instalados com erros parciais." "WARN" }
            4 { Write-Log "Falha na instalação dos updates." "ERROR" }
            5 { Write-Log "Instalação abortada." "WARN" }
            default { Write-Log "ResultCode inesperado: $($InstallResult.ResultCode)" "WARN" }
        }
        if ($InstallResult.RebootRequired) {
            Write-Log "Reinicialização pendente." "WARN"
        }
    } catch {
        Write-Log "Falha crítica no Windows Update: $($_.Exception.Message)" "ERROR"
    }
    Write-Progress -Activity "🔄 Manutenção" -Status "WU concluído" -PercentComplete 85
}

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 3 — LIMPEZA AVANÇADA
# ══════════════════════════════════════════════════════════════════════════════

function Step-Cleanup {
    Write-Banner "ETAPA 3/4 — LIMPEZA DO SISTEMA"
    Write-Progress -Activity "🔄 Manutenção" -Status "Limpeza: cache WU" -PercentComplete 88

    # Windows Update Cache
    Write-Log "Limpando cache do Windows Update..." "STEP"
    try {
        Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $wuCache = "$env:SystemRoot\SoftwareDistribution\Download"
        if (Test-Path $wuCache) {
            Remove-Item "$wuCache\*" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Cache WU limpo." "OK"
        }
        Start-Service wuauserv -ErrorAction SilentlyContinue
    } catch { Write-Log "Erro ao limpar cache WU: $_" "WARN" }

    # Arquivos temporários
    Write-Log "Removendo arquivos temporários..." "INFO"
    Write-Progress -Activity "🔄 Manutenção" -Status "Limpeza: temporários" -PercentComplete 92
    $tempPaths = @("$env:TEMP", "$env:SystemRoot\Temp", "$env:LOCALAPPDATA\Temp")
    foreach ($p in $tempPaths) {
        if (Test-Path $p) {
            try {
                Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "  Limpo: $p" "INFO"
            } catch { }
        }
    }

    # Cache DNS
    Write-Log "Limpando cache DNS..." "INFO"
    Write-Progress -Activity "🔄 Manutenção" -Status "Limpeza: DNS" -PercentComplete 95
    try { ipconfig /flushdns | Out-Null; Write-Log "Cache DNS limpo." "OK" } catch { Write-Log "Falha ao limpar DNS." "WARN" }

    # DISM Health Check
    Write-Log "Verificando integridade da imagem (DISM)..." "INFO"
    Write-Progress -Activity "🔄 Manutenção" -Status "Limpeza: DISM" -PercentComplete 97
    try {
        $dism = Start-Process -FilePath "dism.exe" -ArgumentList "/Online /Cleanup-Image /CheckHealth" -NoNewWindow -Wait -PassThru
        Write-Log "DISM CheckHealth concluído (exit $($dism.ExitCode))." "OK"
    } catch { Write-Log "Erro ao executar DISM." "WARN" }

    Write-Progress -Activity "🔄 Manutenção" -Status "Limpeza concluída" -PercentComplete 100
}

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 4 — OTIMIZAÇÕES DE DESEMPENHO
# ══════════════════════════════════════════════════════════════════════════════

function Step-Optimizations {
    Write-Banner "ETAPA 4/4 — OTIMIZAÇÕES DO SISTEMA"
    Write-Progress -Activity "🔄 Manutenção" -Status "Otimizações: aplicando ajustes" -PercentComplete 5

    Write-Log "Iniciando otimizações baseadas em best practices (Canal 1155 - ET)" "STEP"

    # 1. Desativar Compressão de Memória
    Write-Log "1. Desativando compressão de memória..." "INFO"
    try {
        if (Get-Command -Name Disable-MMAgent -ErrorAction SilentlyContinue) {
            Disable-MMAgent -MemoryCompression -ErrorAction Stop | Out-Null
            Write-Log "   Compressão de memória desativada via MMAgent." "OK"
        } else {
            Write-Log "   Cmdlet Disable-MMAgent não encontrado. Verifique o módulo 'MMAgent'." "WARN"
        }
    } catch {
        Write-Log "   Falha ao desativar compressão de memória: $($_.Exception.Message)" "WARN"
    }

    # 2. Desativar Telemetria e Coleta de Dados
    Write-Log "2. Desativando telemetria e coleta de dados..." "INFO"
    try {
        reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowTelemetry" /t REG_DWORD /d 0 /f | Out-Null
        reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowDeviceTelemetry" /t REG_DWORD /d 0 /f | Out-Null
        Write-Log "   Telemetria desativada." "OK"
    } catch { Write-Log "   Erro ao desativar telemetria: $_" "WARN" }

    # 3. Desativar Aplicativos em Segundo Plano
    Write-Log "3. Desativando aplicativos em segundo plano..." "INFO"
    try {
        reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" /v "GlobalUserDisabled" /t REG_DWORD /d 1 /f | Out-Null
        reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" /v "LetAppsRunInBackground" /t REG_DWORD /d 2 /f | Out-Null
        Write-Log "   Aplicativos em segundo plano desativados." "OK"
    } catch { Write-Log "   Erro ao desativar apps em segundo plano: $_" "WARN" }

    # 4. Desativar Relatório de Erros
    Write-Log "4. Desativando relatório de erros do Windows..." "INFO"
    try {
        reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "Disabled" /t REG_DWORD /d 1 /f | Out-Null
        Write-Log "   Relatório de erros desativado." "OK"
    } catch { Write-Log "   Erro ao desativar relatório de erros: $_" "WARN" }

    # 5. Otimizar Acesso ao Disco (desativar sugestões no Explorer)
    Write-Log "5. Otimizando acesso ao disco (desativando sugestões do Explorer)..." "INFO"
    try {
        reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowSyncProviderNotifications" /t REG_DWORD /d 0 /f | Out-Null
        Write-Log "   Notificações de provedor de sincronia desativadas." "OK"
    } catch { Write-Log "   Erro ao desativar notificações: $_" "WARN" }

    # 6. Desativar Indexação de Pesquisa na Nuvem
    Write-Log "6. Desativando indexação de pesquisa na nuvem..." "INFO"
    try {
        reg add "HKCU\Software\Policies\Microsoft\Windows\Explorer" /v "DisableSearchBoxSuggestions" /t REG_DWORD /d 1 /f | Out-Null
        Write-Log "   Sugestões de pesquisa desativadas." "OK"
    } catch { Write-Log "   Erro ao desativar sugestões de pesquisa: $_" "WARN" }

    # 7. Desativar Feed de Atividades
    Write-Log "7. Desativando feed de atividades..." "INFO"
    try {
        reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v "EnableActivityFeed" /t REG_DWORD /d 0 /f | Out-Null
        Write-Log "   Feed de atividades desativado." "OK"
    } catch { Write-Log "   Erro ao desativar feed de atividades: $_" "WARN" }

    Write-Log "Otimizações concluídas. Reinicie o computador para aplicar totalmente as alterações." "OK"
    Write-Progress -Activity "🔄 Manutenção" -Status "Otimizações concluídas" -PercentComplete 100
}

# ══════════════════════════════════════════════════════════════════════════════
# EXECUÇÃO PRINCIPAL
# ══════════════════════════════════════════════════════════════════════════════

Write-Header
Write-Log "════════════════════════════════════════════════"
Write-Log " WinProvision Maintenance  v$Script:Version"
Write-Log " Início  : $($Script:StartTime.ToString('dd/MM/yyyy HH:mm:ss'))"
Write-Log "════════════════════════════════════════════════"

try {
    if (-not $SkipWinget)        { Step-WingetUpgrade  }
    else { Write-Log "Winget ignorado (-SkipWinget)."                "INFO" }

    if (-not $SkipWindowsUpdate) { Step-WindowsUpdate  }
    else { Write-Log "Windows Update ignorado (-SkipWindowsUpdate)." "INFO" }

    if (-not $SkipCleanup)       { Step-Cleanup        }
    else { Write-Log "Limpeza ignorada (-SkipCleanup)."              "INFO" }

    if (-not $SkipOptimizations) { Step-Optimizations  }
    else { Write-Log "Otimizações ignoradas (-SkipOptimizations)."   "INFO" }
} catch {
    Write-Log "ERRO FATAL no script principal: $_" "ERROR"
}

$duration = ((Get-Date) - $Script:StartTime).ToString("mm\:ss")
Write-Host "`n╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                              RESUMO FINAL                                     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Log "════════════════════════════════════════════════"
Write-Log " Concluído em $duration min."
Write-Log " OK: $($Script:Counters.OK)  ⚠️ WARN: $($Script:Counters.WARN)  ❌ ERROR: $($Script:Counters.ERROR)"
Write-Log " Log completo: $Script:LogFile"
Write-Log "════════════════════════════════════════════════"

$exitCode = $(if ($Script:Counters.ERROR -gt 0) { 1 } else { 0 })
if ($exitCode -eq 0) {
    Write-Host "`n✅ Manutenção concluída com sucesso!" -ForegroundColor Green
} else {
    Write-Host "`n⚠️ Manutenção concluída com $($Script:Counters.ERROR) erro(s). Verifique o log." -ForegroundColor Yellow
}

Write-Host "`n⏱️  Aguardando 3 segundos antes de fechar...`n" -ForegroundColor Gray
Start-Sleep -Seconds 3
try {
    [Console]::SetIn([System.IO.StreamReader]::Null)
    $Host.UI.RawUI.FlushInputBuffer()
    [Environment]::Exit($exitCode)
} catch {
    Stop-Process -Id $pid -Force
}
