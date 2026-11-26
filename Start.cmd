@echo off
rem ===========================================================================
rem  RipPatch one-click launcher (double-click this file)
rem
rem  First run : installs deps and builds (a few minutes)
rem  After that: opens the UI directly (a few seconds)
rem
rem  Why a .cmd: Windows does not execute .ps1 on double-click, and the default
rem  execution policy usually blocks it. -ExecutionPolicy Bypass is applied to
rem  this process only; it does not change any system setting.
rem
rem  This file is deliberately pure ASCII: a non-ASCII .cmd name or content gets
rem  mangled by cmd.exe under the OEM code page when handed to powershell -File.
rem  The launcher script is therefore located by wildcard, never by name.
rem ===========================================================================

setlocal enableextensions

cd /d "%~dp0"

rem Prefer PowerShell 7 (pwsh); fall back to the built-in 5.1.
set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"

rem There is exactly one .ps1 in the repository root; find it instead of
rem hard-coding a non-ASCII file name.
set "LAUNCHER="
for %%F in ("%~dp0*.ps1") do (
    if not defined LAUNCHER set "LAUNCHER=%%~fF"
)

if not defined LAUNCHER (
    echo.
    echo [ERROR] Could not find the launcher script ^(*.ps1^) next to this file.
    echo         Keep the .cmd launcher and the .ps1 launcher in the repo root.
    echo.
    pause
    exit /b 1
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER%" %*

if errorlevel 1 (
    echo.
    echo Launcher exited with an error.
    pause
)

endlocal
