# Sourced by the other scripts: sets $GODOT to the Godot 4 binary.
if [[ -z "${GODOT:-}" ]]; then
  for c in /Applications/Godot.app/Contents/MacOS/Godot "$HOME/Applications/Godot.app/Contents/MacOS/Godot" "$(command -v godot 2>/dev/null || true)"; do
    if [[ -n "$c" && -x "$c" ]]; then GODOT="$c"; break; fi
  done
fi
if [[ -z "${GODOT:-}" || ! -x "$GODOT" ]]; then
  echo "Godot 4 not found. Install it with: brew install --cask godot   (or set GODOT=/path/to/Godot)" >&2
  exit 1
fi
export GODOT
