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
echo "   / __ \____ ___  ____  (_)/ ____/___  ____  / /__________  / / "
echo "  / / / / __ \`__ \/ __ \/ // /   / __ \/ __ \/ __/ ___/ __ \/ /  "
echo " / /_/ / / / / / / / / / // /___/ /_/ / / / / /_/ /  / /_/ / /   "
echo " \____/_/ /_/ /_/_/ /_/_(_)____/\____/_/ /_/\__/_/   \____/_/    "
echo "                                              macOS & Linux Edition"
echo "  =============================================================="
echo -e "${NC}"

INSTALL_DIR="$HOME/.omnicontrolpc"
echo -e "${YELLOW}[*] Directorio de instalación: $INSTALL_DIR${NC}"
mkdir -p "$INSTALL_DIR"

# 1. Clonar o actualizar
echo -e "${GREEN}[1/3] Descargando componentes de OmniControl PC...${NC}"
if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" pull origin main
else
    git clone https://github.com/Wagustin/omnicontrolpc.git "$INSTALL_DIR"
fi

# 2. Verificar Python y dependencias
echo -e "${GREEN}[2/3] Verificando Python y librerías...${NC}"
if command -v python3 &>/dev/null; then
    PY_BIN="python3"
elif command -v python &>/dev/null; then
    PY_BIN="python"
else
    echo -e "${YELLOW}[!] Python no detectado. Instálalo con 'brew install python' (macOS).${NC}"
    exit 1
fi

$PY_BIN -m pip install --quiet cactus-needle || true

# 3. Crear alias o script ejecutable en ~/.local/bin
echo -e "${GREEN}[3/3] Configurando comando global 'omnicontrol'...${NC}"
mkdir -p "$HOME/.local/bin"

cat << 'EOF' > "$HOME/.local/bin/omnicontrol"
#!/usr/bin/env bash
DIR="$HOME/.omnicontrolpc"
if command -v python3 &>/dev/null; then
    python3 "$DIR/jarvis_client.py" "$@"
else
    python "$DIR/jarvis_client.py" "$@"
fi
EOF

chmod +x "$HOME/.local/bin/omnicontrol"

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
