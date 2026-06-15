@echo off
title WinProvision Orchestrator
set LOGFILE=C:\Windows\Temp\WinProvision_Log.txt

:: Limpa a tela e mostra cabeçalho
cls
powershell -Command "Write-Host '══════════════════════════════════════════════════════════════' -ForegroundColor Cyan"
powershell -Command "Write-Host '         WINPROVISION ORCHESTRATOR - EXECUÇÃO SEQUENCIAL' -ForegroundColor White"
powershell -Command "Write-Host '══════════════════════════════════════════════════════════════' -ForegroundColor Cyan"
echo.

:: Início do log
echo [%DATE% %TIME%] Iniciando orquestrador >> "%LOGFILE%"
echo Executando na ordem: Theme, Bootstrap, Office, Maintenance >> "%LOGFILE%"

:: ==========================================
:: 1. Theme (com correção do Stop-Process)
:: ==========================================
powershell -Command "Write-Host '▶ Executando Theme.ps1...' -ForegroundColor Yellow"
echo [%DATE% %TIME%] Executando Theme.ps1... >> "%LOGFILE%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& {$url='https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/setup/theme.ps1';$s=(irm $url);$s=$s -replace 'Stop-Process -Id \$pid -Force','exit 0';$f=[IO.Path]::GetTempFileName()+'.ps1';[IO.File]::WriteAllText($f,$s,[Text.Encoding]::UTF8);Unblock-File $f;&$f;del $f}"

if %errorlevel% neq 0 (
    powershell -Command "Write-Host '  ❌ ERRO no Theme' -ForegroundColor Red"
    echo [%DATE% %TIME%] ERRO no Theme (codigo: %errorlevel%) >> "%LOGFILE%"
) else (
    powershell -Command "Write-Host '  ✔️ Theme concluído' -ForegroundColor Green"
    echo [%DATE% %TIME%] Theme concluido >> "%LOGFILE%"
)

:: ==========================================
:: 2. Bootstrap
:: ==========================================
powershell -Command "Write-Host '▶ Executando Bootstrap.ps1...' -ForegroundColor Yellow"
echo [%DATE% %TIME%] Executando Bootstrap.ps1... >> "%LOGFILE%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/main/setup/Bootstrap.ps1' | iex"

if %errorlevel% neq 0 (
    powershell -Command "Write-Host '  ❌ ERRO no Bootstrap' -ForegroundColor Red"
    echo [%DATE% %TIME%] ERRO no Bootstrap (codigo: %errorlevel%) >> "%LOGFILE%"
) else (
    powershell -Command "Write-Host '  ✔️ Bootstrap concluído' -ForegroundColor Green"
    echo [%DATE% %TIME%] Bootstrap concluido >> "%LOGFILE%"
)

:: ==========================================
:: 3. Office
:: ==========================================
powershell -Command "Write-Host '▶ Executando Office.ps1...' -ForegroundColor Yellow"
echo [%DATE% %TIME%] Executando Office.ps1... >> "%LOGFILE%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/setup/Office.ps1' | iex"

if %errorlevel% neq 0 (
    powershell -Command "Write-Host '  ❌ ERRO no Office' -ForegroundColor Red"
    echo [%DATE% %TIME%] ERRO no Office (codigo: %errorlevel%) >> "%LOGFILE%"
) else (
    powershell -Command "Write-Host '  ✔️ Office concluído' -ForegroundColor Green"
    echo [%DATE% %TIME%] Office concluido >> "%LOGFILE%"
)

:: ==========================================
:: 4. Maintenance (Orchestrator)
:: ==========================================
powershell -Command "Write-Host '▶ Executando Maintenance (Orchestrator)...' -ForegroundColor Yellow"
echo [%DATE% %TIME%] Executando Maintenance (Orchestrator)... >> "%LOGFILE%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& {$p='https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/setup/Orchestrator%20Maintenance.ps1';$s=(irm $p);$s=$s-replace'✔️','[OK]'-replace'⚠️','[WARN]'-replace'❌','[ERROR]'-replace'▶','[STEP]'-replace'ℹ','[INFO]';$f=[IO.Path]::GetTempFileName()+'.ps1';[IO.File]::WriteAllText($f,$s,[Text.Encoding]::UTF8);Unblock-File $f;&$f;del $f}"

if %errorlevel% neq 0 (
    powershell -Command "Write-Host '  ❌ ERRO no Maintenance' -ForegroundColor Red"
    echo [%DATE% %TIME%] ERRO no Maintenance (codigo: %errorlevel%) >> "%LOGFILE%"
) else (
    powershell -Command "Write-Host '  ✔️ Maintenance concluído' -ForegroundColor Green"
    echo [%DATE% %TIME%] Maintenance concluido >> "%LOGFILE%"
)

:: ==========================================
:: Finalização
:: ==========================================
powershell -Command "Write-Host '══════════════════════════════════════════════════════════════' -ForegroundColor Cyan"
powershell -Command "Write-Host '  ✅ Todos os scripts foram processados!' -ForegroundColor Green"
powershell -Command "Write-Host '  📄 Log completo: %LOGFILE%' -ForegroundColor White"
powershell -Command "Write-Host '══════════════════════════════════════════════════════════════' -ForegroundColor Cyan"

echo [%DATE% %TIME%] Orquestrador finalizado >> "%LOGFILE%"
timeout /t 5 /nobreak >nul
exit /b 0
