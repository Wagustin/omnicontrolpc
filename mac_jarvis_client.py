#!/usr/bin/env python3
"""
Jarvis Mac Client - Integración local de Needle 3 en macOS
Ejecuta comandos en lenguaje natural sin latencia de red.
"""

import json
import os
import subprocess
import sys

def execute_action(call):
    name = call.get("name")
    args = call.get("arguments", {})
    print(f"[*] Ejecutando: {name} con argumentos {args}")
    
    if name == "find_files":
        query = args.get("query", "")
        file_type = args.get("file_type", "any")
        folder = args.get("folder", "any")
        
        # Spotlight mdfind en macOS
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
        files = [f for f in res.stdout.split("\n") if f.strip()]
        if file_type == "pdf":
            files = [f for f in files if f.endswith(".pdf")]
            
        print(f"[+] Archivos encontrados ({len(files)}):")
        for f in files[:5]:
            print(f"    - {f}")
        if files:
            subprocess.run(["open", files[0]])
            print(f"[✓] Abierto en pantalla: {files[0]}")
            
    elif name == "open_target":
        target = args.get("name")
        target_type = args.get("target_type")
        if target_type == "url":
            subprocess.run(["open", target])
        elif target_type == "app":
            subprocess.run(["open", "-a", target])
        else:
            subprocess.run(["open", target])
        print(f"[✓] Objetivo abierto: {target}")
        
    elif name == "system_control":
        action = args.get("action")
        level = args.get("level", 50)
        if action == "set_volume":
            subprocess.run(["osascript", "-e", f"set volume output volume {level}"])
        elif action == "mute":
            subprocess.run(["osascript", "-e", "set volume with output muted"])
        elif action == "unmute":
            subprocess.run(["osascript", "-e", "set volume without output muted"])
        elif action == "take_screenshot":
            subprocess.run(["screencapture", "-x", os.path.expanduser("~/Desktop/screenshot_jarvis.png")])
            print("[✓] Screenshot guardado en Desktop.")
            
    elif name == "delegate_kathy":
        req = args.get("request")
        print(f"[→] Reenviando a Kathy por Telegram / SSH: {req}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Uso: python3 mac_jarvis_client.py 'busca los apuntes de SO'")
        sys.exit(0)
    
    # En Mac cargará el binario compilado jarvis_mac_es.cact
    from needle import Needle
    ndl = Needle(weights="jarvis_mac_es.cact", tools="tools.json", stateless=True)
    res = ndl.complete(" ".join(sys.argv[1:]))
    for call in res.get("function_calls", []):
        execute_action(call)
