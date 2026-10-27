#!/usr/bin/env bash
set -e

# =====================================================================
# OmniControl PC - macOS / Linux Installer
# Ultralight (<35MB) On-Device System Assistant & Tool Engine
# =====================================================================

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${CYAN}${BOLD}"
echo "  =============================================================="
echo "    ____                  _  ______            __             __ "
echo "   / __ \\____ ___  ____  (_)/ ____/___  ____  / /__________  / / "
echo "  / / / / __ \`__ \\/ __ \\/ // /   / __ \\/ __ \\/ __/ ___/ __ \\/ /  "
echo " / /_/ / / / / / / / / / // /___/ /_/ / / / / /_/ /  / /_/ / /   "
echo " \\____/_/ /_/ /_/_/ /_/_(_)____/\\____/_/ /_/\\__/_/   \\____/_/    "
echo "                                              macOS & Linux Edition"
echo "  ============================================================== "
echo -e "${NC}"

INSTALL_DIR="$HOME/.omnicontrolpc"
echo -e "${YELLOW}[*] Directorio de instalación: $INSTALL_DIR${NC}"
mkdir -p "$INSTALL_DIR"

# 1. Clonar o actualizar repositorio
echo -e "${GREEN}[1/4] Descargando componentes de OmniControl PC...${NC}"
if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" pull --quiet origin main || true
else
    git clone --quiet https://github.com/Wagustin/omnicontrolpc.git "$INSTALL_DIR"
fi

# 2. Preparar entorno Python aislado (PEP 668 safe)
echo -e "${GREEN}[2/4] Configurando entorno virtual aislado...${NC}"
VENV_DIR="$INSTALL_DIR/.venv"

if command -v uv &>/dev/null; then
    if [ ! -d "$VENV_DIR" ]; then
        uv venv --quiet --python 3.12 "$VENV_DIR" 2>/dev/null || uv venv --quiet "$VENV_DIR"
    fi
    uv pip install --quiet --python "$VENV_DIR/bin/python" cactus-needle
elif command -v python3 &>/dev/null; then
    if [ ! -d "$VENV_DIR" ]; then
        python3 -m venv "$VENV_DIR"
    fi
    "$VENV_DIR/bin/pip" install --quiet cactus-needle
else
    echo -e "${YELLOW}[!] Python no detectado. Instálalo con 'brew install python' (macOS).${NC}"
    exit 1
fi

# 3. Crear comando global en ~/.local/bin
echo -e "${GREEN}[3/4] Configurando comando global 'omnicontrol'...${NC}"
mkdir -p "$HOME/.local/bin"

cat << 'EOF' > "$HOME/.local/bin/omnicontrol"
#!/usr/bin/env bash
DIR="$HOME/.omnicontrolpc"
if [ -f "$DIR/.venv/bin/python" ]; then
    exec "$DIR/.venv/bin/python" "$DIR/jarvis_client.py" "$@"
elif command -v python3 &>/dev/null; then
    exec python3 "$DIR/jarvis_client.py" "$@"
else
    exec python "$DIR/jarvis_client.py" "$@"
fi
EOF

chmod +x "$HOME/.local/bin/omnicontrol"

# 4. Asegurar PATH en shell del usuario
echo -e "${GREEN}[4/4] Verificando variables de entorno...${NC}"
SHELL_RC=""
if [ -n "$ZSH_VERSION" ] || [ "$SHELL" = "/bin/zsh" ]; then
    SHELL_RC="$HOME/.zshrc"
elif [ -n "$BASH_VERSION" ] || [ "$SHELL" = "/bin/bash" ]; then
    SHELL_RC="$HOME/.bashrc"
fi

if [ -n "$SHELL_RC" ] && [ -f "$SHELL_RC" ]; then
    if ! grep -q '\.local/bin' "$SHELL_RC"; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
    fi
fi

echo -e "${CYAN}${BOLD}"
echo "  =============================================================="
echo "    ¡INSTALACIÓN COMPLETADA CON ÉXITO!"
echo "  =============================================================="
echo -e "${NC}"
echo "  Puedes usar OmniControl PC desde cualquier terminal:"
echo -e "    ${GREEN}omnicontrol \"sube el volumen al 50%\"${NC}"
echo -e "    ${GREEN}omnicontrol \"busca apuntes de Sistemas Operativos\"${NC}"
echo -e "    ${GREEN}omnicontrol \"abre el campus virtual\"${NC}"
echo "  =============================================================="
