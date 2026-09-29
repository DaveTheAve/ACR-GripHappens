@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0"
if not exist "%~dp0app\Restore-ACR-Original.ps1" (
  echo Extract the ENTIRE ZIP first, then open this file from the extracted folder.
  echo Keep the app folder next to this launcher.
  pause
  exit /b 1
)
set "ACR_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "ACR_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%ACR_PS%" (
  echo Windows PowerShell is unavailable on this computer. No files were changed.
  pause
  exit /b 1
)
"%ACR_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\Restore-ACR-Original.ps1"
exit /b %errorlevel%
