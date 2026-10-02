@echo off
setlocal
set "quotaShell=%ProgramFiles%\PowerShell\7\pwsh.exe"
if exist "%quotaShell%" goto ready
set "quotaShell=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe"
if exist "%quotaShell%" goto ready
set "quotaShell=pwsh.exe"
:ready
if "%~1"=="" (
  "%quotaShell%" -NoProfile -File "%~dp0Setup.ps1"
  pause
) else (
  "%quotaShell%" -NoProfile -File "%~dp0Watch-Quota.ps1" -Action %1
)
