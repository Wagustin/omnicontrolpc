@echo off
rem ============================================================
rem  OmniControl PC - Windows bootstrap installer
rem  Delegates to install.ps1. Every path is quoted so spaces,
rem  parentheses and ampersands in the project path are safe.
rem ============================================================
setlocal EnableExtensions
chcp 65001 >nul 2>&1
title OmniControl PC Installer

set "SCRIPT_DIR=%~dp0"

if not exist "%SCRIPT_DIR%install.ps1" (
    echo [ERROR] install.ps1 was not found next to this file:
    echo         "%SCRIPT_DIR%"
    goto :fail
)

set "PS_EXE="
where pwsh.exe >nul 2>&1
if not errorlevel 1 set "PS_EXE=pwsh.exe"
if not defined PS_EXE (
    where powershell.exe >nul 2>&1
    if not errorlevel 1 set "PS_EXE=powershell.exe"
)
if not defined PS_EXE (
    if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
        set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
    )
)
if not defined PS_EXE (
    echo [ERROR] PowerShell 5.1 or newer is required but was not found.
    goto :fail
)

echo.
echo ============================================================
echo   OmniControl PC - Windows Installer
echo ============================================================
echo   PowerShell : "%PS_EXE%"
echo   Project    : "%SCRIPT_DIR%"
echo.

rem pushd also maps a UNC path to a temporary drive, so running the
rem installer directly from a network share keeps working.
pushd "%SCRIPT_DIR%" 2>nul
if errorlevel 1 (
    echo [ERROR] Cannot open the project directory:
    echo         "%SCRIPT_DIR%"
    goto :fail
)

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%install.ps1" %*
set "RC=%ERRORLEVEL%"
popd

if not "%RC%"=="0" goto :failed

echo.
echo [OK] Installation finished successfully.
goto :end

:failed
echo.
echo [ERROR] Installation failed with exit code %RC%.
echo         Read the log in "%SCRIPT_DIR%.omnicontrol\install.log".

:end
rem Do not pause in unattended runs. -NoPause may appear anywhere.
set "NOPAUSE=0"
if /I "%OMNICONTROL_NO_PAUSE%"=="1" set "NOPAUSE=1"
call :parse_args %*
if "%NOPAUSE%"=="0" (
    echo.
    pause
)
endlocal & exit /b %RC%

:parse_args
if "%~1"=="" goto :eof
if /I "%~1"=="-NoPause" set "NOPAUSE=1"
shift
goto :parse_args

:fail
set "RC=1"
goto :end
