#!/bin/zsh
# Installs the free local neural voice (Kokoro-82M, Apache-2.0) into tts/venv and
# downloads its model files (~340 MB). Filo uses it automatically when present.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-$(command -v python3)}"
mkdir -p "$ROOT/tts/models"
[[ -x "$ROOT/tts/venv/bin/python3" ]] || "$PY" -m venv "$ROOT/tts/venv"
"$ROOT/tts/venv/bin/pip" install --quiet --upgrade pip
"$ROOT/tts/venv/bin/pip" install --quiet kokoro-onnx soundfile numpy
cd "$ROOT/tts/models"
for f in kokoro-v1.0.onnx voices-v1.0.bin; do
  [[ -f "$f" ]] || curl -L --progress-bar -o "$f" "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/$f"
done
echo "Voice installed. Test: $ROOT/tts/venv/bin/python3 $ROOT/tts/kokoro_server.py --port 47823"
