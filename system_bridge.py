#!/usr/bin/env python3
"""
system_bridge.py — Unified cross-platform system control & audio feedback for macOS & Windows.

Provides deterministic, zero-dependency system actions and native audio beeps
matching the tool signatures in schemas/tools.json.
"""

from __future__ import annotations

import os
import platform
import shutil
import struct
import subprocess
import sys
import wave
from pathlib import Path
from typing import Any

IS_MAC = sys.platform == "darwin"
IS_WIN = sys.platform == "win32"
IS_LINUX = sys.platform.startswith("linux")


# ──────────────────────────────────────────────────────────────────────────────
# Platform detection & utilities
# ──────────────────────────────────────────────────────────────────────────────

def _which(cmd: str) -> str | None:
    return shutil.which(cmd)


def _run(cmd: list[str] | str, **kw) -> subprocess.CompletedProcess:
    if isinstance(cmd, str) and IS_WIN:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


# ──────────────────────────────────────────────────────────────────────────────
# Audio feedback (beep / chime)
# ──────────────────────────────────────────────────────────────────────────────

def beep(frequency: int = 880, duration_ms: int = 120, volume: float = 0.6) -> bool:
    """
    Play a short sine-wave beep. Native on macOS (afplay) and Windows (winsound).
    Falls back to pure Python wave synthesis written to a temp file.
    """
    # ── macOS: afplay with generated AIFF ──────────────────────────────────
    if IS_MAC and _which("afplay"):
        try:
            import tempfile
            with tempfile.NamedTemporaryFile(suffix=".aiff", delete=False) as tmp:
                _write_aiff(tmp.name, frequency, duration_ms, volume)
            _run(["afplay", tmp.name])
            try:
                os.unlink(tmp.name)
            except OSError:
                pass
            return True
        except Exception:
            pass

    # ── Windows: winsound.Beep ─────────────────────────────────────────────
    if IS_WIN:
        try:
            import winsound
            winsound.Beep(frequency, duration_ms)  # type: ignore[attr-defined]
            return True
        except Exception:
            pass

    # ── Fallback: pure Python wave → play via platform default ─────────────
    try:
        import tempfile
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            _write_wav(tmp.name, frequency, duration_ms, volume)
        if IS_MAC:
            _run(["afplay", tmp.name])
        elif IS_WIN:
            _run([sys.executable, "-c", f"import winsound; winsound.PlaySound(r'{tmp.name}', winsound.SND_FILENAME)"])
        elif IS_LINUX:
            for player in ("aplay", "paplay", "ffplay -nodisp -autoexit", "mpv --no-video"):
                if _which(player.split()[0]):
                    _run(player.split() + [tmp.name])
                    break
        else:
            _run([sys.executable, "-c", f"import wave, pyaudio; ..."])  # no-op placeholder
        try:
            os.unlink(tmp.name)
        except OSError:
            pass
        return True
    except Exception:
        return False


def _write_wav(path: str, freq: int, dur_ms: int, vol: float) -> None:
    sr = 44100
    n = int(sr * dur_ms / 1000)
    amp = int(32767 * vol)
    with wave.open(path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sr)
        frames = bytearray()
        for i in range(n):
            v = int(amp * (i / n) * (1 - i / n) * 4 * (i / n) * (1 - i / n) * 4 *  # envelope
                    (i / n) * (1 - i / n) * 4)  # simple fade in/out
            # Actually just a sine with linear fade
            import math
            t = i / sr
            sample = int(amp * math.sin(2 * math.pi * freq * t) * (1 - t / (dur_ms / 1000)))
            frames.extend(struct.pack("<h", max(-32768, min(32767, sample))))
        wf.writeframes(frames)


def _write_aiff(path: str, freq: int, dur_ms: int, vol: float) -> None:
    # Minimal AIFF writer for afplay
    sr = 44100
    n = int(sr * dur_ms / 1000)
    amp = int(32767 * vol)
    import math
    frames = bytearray()
    for i in range(n):
        t = i / sr
        sample = int(amp * math.sin(2 * math.pi * freq * t) * (1 - t / (dur_ms / 1000)))
        frames.extend(struct.pack(">h", max(-32768, min(32767, sample))))
    form_size = 4 + 8 + 18 + 8 + len(frames) + 8  # FORM + COMM + SSND
    with open(path, "wb") as f:
        f.write(b"FORM")
        f.write(struct.pack(">I", form_size))
        f.write(b"AIFF")
        # COMM chunk
        f.write(b"COMM")
        f.write(struct.pack(">I", 18))
        f.write(struct.pack(">H", 1))          # channels
        f.write(struct.pack(">I", n))          # num frames
        f.write(struct.pack(">H", 16))         # sample size
        f.write(struct.pack(">f", sr))         # sample rate (80-bit extended → fudge with float)
        # SSND chunk
        f.write(b"SSND")
        f.write(struct.pack(">I", len(frames) + 8))
        f.write(struct.pack(">I", 0))  # offset
        f.write(struct.pack(">I", 0))  # block size
        f.write(frames)


def feedback_success() -> bool:
    """Two-tone ascending chime for success."""
    beep(660, 90, 0.5)
    beep(880, 120, 0.6)
    return True


def feedback_error() -> bool:
    """Descending two-tone for error."""
    beep(440, 120, 0.6)
    beep(330, 150, 0.5)
    return True


def feedback_neutral() -> bool:
    """Single neutral beep."""
    return beep(550, 100, 0.5)


# ──────────────────────────────────────────────────────────────────────────────
# System control — volume, mute, lock, screenshot
# ──────────────────────────────────────────────────────────────────────────────

def volume_set(level: int) -> dict[str, Any]:
    """Set system output volume 0-100."""
    level = max(0, min(100, int(level)))
    if IS_MAC:
        _run(["osascript", "-e", "set volume without output muted", "-e", f"set volume output volume {level}"])
        return {"ok": True, "level": level}
    if IS_WIN:
        if _which("nircmd"):
            val = int((level / 100) * 65535)
            _run(["nircmd", "setsysvolume", str(val)])
            return {"ok": True, "level": level}
        # PowerShell fallback (requires COM)
        ps = f"(New-Object -ComObject WScript.Shell).SendKeys([char]174)*{100-level}; (New-Object -ComObject WScript.Shell).SendKeys([char]175)*{level}"
        _run(["powershell", "-NoProfile", "-Command", ps])
        return {"ok": True, "level": level, "note": "fallback"}
    return {"ok": False, "error": "unsupported platform"}


def volume_mute() -> dict[str, Any]:
    if IS_MAC:
        _run(["osascript", "-e", "set volume with output muted"])
        return {"ok": True, "muted": True}
    if IS_WIN:
        if _which("nircmd"):
            _run(["nircmd", "mutesysvolume", "1"])
            return {"ok": True, "muted": True}
        _run(["powershell", "-NoProfile", "-Command", "(New-Object -ComObject WScript.Shell).SendKeys([char]173)"])
        return {"ok": True, "muted": True, "note": "fallback"}
    return {"ok": False, "error": "unsupported platform"}


def volume_unmute() -> dict[str, Any]:
    if IS_MAC:
        _run(["osascript", "-e", "set volume without output muted"])
        return {"ok": True, "muted": False}
    if IS_WIN:
        if _which("nircmd"):
            _run(["nircmd", "mutesysvolume", "0"])
            return {"ok": True, "muted": False}
        _run(["powershell", "-NoProfile", "-Command", "(New-Object -ComObject WScript.Shell).SendKeys([char]173)"])
        return {"ok": True, "muted": False, "note": "fallback"}
    return {"ok": False, "error": "unsupported platform"}


def lock_screen() -> dict[str, Any]:
    if IS_MAC:
        _run(["pmset", "displaysleepnow"])
        return {"ok": True}
    if IS_WIN:
        _run("rundll32.exe user32.dll,LockWorkStation", shell=True)
        return {"ok": True}
    if IS_LINUX:
        for cmd in (["gnome-screensaver-command", "-l"], ["loginctl", "lock-session"], ["dm-tool", "lock"]):
            if _which(cmd[0]):
                _run(cmd)
                return {"ok": True}
    return {"ok": False, "error": "unsupported platform"}


def screenshot(path: str | None = None) -> dict[str, Any]:
    """Take a screenshot. Returns path to saved file."""
    if path is None:
        desk = Path.home() / "Desktop"
        desk.mkdir(exist_ok=True)
        path = str(desk / f"screenshot_{platform.node()}_{os.getpid()}.png")

    if IS_MAC:
        _run(["screencapture", "-x", path])
        return {"ok": True, "path": path}
    if IS_WIN:
        if _which("nircmd"):
            _run(["nircmd", "savescreenshot", path])
            return {"ok": True, "path": path}
        # PowerShell fallback
        ps = f"""
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap $screen.Width, $screen.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bmp)
        $graphics.CopyFromScreen(0,0,0,0,$screen.Size)
        $bmp.Save('{path}')
        """
        _run(["powershell", "-NoProfile", "-Command", ps])
        return {"ok": True, "path": path}
    if IS_LINUX:
        for cmd in (["gnome-screenshot", "-f", path], ["scrot", path], ["maim", path]):
            if _which(cmd[0]):
                _run(cmd)
                return {"ok": True, "path": path}
    return {"ok": False, "error": "unsupported platform"}


# ──────────────────────────────────────────────────────────────────────────────
# Open targets — apps, files, URLs
# ──────────────────────────────────────────────────────────────────────────────

def open_target(name: str, target_type: str = "app") -> dict[str, Any]:
    """
    Open an application, file, or URL.
    target_type: "app" | "file" | "url"
    """
    if IS_MAC:
        if target_type == "url":
            _run(["open", name])
        elif target_type == "app":
            _run(["open", "-a", name])
        else:
            _run(["open", name])
        return {"ok": True}
    if IS_WIN:
        _run(f'cmd.exe /c start "" "{name}"', shell=True)
        return {"ok": True}
    if IS_LINUX:
        _run(["xdg-open", name])
        return {"ok": True}
    return {"ok": False, "error": "unsupported platform"}


# ──────────────────────────────────────────────────────────────────────────────
# File search — Spotlight (macOS) / Everything + PowerShell (Windows)
# ──────────────────────────────────────────────────────────────────────────────

_FOLDER_MAP_MAC = {
    "downloads": "~/Downloads",
    "documents": "~/Documents",
    "desktop": "~/Desktop",
    "obsidian_vault": "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian_vault",
}

_FOLDER_MAP_WIN = {
    "downloads": "~/Downloads",
    "documents": "~/Documents",
    "desktop": "~/Desktop",
}


def find_files(query: str, file_type: str = "any", folder: str = "any") -> list[str]:
    """
    Search files locally. Returns list of absolute paths.
    file_type: "pdf" | "code" | "document" | "image" | "any"
    folder: "downloads" | "documents" | "desktop" | "obsidian_vault" | "any"
    """
    results: list[str] = []
    folder = folder.lower()

    if IS_MAC:
        cmd = ["mdfind"]
        if folder in _FOLDER_MAP_MAC:
            cmd.extend(["-onlyin", os.path.expanduser(_FOLDER_MAP_MAC[folder])])
        cmd.append(query)
        res = _run(cmd)
        results = [f for f in res.stdout.splitlines() if f.strip()]

    elif IS_WIN:
        if _which("es"):
            es_cmd = ["es", query]
            if folder in _FOLDER_MAP_WIN:
                es_cmd.extend(["-path", os.path.expanduser(_FOLDER_MAP_WIN[folder])])
            res = _run(es_cmd)
            results = [f for f in res.stdout.splitlines() if f.strip()]
        else:
            target = os.path.expanduser("~")
            if folder in _FOLDER_MAP_WIN:
                target = os.path.expanduser(_FOLDER_MAP_WIN[folder])
            ps = (
                f"Get-ChildItem -Path '{target}' -Recurse -Filter '*{query}*' -File "
                f"-ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 15"
            )
            res = _run(["powershell", "-NoProfile", "-Command", ps])
            results = [f for f in res.stdout.splitlines() if f.strip()]

    # Filter by file_type
    if file_type == "pdf":
        results = [f for f in results if f.lower().endswith(".pdf")]
    elif file_type == "code":
        code_ext = {".py", ".c", ".cpp", ".js", ".ts", ".html", ".css", ".java", ".rs", ".go", ".rb", ".php", ".sh"}
        results = [f for f in results if Path(f).suffix.lower() in code_ext]
    elif file_type == "document":
        doc_ext = {".pdf", ".doc", ".docx", ".txt", ".md", ".rtf", ".odt"}
        results = [f for f in results if Path(f).suffix.lower() in doc_ext]
    elif file_type == "image":
        img_ext = {".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tiff", ".webp", ".svg"}
        results = [f for f in results if Path(f).suffix.lower() in img_ext]

    return results


# ──────────────────────────────────────────────────────────────────────────────
# Tool schemas matching schemas/tools.json
# ──────────────────────────────────────────────────────────────────────────────

TOOL_SCHEMAS: list[dict[str, Any]] = [
    {
        "name": "find_files",
        "description": "Buscar y localizar archivos, documentos, apuntes o PDFs en la Mac",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Término de búsqueda, nombre de archivo o tema"},
                "file_type": {
                    "type": "string",
                    "enum": ["pdf", "code", "document", "image", "any"],
                    "description": "Extensión o tipo de archivo"
                },
                "folder": {
                    "type": "string",
                    "enum": ["Downloads", "Documents", "obsidian_vault", "Desktop", "any"],
                    "description": "Carpeta donde buscar"
                }
            },
            "required": ["query"]
        }
    },
    {
        "name": "open_target",
        "description": "Abrir una aplicación, un archivo encontrado o un sitio web",
        "parameters": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Nombre de la aplicación, archivo o URL"},
                "target_type": {
                    "type": "string",
                    "enum": ["app", "file", "url"],
                    "description": "Tipo de objetivo a abrir"
                }
            },
            "required": ["name", "target_type"]
        }
    },
    {
        "name": "system_control",
        "description": "Control del sistema de la Mac: volumen, capturas de pantalla o bloqueo",
        "parameters": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["set_volume", "mute", "unmute", "take_screenshot", "lock_screen"],
                    "description": "Acción a realizar"
                },
                "level": {
                    "type": "integer",
                    "description": "Nivel numérico de volumen entre 0 y 100"
                }
            },
            "required": ["action"]
        }
    }
]


# ──────────────────────────────────────────────────────────────────────────────
# Dispatcher — executes a tool call by name
# ──────────────────────────────────────────────────────────────────────────────

def execute_tool(call: dict[str, Any]) -> dict[str, Any]:
    """
    Execute a single tool call dict: {"name": "...", "arguments": {...}}.
    Returns a result dict with at least {"ok": bool, ...}.
    """
    name = call.get("name")
    args = call.get("arguments", {})

    try:
        if name == "find_files":
            files = find_files(
                args.get("query", ""),
                args.get("file_type", "any"),
                args.get("folder", "any")
            )
            return {"ok": True, "files": files, "count": len(files)}

        if name == "open_target":
            return open_target(args.get("name", ""), args.get("target_type", "app"))

        if name == "system_control":
            action = args.get("action")
            level = args.get("level", 50)
            if action == "set_volume":
                return volume_set(level)
            if action == "mute":
                return volume_mute()
            if action == "unmute":
                return volume_unmute()
            if action == "take_screenshot":
                return screenshot()
            if action == "lock_screen":
                return lock_screen()
            return {"ok": False, "error": f"unknown action: {action}"}

    except Exception as e:
        return {"ok": False, "error": str(e)}

    return {"ok": False, "error": f"unknown tool: {name}"}


# ──────────────────────────────────────────────────────────────────────────────
# CLI test harness
# ──────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import json

    print(f"Platform: {platform.system()} ({platform.machine()})")
    print(f"Python: {sys.version.split()[0]}")
    print()

    # Quick self-test
    print("— Audio feedback —")
    print("neutral:", feedback_neutral())
    print("success:", feedback_success())
    print("error:", feedback_error())

    print("\n— Volume —")
    print("set 30%:", volume_set(30))
    print("mute:", volume_mute())
    print("unmute:", volume_unmute())
    print("set 60%:", volume_set(60))

    print("\n— Screenshot —")
    print(screenshot())

    print("\n— File search —")
    files = find_files("README", "any", "any")
    print(f"Found {len(files)}: {files[:3]}")

    print("\n— Open target —")
    print(open_target("https://example.com", "url"))

    print("\n— Lock screen (dry-run) —")
    # print(lock_screen())  # commented out to avoid locking during test

    print("\n— Tool schemas —")
    print(json.dumps(TOOL_SCHEMAS, indent=2, ensure_ascii=False))