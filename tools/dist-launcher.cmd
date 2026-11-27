@echo off
rem ===========================================================================
rem  RipPatch launcher -- double-click this file to start the program.
rem
rem  The program itself lives in the RipPatch\ folder next to this file.
rem  You do not need to find or run the exe manually.
rem
rem  Why this file exists: the program folder contains ~420 files (the .NET
rem  runtime and its dependencies must sit next to the exe, that is a hard
rem  requirement of the .NET host). Scrolling through them to find the exe is
rem  annoying, so this launcher starts it for you.
rem
rem  This file is pure ASCII on purpose: a .cmd with non-ASCII content gets
rem  mangled by cmd.exe under the OEM code page. Keep it ASCII.
rem ===========================================================================

setlocal enableextensions
cd /d "%~dp0"

set "APP=%~dp0RipPatch\RipPatch.exe"

if not exist "%APP%" (
    echo.
    echo [ERROR] Not found: RipPatch\RipPatch.exe
    echo.
    echo         Run this launcher from the folder you extracted the zip into.
    echo         It must stay next to the RipPatch folder.
    echo.
    pause
    exit /b 1
)

rem Any arguments are passed through, e.g.:
rem   RipPatch.cmd --web --port 5199
start "" /d "%~dp0RipPatch" "%APP%" %*

endlocal
exit /b 0
