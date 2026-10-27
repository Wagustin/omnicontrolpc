<div align="center">

<img src="assets/omnicontrol-banner.svg" alt="OmniControl PC Animated Banner" width="100%" />

<br/>

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Platform: macOS & Windows](https://img.shields.io/badge/Platform-macOS%20ARM64%20%7C%20Windows%20x64-indigo.svg)]()
[![Model Size](https://img.shields.io/badge/Model%20Weight-35.3%20MB-emerald.svg)]()
[![RAM Consumption](https://img.shields.io/badge/RAM-~94%20MB-purple.svg)]()
[![Inference Latency](https://img.shields.io/badge/Latency-%3C%2028ms-cyan.svg)]()

<p align="center">
  <b>Asistente de sistema y control remoto por herramientas ultra-ligero para macOS y Windows.</b><br/>
  <i>Entrenado para español natural. 100% Offline. Diseñado para correr en cualquier PC, desde una MacBook Pro M-series hasta laptops modestas con Intel Core i3 y 8 GB de RAM.</i>
</p>

---

</div>

## 🌟 ¿Qué es OmniControl PC?

La mayoría de asistentes basados en LLMs requieren GPUs dedicadas pesadas, consumen entre 4 y 16 GB de VRAM o introducen latencias de red de varios segundos al llamar a APIs en la nube.

**OmniControl PC** toma un enfoque radicalmente minimalista y agéntico:
* **⚡ Latencia menor a 28ms:** Ejecuta llamadas deterministas de sistema en milisegundos reales.
* **🪶 Huella mínima (~35 MB en disco, ~94 MB en RAM):** Consume menos memoria que una sola pestaña de navegador web.
* **💻 Funciona en hardware modesto:** Optimizado para instrucciones vectoriales de CPU (AVX2 / SSE4.2). Corre sin esfuerzo en un procesador **Intel Core i3 de 7ma generación con 8 GB de RAM**, así como en **Apple Silicon (M1/M2/M3/M4)**.
* **🇪🇸 Fine-Tuning en Español:** Corrige la supresión de llamadas del modelo base en frases cotidianas en español (*"sube el volumen al 50%"*, *"busca los apuntes de SO en Descargas"*, *"abre el campus de la universidad"*).
* **📜 Licencia Apache-2.0:** Código y modelo base bajo una de las licencias más permisivas y abiertas de la industria.

---

## 🏗️ Arquitectura del Sistema

```
                         Voz o Texto del Usuario
                                   │
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│             Needle 3 SAN Engine (Simple Attention Network)             │
│            Pesos Cuantizados CQ W4 STE + A8 (~35.3 MB en disco)        │
│          Adaptador LoRA para Español Coloquial y Materias UAB          │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │
               JSON Function Call Determinista (< 28ms)
                                   │
         ┌─────────────────────────┴─────────────────────────┐
         ▼                                                   ▼
┌─────────────────────────────────┐   ┌─────────────────────────────────┐
│     🍎 Módulo macOS (ARM64)     │   │     🪟 Módulo Windows (x64)     │
├─────────────────────────────────┤   ├─────────────────────────────────┤
│ • Spotlight CLI (mdfind)        │   │ • Everything CLI (es.exe) <5ms  │
│ • AppleScript (osascript)       │   │ • PowerShell nativo             │
│ • Gestor de ventanas & open CLI │   │ • Win32 API / NirCmd            │
│ • Captura de pantalla nativa    │   │ • Bloqueo de sesión (rundll32)  │
└─────────────────────────────────┘   └─────────────────────────────────┘
```

---

## 🛠️ Herramientas Entrenadas (`schemas/tools.json`)

El modelo opera de forma determinista sobre 5 esquemas de herramientas:

1. **`find_files`**: Búsqueda instantánea de archivos, apuntes y PDFs en rutas clave (`Documents`, `Downloads`, `obsidian_vault`, `Desktop`).
2. **`open_target`**: Apertura de aplicaciones (*Antigravity IDE*, *Chrome*, *Spotify*), archivos o portales académicos (*e-aules.uab.cat*, *Caronte*).
3. **`system_control`**: Control granular de volumen (0-100%), mute/unmute, capturas de pantalla y bloqueo de sesión.
4. **`study_notes`**: Consulta y generación rápida de notas en Obsidian clasificadas por materia (Sistemas Operativos, Fundamentos de Computadores, etc.).
5. **`delegate_kathy`**: Enrutador inteligente para solicitudes complejas que requieran razonamiento avanzado o redacción asistida.

---

## 💻 Guía de Ejecución Rápida

### 🍎 Opción A: En tu MacBook Pro (Apple Silicon)

1. **Clonar el repositorio:**
   ```bash
   git clone https://github.com/Wagustin/omnicontrolpc.git
   cd omnicontrolpc
   ```

2. **Instalar el runtime ultra-ligero:**
   ```bash
   pip install cactus-needle
   ```

3. **Ejecutar comandos directos:**
   ```bash
   # Buscar archivos de la universidad y abrirlos en pantalla:
   python jarvis_client.py "busca los apuntes de Sistemas Operativos"

   # Control del sistema:
   python jarvis_client.py "sube el volumen al 50%"

   # Abrir aplicaciones o plataformas:
   python jarvis_client.py "abre el campus virtual"
   ```

---

### 🪟 Opción B: En una Laptop Modesta con Windows (ej. Intel Core i3 7ma Gen / 8 GB RAM)

Este motor está diseñado específicamente para correr fluido en equipos de bajos recursos sin depender de tarjeta gráfica dedicada ni saturar la memoria RAM.

1. **Clonar o descargar el proyecto en Windows:**
   ```powershell
   git clone https://github.com/Wagustin/omnicontrolpc.git
   cd omnicontrolpc
   ```

2. **Instalar la dependencia:**
   ```powershell
   pip install cactus-needle
   ```

3. **(Opcional Recomendado) Búsqueda instantánea en <5 ms:**
   * Descarga la utilidad gratuita **[Voidtools Everything](https://www.voidtools.com/)** y su herramienta de línea de comandos **`es.exe`**.
   * Coloca `es.exe` en tu PATH o en la carpeta del proyecto. El script la detectará automáticamente para indexar y buscar archivos NTFS al instante.

4. **Probar el asistente:**
   ```powershell
   python jarvis_client.py "pon el volumen al 40%"
   python jarvis_client.py "busca en Descargas el PDF de la matrícula"
   python jarvis_client.py "bloquea la pantalla"
   ```

---

## 📊 Especificaciones de Hardware & Rendimiento

| Parámetro | MacBook Pro (M-Series) | Laptop i3 7ma Gen (Windows) |
| :--- | :--- | :--- |
| **Uso de RAM** | ~94 MB | ~98 MB |
| **Uso de CPU** | < 2% en inferencia | < 5% en inferencia |
| **Tiempo de Inferencia** | 18 ms - 24 ms | 42 ms - 55 ms |
| **GPU Requerida** | Ninguna (CPU Apple Silicon) | Ninguna (CPU Intel AVX2) |
| **Espacio en Disco** | 35.3 MB | 35.3 MB |

---

## 📜 Licencias y Reconocimientos

* **Motor Base (Needle 3):** Creado por [Cactus Compute](https://cactuscompute.com/needle) bajo licencia **Apache-2.0**.
* **OmniControl PC:** Código fuente, herramientas y adaptadores publicados bajo licencia **Apache-2.0**.
* **Autor:** Diseñado y mantenido por [Agustín](https://github.com/Wagustin).
