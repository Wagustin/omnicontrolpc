@echo off
setlocal enabledelayedexpansion
title Instalador OmniControl PC
color 0A

echo ==============================================================
echo       OMNICONTROL PC - INSTALADOR RAPIDO PARA WINDOWS
echo ==============================================================
echo.
echo Este instalador configurara OmniControl PC en tu equipo.
echo No requiere configuracion manual ni conocimientos tecnicos.
echo.

where powershell >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] No se encontro PowerShell en este sistema.
    pause
    exit /b 1
)

echo Iniciando instalacion automatizada...
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { [ScriptBlock]::Create((Get-Content -Path '%~dp0install.ps1' -Raw)).Invoke() }"

if %errorlevel% equ 0 (
    echo.
    echo ==============================================================
    echo  Listo. Ya puedes abrir 'OmniControl PC' desde tu Escritorio!
    echo ==============================================================
) else (
    echo.
    echo [!] Hubo un detalle durante la instalacion. Revisa los mensajes arriba.
)

pause
