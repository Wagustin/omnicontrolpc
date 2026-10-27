# 🎙️ Needle Desktop Jarvis

> **Ultralight (~35MB) On-Device System Assistant & Tool Engine for macOS & Windows with Spanish Fine-Tuning.**  
> Powered by [Cactus Compute Needle 3](https://cactuscompute.com/needle), Spotlight (`mdfind`), Voidtools Everything (`es.exe`), and AppleScript / PowerShell.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20ARM64%20%7C%20Windows%20x64-green.svg)]()
[![Model Size](https://img.shields.io/badge/Model%20Weight-35.3%20MB-orange.svg)]()
[![RAM Usage](https://img.shields.io/badge/RAM-~110%20MB-purple.svg)]()

---

## ⚡ What is Needle Desktop Jarvis?

While general-purpose LLMs require gigabytes of VRAM, high cloud API costs, or heavy background daemons, **Needle Desktop Jarvis** is designed for extreme local efficiency:

* **⚡ Sub-30ms Tool Calling:** Executes actions on-device with zero cloud latency.
* **🪶 Ultra-Low Footprint:** Runs on a ~35MB binary model (`.cact`) consuming less than **110 MB of RAM**.
* **🍎 macOS Native:** Powered by native Apple Silicon (`macos-arm64`) with Spotlight (`mdfind`), `open`, and `osascript`.
* **🪟 Windows Native:** Runs via `needle.exe` (`windows-x86_64`), leveraging the NTFS index via Voidtools Everything (`es.exe`) in **<5ms**, or native PowerShell / Win32 APIs.
* **🇪🇸 Fine-Tuned for Natural Spanish:** Solves Needle 3's default suppression and keyword-matching hurdles on Spanish queries through calibrated LoRA fine-tuning.

---

## 🏗️ Architecture

```
User (Voice / Text)
        │
        ▼
┌──────────────────────────────────────────────┐
│  Needle 3 Engine (~35 MB, CQ W4 STE + A8)     │
│  - Simple Attention Network (20 Layers)      │
│  - Spanish LoRA Adapter (Rank 16, Alpha 32)  │
└──────────────────────┬───────────────────────┘
                       │ Deterministic Tool Call (JSON)
        ┌──────────────┴──────────────┐
        ▼                             ▼
┌──────────────────────────┐   ┌──────────────────────────┐
│       macOS Client       │   │      Windows Client      │
├──────────────────────────┤   ├──────────────────────────┤
│ • Spotlight (mdfind)     │   │ • Everything (es.exe)    │
│ • AppleScript (osascript)│   │ • PowerShell / cmd start │
│ • Native open CLI        │   │ • NirCmd / Win32 API     │
└──────────────────────────┘   └──────────────────────────┘
```

---

## 🛠️ Tool Schemas (`schemas/tools.json`)

The model is trained on 5 deterministic system capabilities:

1. **`find_files`**: Locates documents, notes, course guides, and codebases across specific folders (`Documents`, `Downloads`, `obsidian_vault`, `Desktop`).
2. **`open_target`**: Launches applications (*Antigravity IDE*, *Chrome*, *Spotify*), files, or institutional web portals (*Moodle*, *Caronte*).
3. **`system_control`**: Direct control over audio volume (0-100%), mute/unmute, screenshot captures, and workstation locking.
4. **`study_notes`**: Quick creation and lookup of subject notes in Obsidian (`SO`, `FC`, `P3`, `PS`, etc.).
5. **`delegate_kathy`**: Intelligent fallback router that forwards complex reasoning, code refactoring, or email drafting to an external senior agent.

---

## 📊 Dataset & Spanish Fine-Tuning

Default base models in English often suppress tools (`confidence < 0.10`) when processing colloquial Spanish phrases (*"búscame la guía 2 de laboratorio de FC"*, *"sube el volumen al 50%"*).

This repository includes:
* **`data/train.jsonl` (288 samples):** Balanced dataset covering university study routines, engineering workflows, system actions, and negative conversational inputs (`answers: []`) to eliminate false positives.
* **`data/val.jsonl` (51 samples):** Validation holdout split.
* **`run_finetune.sh`:** Automated reproducible LoRA fine-tuning pipeline using JAX and CQ4 quantization.

---

## 🚀 Quick Start

### 1. Requirements

* Python 3.11+
* `uv` or `pip`

```bash
git clone https://github.com/Wagustin/needle-desktop-jarvis.git
cd needle-desktop-jarvis
pip install cactus-needle
```

### 2. Download Base Engine & Weights

```bash
# For macOS Apple Silicon:
python -m needle.cli download macos-arm64 --out bin/

# For Windows x64:
python -m needle.cli download windows-x86_64 --out bin/
```

### 3. Run the Cross-Platform Client

```bash
# macOS or Windows:
python jarvis_client.py "búscame los apuntes de Sistemas Operativos"
python jarvis_client.py "sube el volumen al 50%"
python jarvis_client.py "abre el campus virtual"
```

---

## 📂 Repository Structure

```
.
├── schemas/
│   └── tools.json               # Formal tool specifications
├── data/
│   ├── train.jsonl              # Spanish fine-tuning training set
│   └── val.jsonl                # Validation split
├── jarvis_client.py             # Unified cross-platform client (macOS & Windows)
├── mac_jarvis_client.py         # macOS specialized runner
├── run_finetune.sh              # LoRA training & build script
└── README.md                    # Documentation
```

---

## 📄 License

MIT License. Designed and maintained by [Agustín](https://github.com/Wagustin).
