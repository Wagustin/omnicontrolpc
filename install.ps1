# =====================================================================
# OmniControl PC - Windows Automated Installer
# Ultralight (<35MB) On-Device System Assistant & Tool Engine
# =====================================================================

$ErrorActionPreference = "Stop"

Write-Host @"
  ==============================================================
    ____                  _  ______            __             __ 
   / __ \____ ___  ____  (_)/ ____/___  ____  / /__________  / / 
  / / / / __ `__ \/ __ \/ // /   / __ \/ __ \/ __/ ___/ __ \/ /  
 / /_/ / / / / / / / / / // /___/ /_/ / / / / /_/ /  / /_/ / /   
 \____/_/ /_/ /_/_/ /_/_(_)____/\____/_/ /_/\__/_/   \____/_/    
                                            PC Edition (Windows)
  ==============================================================
"@ -ForegroundColor Cyan

$InstallDir = "$env:USERPROFILE\.omnicontrolpc"
Write-Host "[*] Carpeta de instalación: $InstallDir" -ForegroundColor Yellow

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# 1. Verificar Git y Clonar/Descargar Repositorio
Write-Host "[1/4] Descargando componentes de OmniControl PC..." -ForegroundColor Green
if (Get-Command git -ErrorAction SilentlyContinue) {
    if (Test-Path "$InstallDir\.git") {
        Write-Host "    - Repositorio existente. Actualizando..." -ForegroundColor Gray
        git -C $InstallDir pull origin main
    } else {
        git clone https://github.com/Wagustin/omnicontrolpc.git $InstallDir
    }
} else {
    Write-Host "    - Git no detectado. Descargando paquete ZIP oficial..." -ForegroundColor Gray
    $ZipPath = "$env:TEMP\omnicontrolpc.zip"
    Invoke-WebRequest -Uri "https://github.com/Wagustin/omnicontrolpc/archive/refs/heads/main.zip" -OutFile $ZipPath
    Expand-Archive -Path $ZipPath -DestinationPath "$env:TEMP\omnicontrol_extracted" -Force
    Copy-Item -Path "$env:TEMP\omnicontrol_extracted\omnicontrolpc-main\*" -Destination $InstallDir -Recurse -Force
    Remove-Item -Path $ZipPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$env:TEMP\omnicontrol_extracted" -Recurse -Force -ErrorAction SilentlyContinue
}

# 2. Verificar Python
Write-Host "[2/4] Verificando entorno de ejecución..." -ForegroundColor Green
$PythonCmd = $null
if (Get-Command python -ErrorAction SilentlyContinue) {
    $PythonCmd = "python"
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    $PythonCmd = "py"
} else {
    Write-Host "    - Python no encontrado. Instalando Python automáticamente vía winget..." -ForegroundColor Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Python.Python.3.11 --exact --silent --accept-package-agreements --accept-source-agreements
        $PythonCmd = "python"
    } else {
        Write-Host "    [!] Por favor instala Python desde https://www.python.org/downloads/ para continuar." -ForegroundColor Red
        exit 1
    }
}

# 3. Instalar librerías ultra-ligeras
Write-Host "[3/4] Instalando runtime de Needle 3..." -ForegroundColor Green
& $PythonCmd -m pip install --upgrade pip --quiet
& $PythonCmd -m pip install cactus-needle --quiet

# Descargar Everything CLI (es.exe) para búsqueda en <5ms en NTFS
$EsPath = "$InstallDir\es.exe"
if (-not (Test-Path $EsPath)) {
    Write-Host "    - Instalando indexador de búsqueda ultrarrápido (es.exe)..." -ForegroundColor Gray
    try {
        $EsZip = "$env:TEMP\es.zip"
        Invoke-WebRequest -Uri "https://www.voidtools.com/ES-1.1.0.28.x64.zip" -OutFile $EsZip
        Expand-Archive -Path $EsZip -DestinationPath "$env:TEMP\es_extracted" -Force
        Copy-Item -Path "$env:TEMP\es_extracted\es.exe" -Destination $EsPath -Force
        Remove-Item -Path $EsZip -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$env:TEMP\es_extracted" -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "    - Fallback: se utilizará PowerShell para búsqueda de archivos." -ForegroundColor DarkGray
    }
}

# 4. Crear lanzador y acceso directo en el Escritorio
Write-Host "[4/4] Creando acceso directo en el Escritorio..." -ForegroundColor Green

$LauncherBat = "$InstallDir\iniciar_omnicontrol.bat"
$BatContent = @"
@echo off
title OmniControl PC - Asistente de Sistema
color 0B
echo ==============================================================
echo           OMNICONTROL PC - ASISTENTE ACTIVO
echo ==============================================================
echo.
cd /d "$InstallDir"
:loop
set /p "QUERY=Dime una orden (ej. 'sube el volumen al 50%%' o 'salir'): "
if /i "%QUERY%"=="salir" goto end
if /i "%QUERY%"=="exit" goto end
echo Procesando con Needle 3...
$PythonCmd jarvis_client.py "%QUERY%"
echo.
goto loop
:end
exit
"@
Set-Content -Path $LauncherBat -Value $BatContent -Encoding ASCII

# Crear acceso directo .lnk en el Escritorio
try {
    $WshShell = New-Object -ComObject WScript.Shell
    $DesktopPath = [Environment]::GetFolderPath("Desktop")
    $Shortcut = $WshShell.CreateShortcut("$DesktopPath\OmniControl PC.lnk")
    $Shortcut.TargetPath = $LauncherBat
    $Shortcut.WorkingDirectory = $InstallDir
    $Shortcut.Description = "OmniControl PC - Asistente de Sistema Ultra-ligero"
    $Shortcut.Save()
    Write-Host "    [✓] Acceso directo creado: $DesktopPath\OmniControl PC.lnk" -ForegroundColor Green
} catch {
    Write-Host "    - No se pudo crear el acceso directo en el escritorio. Usa: $LauncherBat" -ForegroundColor Yellow
}

Write-Host @"

  ==============================================================
    ¡INSTALACIÓN COMPLETADA CON ÉXITO!
  ==============================================================
  Puedes iniciar OmniControl PC haciendo doble clic en el icono 
  'OmniControl PC' de tu Escritorio, o ejecutando:
  
    cd $InstallDir
    $PythonCmd jarvis_client.py "tu orden aquí"
  ==============================================================
"@ -ForegroundColor Cyan
