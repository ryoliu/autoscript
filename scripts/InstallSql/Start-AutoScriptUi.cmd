@echo off
setlocal DisableDelayedExpansion

if not exist "%~dp0Start-AutoScriptUi.ps1" (
    echo ERROR: Script not found: "%~dp0Start-AutoScriptUi.ps1"
    pause
    exit /b 1
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Start-AutoScriptUi.ps1"
set "autoScriptExitCode=%ERRORLEVEL%"

if not "%autoScriptExitCode%"=="0" (
    echo ERROR: AutoScript UI exited with code %autoScriptExitCode%.
    pause
)

exit /b %autoScriptExitCode%
