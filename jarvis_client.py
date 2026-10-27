#!/usr/bin/env python3
"""
Jarvis Cross-Platform Client (Windows & macOS)
Ejecuta acciones locales en milisegundos con Needle 3 y fallback determinista.
"""

import json
import os
import re
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
        subprocess.run(f'cmd.exe /c start "" "{target}"', shell=True)
    elif IS_LINUX:
        subprocess.run(["xdg-open", target])

def system_control_local(action, level=50):
    if IS_MAC:
        if action == "set_volume":
            subprocess.run(["osascript", "-e", "set volume without output muted", "-e", f"set volume output volume {level}"])
        elif action == "mute":
            subprocess.run(["osascript", "-e", "set volume with output muted"])
        elif action == "unmute":
            subprocess.run(["osascript", "-e", "set volume without output muted"])
        elif action == "take_screenshot":
            p = os.path.expanduser("~/Desktop/screenshot_jarvis.png")
            subprocess.run(["screencapture", "-x", p])
            print(f"[✓] Captura guardada en: {p}")
        elif action == "lock_screen":
            subprocess.run(["pmset", "displaysleepnow"])
            
    elif IS_WIN:
        if action == "set_volume":
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
                print(f"[✓] Captura guardada en: {p}")
        elif action == "lock_screen":
            subprocess.run("rundll32.exe user32.dll,LockWorkStation", shell=True)

def rule_based_fallback(query):
    q = query.lower().strip()
    
    # 1. Volumen y Audio
    m_vol = re.search(r'(?:sube|baja|pon|ajusta|cambia)?\s*(?:el\s*)?volumen\s*(?:al?|en)?\s*(\d+)%?', q)
    if m_vol:
        return [{"name": "system_control", "arguments": {"action": "set_volume", "level": int(m_vol.group(1))}}]
    if any(w in q for w in ["silencia", "mute", "mutear", "pon en silencio", "quitar sonido"]):
        return [{"name": "system_control", "arguments": {"action": "mute"}}]
    if any(w in q for w in ["desmutea", "unmute", "activa sonido", "activa el audio", "quitar silencio"]):
        return [{"name": "system_control", "arguments": {"action": "unmute"}}]
    if any(w in q for w in ["captura de pantalla", "screenshot", "pantallazo", "foto de la pantalla"]):
        return [{"name": "system_control", "arguments": {"action": "take_screenshot"}}]
    if any(w in q for w in ["bloquea la pantalla", "bloquear pantalla", "bloquea el mac", "bloquea el pc", "suspende la pantalla"]):
        return [{"name": "system_control", "arguments": {"action": "lock_screen"}}]

    # 2. Abrir URLs o Apps
    m_url = re.search(r'abre\s+(https?://\S+)', q)
    if m_url:
        return [{"name": "open_target", "arguments": {"name": m_url.group(1), "target_type": "url"}}]
    if "campus virtual" in q or "e-aules" in q:
        return [{"name": "open_target", "arguments": {"name": "https://e-aules.uab.cat", "target_type": "url"}}]
    if "caronte" in q:
        return [{"name": "open_target", "arguments": {"name": "https://caronte.uab.cat", "target_type": "url"}}]
    m_app = re.search(r'abre\s+(?:la\s*app\s*de\s*|el\s*programa\s*|la\s*aplicación\s*)?([a-zA-Z0-9_\s\.\-]+)$', q)
    if m_app:
        app_name = m_app.group(1).strip()
        if app_name:
            return [{"name": "open_target", "arguments": {"name": app_name, "target_type": "app"}}]

    # 3. Buscar archivos
    m_search = re.search(r'(?:busca|encuentra|localiza)\s+(?:los\s*apuntes\s*de\s*|el\s*archivo\s*|archivos\s*de\s*)?(.*?)\s*(?:en\s+(descargas|documentos|escritorio|obsidian))?$', q)
    if m_search:
        term = m_search.group(1).strip()
        fld_raw = (m_search.group(2) or "").lower()
        fld = "any"
        if "descarga" in fld_raw: fld = "Downloads"
        elif "documento" in fld_raw: fld = "Documents"
        elif "escritorio" in fld_raw: fld = "Desktop"
        elif "obsidian" in fld_raw: fld = "obsidian_vault"
        if term:
            return [{"name": "find_files", "arguments": {"query": term, "folder": fld, "file_type": "any"}}]

    return []

def execute_call(call):
    name = call.get("name")
    args = call.get("arguments", {})
    
    # Sanitizar casos donde el modelo predijo mute con level > 0
    if name == "system_control":
        if args.get("action") == "mute" and args.get("level") is not None and args.get("level", 0) > 0:
            args["action"] = "set_volume"
            
    print(f"[*] OmniControl Acción: {name} -> {args}")
    
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
        print("Uso: omnicontrol 'sube el volumen al 50%'")
        sys.exit(0)
        
    query = " ".join(sys.argv[1:])
    executed = False
    
    # Intentar inferencia local con Needle 3
    try:
        from needle import Needle
        schema_path = os.path.join(os.path.dirname(__file__), "schemas", "tools.json")
        tools_data = []
        if os.path.exists(schema_path):
            with open(schema_path, "r", encoding="utf-8") as f:
                tools_data = json.load(f)
                
        ndl = Needle(tools=tools_data, stateless=True)
        res = ndl.complete(query)
        calls = res.get("function_calls", [])
        conf = res.get("confidence", 0.0) or 0.0
        
        if calls and conf >= 0.45:
            for call in calls:
                execute_call(call)
            executed = True
    except Exception as e:
        pass
        
    # Fallback determinista si Needle no disparó o tuvo baja confianza
    if not executed:
        fallback_calls = rule_based_fallback(query)
        if fallback_calls:
            for call in fallback_calls:
                execute_call(call)
            executed = True
        else:
            execute_call({"name": "delegate_kathy", "arguments": {"request": query}})
