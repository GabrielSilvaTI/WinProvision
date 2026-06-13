Clear-Host
Write-Host ""
Write-Host "========================================================"
Write-Host ""
Write-Host "        __  __      _ ______     __  __  ______" -ForegroundColor Cyan
Write-Host "       / / / /___  (_) ____/__  / /_/ / / /  _/" -ForegroundColor Cyan
Write-Host "      / / / / __ \/ / / __/ _ \/ __/ / / // /" -ForegroundColor Cyan
Write-Host "     / /_/ / / / / / /_/ /  __/ /_/ /_/ // /" -ForegroundColor Cyan
Write-Host "     \____/_/ /_/_/\____/\___/\__/\____/___/" -ForegroundColor Cyan
Write-Host "          UniGetUI Package Installer Script" 
Write-Host "        Created with UniGetUI Version 2026.2.0"
Write-Host ""
Write-Host "========================================================"
Write-Host ""
Write-Host "NOTES:" -ForegroundColor Yellow
Write-Host "  - The install process will not be as reliable as importing a bundle with UniGetUI. Expect issues and errors." -ForegroundColor Yellow
Write-Host "  - Packages will be installed with the install options specified at the time of creation of this script." -ForegroundColor Yellow
Write-Host "  - Error/Sucess detection may not be 100% accurate." -ForegroundColor Yellow
Write-Host "  - Some of the packages may require elevation. Some of them may ask for permission, but others may fail. Consider running this script elevated." -ForegroundColor Yellow
Write-Host "  - You can skip confirmation prompts by running this script with the parameter `/DisablePausePrompts` " -ForegroundColor Yellow
Write-Host ""
Write-Host ""
Write-Host ""
Write-Host "This script will attempt to install the following packages:"
Write-Host "  - WinRAR from WinGet"
Write-Host "  - Hydra from WinGet"
Write-Host "  - Steam from WinGet"
Write-Host "  - LocalSend from WinGet"
Write-Host "  - Epson Scan 2 from WinGet"
Write-Host "  - Google Chrome from WinGet"
Write-Host ""
Clear-Host

$success_count=0
$failure_count=0
$commands_run=0
$results=""

$commands= @(
    'cmd.exe /C winget.exe install --id "RARLab.WinRAR" --exact --source winget --accept-source-agreements --disable-interactivity --silent --accept-package-agreements --force',
    'cmd.exe /C winget.exe install --id "HydraLauncher.Hydra" --exact --source winget --accept-source-agreements --disable-interactivity --silent --accept-package-agreements --force',
    'cmd.exe /C winget.exe install --id "Valve.Steam" --exact --source winget --accept-source-agreements --disable-interactivity --silent --accept-package-agreements --force',
    'cmd.exe /C winget.exe install --id "LocalSend.LocalSend" --exact --source winget --accept-source-agreements --disable-interactivity --silent --accept-package-agreements --force',
    'cmd.exe /C winget.exe install --id "EPSON.EpsonScan2" --exact --source winget --accept-source-agreements --disable-interactivity --silent --accept-package-agreements --force',
    'cmd.exe /C winget.exe install --id "Google.Chrome" --exact --source winget --accept-source-agreements --disable-interactivity --silent --accept-package-agreements --force'
)

foreach ($command in $commands) {
    Write-Host "Running: $command" -ForegroundColor Yellow
    cmd.exe /C $command
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[  OK  ] $command" -ForegroundColor Green
        $success_count++
        $results += "$([char]0x1b)[32m[  OK  ] $command`n"
    }
    else {
        Write-Host "[ FAIL ] $command" -ForegroundColor Red
        $failure_count++
        $results += "$([char]0x1b)[31m[ FAIL ] $command`n"
    }
    $commands_run++
    Write-Host ""
}

Write-Host "========================================================"
Write-Host "                  OPERATION SUMMARY"
Write-Host "========================================================"
Write-Host "Total commands run: $commands_run"
Write-Host "Successful: $success_count"
Write-Host "Failed: $failure_count"
Write-Host ""
Write-Host "Details:"
Write-Host "$results$([char]0x1b)[37m"
Write-Host "========================================================"

if ($failure_count -gt 0) {
    Write-Host "Some commands failed. Please check the log above." -ForegroundColor Yellow
}
else {
    Write-Host "All commands executed successfully!" -ForegroundColor Green
}
Write-Host ""
exit $failure_count
