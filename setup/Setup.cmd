@echo off
title WinProvision Orchestrator
set LOGFILE=C:\Windows\Temp\WinProvision_Log.txt

echo [%DATE% %TIME%] Iniciando orquestrador >> "%LOGFILE%"
echo Executando na ordem: Theme, Bootstrap, Office >> "%LOGFILE%"

:: Theme
echo [%DATE% %TIME%] Executando Theme.ps1... >> "%LOGFILE%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/setup/theme.ps1' | iex"
if %errorlevel% neq 0 (
    echo [%DATE% %TIME%] ERRO no Theme (codigo: %errorlevel%) >> "%LOGFILE%"
) else (
    echo [%DATE% %TIME%] Theme concluido >> "%LOGFILE%"
)

:: Bootstrap
echo [%DATE% %TIME%] Executando Bootstrap.ps1... >> "%LOGFILE%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/main/setup/Bootstrap.ps1' | iex"
if %errorlevel% neq 0 (
    echo [%DATE% %TIME%] ERRO no Bootstrap (codigo: %errorlevel%) >> "%LOGFILE%"
) else (
    echo [%DATE% %TIME%] Bootstrap concluido >> "%LOGFILE%"
)

:: Office
echo [%DATE% %TIME%] Executando Office.ps1... >> "%LOGFILE%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/setup/Office.ps1' | iex"
if %errorlevel% neq 0 (
    echo [%DATE% %TIME%] ERRO no Office (codigo: %errorlevel%) >> "%LOGFILE%"
) else (
    echo [%DATE% %TIME%] Office concluido >> "%LOGFILE%"
)

echo [%DATE% %TIME%] Orquestrador finalizado >> "%LOGFILE%"
exit /b 0
