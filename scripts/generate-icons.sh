#!/bin/zsh
# Generates the 3D glass icon set with Nano Banana through the Antigravity CLI (agy), then keys out the
# black backdrop into assets/icons3d. Usage:
#   scripts/generate-icons.sh              # only icons missing from assets/icons3d
#   scripts/generate-icons.sh mac trash    # regenerate specific icons
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW="$(mktemp -d)"
mkdir -p "$RAW/logs"

gen() {
  local name="$1" subject="$2"
  (cd "$RAW" && agy -p "Using your image generation tool (Nano Banana), generate ONE image and save it as the PNG file ./$name.png in the current directory (overwrite if present). Subject: $subject. Style: an original premium 3D macOS app icon render — soft rounded inflated toy-like shapes, made of translucent frosted glass and polished white ceramic, luminous inner glow and bright rim light on the edges, soft subsurface scattering, glossy specular highlights, strictly monochrome palette of white, silver and icy light grey (no color hues), soft studio lighting from top-left. Composition: single object, centered, filling about 75% of the frame, square 1:1. Background: perfectly flat pure black #000000, no floor, no reflection, no cast shadow, no text, no letters except the subject's own symbols, no logos, no watermark. Reply only with the saved file path." \
    --dangerously-skip-permissions --print-timeout 400s > "logs/$name.log" 2>&1)
  [ -f "$RAW/$name.png" ] && echo "✓ $name" || echo "✗ $name (ver $RAW/logs/$name.log)"
}

while IFS='|' read -r name subject; do
  [ -z "$name" ] && continue
  if [ $# -gt 0 ]; then
    [[ " $* " == *" $name "* ]] || continue
  elif [ -f "$ROOT/assets/icons3d/$name.png" ]; then
    continue
  fi
  gen "$name" "$subject" &
  # Nano Banana quota is tight: at most 3 renders in flight.
  while [ "$(jobs -r | wc -l)" -ge 3 ]; do sleep 2; done
done < "$ROOT/scripts/icons3d-prompts.txt"
wait

swift "$ROOT/scripts/process-icons.swift" "$RAW" "$ROOT/assets/icons3d"
