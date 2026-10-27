#!/usr/bin/env python3
"""
Jarvis Cross-Platform Client (Windows & macOS)
Ejecuta acciones locales en milisegundos con Needle 3.
"""

import json
import os
import shutil
import subprocess
import sys

IS_MAC = sys.platform == "darwin"
IS_WIN = sys.platform == "win32"
IS_LINUX = sys.platform.startswith("linux")

def search_files_local(query, file_type="any", folder="any"):
    results = []
    
    if IS_MAC:
        cmd = ["mdfind"]
        if folder == "Downloads":
            cmd.extend(["-onlyin", os.path.expanduser("~/Downloads")])
        elif folder == "Documents":
            cmd.extend(["-onlyin", os.path.expanduser("~/Documents")])
        elif folder == "Desktop":
            cmd.extend(["-onlyin", os.path.expanduser("~/Desktop")])
        elif folder == "obsidian_vault":
            cmd.extend(["-onlyin", os.path.expanduser("~/Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian_vault")])
        cmd.append(query)
        res = subprocess.run(cmd, capture_output=True, text=True)
        results = [f for f in res.stdout.splitlines() if f.strip()]
        
    elif IS_WIN:
        # 1. Si Everything CLI (es.exe) está instalado, es instantáneo (<5 ms)
        if shutil.which("es"):
            es_cmd = ["es", query]
            if folder == "Downloads":
                es_cmd.extend(["-path", os.path.expanduser("~\\Downloads")])
            elif folder == "Documents":
                es_cmd.extend(["-path", os.path.expanduser("~\\Documents")])
            elif folder == "Desktop":
                es_cmd.extend(["-path", os.path.expanduser("~\\Desktop")])
            res = subprocess.run(es_cmd, capture_output=True, text=True)
            results = [f for f in res.stdout.splitlines() if f.strip()]
        else:
            # Fallback a PowerShell Get-ChildItem en carpetas de usuario
            target_dir = os.path.expanduser("~")
            if folder == "Downloads":
                target_dir = os.path.expanduser("~\\Downloads")
            elif folder == "Documents":
                target_dir = os.path.expanduser("~\\Documents")
            elif folder == "Desktop":
                target_dir = os.path.expanduser("~\\Desktop")
                
            ps_script = f"Get-ChildItem -Path '{target_dir}' -Recurse -Filter '*{query}*' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 10"
            res = subprocess.run(["powershell", "-NoProfile", "-Command", ps_script], capture_output=True, text=True)
            results = [f for f in res.stdout.splitlines() if f.strip()]
            
    if file_type == "pdf":
        results = [f for f in results if f.lower().endswith(".pdf")]
    elif file_type == "code":
        results = [f for f in results if any(f.lower().endswith(ext) for ext in [".py", ".c", ".cpp", ".js", ".ts", ".html", ".css", ".java"])]
        
    return results

def open_target_local(target, target_type):
    if IS_MAC:
        if target_type == "url":
            subprocess.run(["open", target])
        elif target_type == "app":
            subprocess.run(["open", "-a", target])
        else:
            subprocess.run(["open", target])
    elif IS_WIN:
        # En Windows 'start' abre URLs, apps o archivos registrados con el visor predeterminado
        subprocess.run(f'cmd.exe /c start "" "{target}"', shell=True)
    elif IS_LINUX:
        subprocess.run(["xdg-open", target])

def system_control_local(action, level=50):
    if IS_MAC:
        if action == "set_volume":
            subprocess.run(["osascript", "-e", f"set volume output volume {level}"])
        elif action == "mute":
            subprocess.run(["osascript", "-e", "set volume with output muted"])
        elif action == "unmute":
            subprocess.run(["osascript", "-e", "set volume without output muted"])
        elif action == "take_screenshot":
            p = os.path.expanduser("~/Desktop/screenshot_jarvis.png")
            subprocess.run(["screencapture", "-x", p])
        elif action == "lock_screen":
            subprocess.run(["pmset", "displaysleepnow"])
            
    elif IS_WIN:
        if action == "set_volume":
            # Si nircmd está disponible o vía PowerShell Audio API
            if shutil.which("nircmd"):
                val = int((level / 100) * 65535)
                subprocess.run(["nircmd", "setsysvolume", str(val)])
            else:
                print(f"[!] Volumen Windows ajustado a {level}% (requiere nircmd.exe)")
        elif action == "mute":
            if shutil.which("nircmd"):
                subprocess.run(["nircmd", "mutesysvolume", "1"])
        elif action == "unmute":
            if shutil.which("nircmd"):
                subprocess.run(["nircmd", "mutesysvolume", "0"])
        elif action == "take_screenshot":
            if shutil.which("nircmd"):
                p = os.path.expanduser("~\\Desktop\\screenshot_jarvis.png")
                subprocess.run(["nircmd", "savescreenshot", p])
        elif action == "lock_screen":
            subprocess.run("rundll32.exe user32.dll,LockWorkStation", shell=True)

def execute_call(call):
    name = call.get("name")
    args = call.get("arguments", {})
    print(f"[*] Jarvis Acción: {name} -> {args}")
    
    if name == "find_files":
        files = search_files_local(args.get("query", ""), args.get("file_type", "any"), args.get("folder", "any"))
        print(f"[+] Archivos encontrados ({len(files)}):")
        for f in files[:5]:
            print(f"    - {f}")
        if files:
            open_target_local(files[0], "file")
            print(f"[✓] Abierto: {files[0]}")
            
    elif name == "open_target":
        open_target_local(args.get("name"), args.get("target_type", "app"))
        print(f"[✓] Ejecutado objetivo: {args.get('name')}")
        
    elif name == "system_control":
        system_control_local(args.get("action"), args.get("level", 50))
        print(f"[✓] Control de sistema ejecutado: {args.get('action')}")
        
    elif name == "study_notes":
        print(f"[✓] Notas: {args}")
        
    elif name == "delegate_kathy":
        print(f"[→] Delegado a Kathy: {args.get('request')}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Uso: python jarvis_client.py 'sube el volumen al 50%'")
        sys.exit(0)
        
    from needle import Needle
    # Carga weights .cact
    ndl = Needle(tools="schemas/tools.json", stateless=True)
    res = ndl.complete(" ".join(sys.argv[1:]))
    for call in res.get("function_calls", []):
        execute_call(call)
