@echo off
rem ======================================================================
rem  VDI-ImageMaint - start here (double-click).
rem  Asks for administrator rights, unblocks downloaded files and opens
rem  the step-by-step menu (Scripts\Start-Menu.ps1, English / Polish).
rem  ASCII only on purpose: no code page switching in cmd.
rem ======================================================================
setlocal EnableExtensions DisableDelayedExpansion
set "HERE=%~dp0"

net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator rights...
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

if not exist "%HERE%Scripts\Start-Menu.ps1" (
    echo Scripts\Start-Menu.ps1 not found - copy the whole install folder to C:\install.
    pause
    exit /b 1
)

rem Files downloaded from the internet carry a "blocked" mark (scripts and installers)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%HERE:~0,-1%' -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" <nul

title VDI-ImageMaint
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%Scripts\Start-Menu.ps1"
exit /b %ERRORLEVEL%
