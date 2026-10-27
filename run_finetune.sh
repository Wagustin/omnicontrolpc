#!/usr/bin/env bash
# ==============================================================================
# Jarvis Mac - Needle 3 Fine-Tuning Pipeline
# ==============================================================================
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "=== Jarvis Mac: Pipeline de Fine-Tuning para Needle 3 ==="
echo "1. Verificando dataset..."
if [ ! -f "data/train.jsonl" ]; then
    echo "Error: data/train.jsonl no encontrado."
    exit 1
fi

echo "2. Checkpoint base: checkpoints/checkpoints/needle3.safetensors"
mkdir -p checkpoints

echo "3. Ejecutando fine-tuning LoRA (rank 16, alpha 32)..."
uv run --python 3.12 \
    --with cactus-needle \
    --with "jax[cpu]" \
    --with optax \
    --with sentencepiece \
    --with flax \
    --with safetensors \
    python -c "
from needle.cli import main
import sys
sys.argv = [
    'needle', 'finetune', '$DIR/data/train.jsonl',
    '--checkpoint', '$DIR/checkpoints/checkpoints/needle3.safetensors',
    '--epochs', '3',
    '--batch-size', '8',
    '--lora-rank', '16',
    '--max-len', '256',
    '--out', '$DIR/checkpoints/jarvis_lora.safetensors'
]
main()
"

echo "4. Exportando modelo cuantizado .cact para macOS ARM64..."
uv run --python 3.12 --with cactus-needle python -c "
from needle.cli import main
import sys
sys.argv = [
    'needle', 'build', '$DIR/checkpoints/checkpoints/needle3.safetensors',
    '--lora', '$DIR/checkpoints/jarvis_lora.safetensors',
    '--out', '$DIR/jarvis_mac_es.cact',
    '--platform', 'macos-arm64'
]
main()
"

echo "=== Proceso finalizado exitosamente. Artefacto listo en $DIR/jarvis_mac_es.cact ==="
