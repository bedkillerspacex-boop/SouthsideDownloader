@echo off
chcp 65001 >nul
setlocal

set "SCRIPT_DIR=%~dp0"
powershell -STA -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%download-minecraft-fabric.ps1" %*
exit /b %ERRORLEVEL%
