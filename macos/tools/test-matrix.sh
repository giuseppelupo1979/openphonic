#!/bin/bash
# Runs the engine over every preset and every option combination; prints one line per run.
# Usage: tools/test-matrix.sh <audio-or-video-file> [work-dir]
set -uo pipefail
cd "$(dirname "$0")/.."
SRC="$1"
WORK="${2:-${TMPDIR:-/tmp}/openphonic-matrix}"
BIN="${BIN:-dist/OpenPhonic.app/Contents/MacOS/OpenPhonic}"
WEB="../web/samples"
rm -rf "$WORK"; mkdir -p "$WORK"
fail=0
run() {
  local name="$1"; shift
  local out
  out=$("$BIN" --process "$SRC" --out "$WORK/$name" "$@" 2>&1)
  if echo "$out" | grep -q "^ERRORE"; then
    echo "FAIL  $name: $(echo "$out" | grep -A6 '^ERRORE' | tr '\n' ' ')"; fail=1
  else
    echo "ok    $name  $(echo "$out" | grep '^DOPO' | cut -c8-)  $(echo "$out" | grep '^TEMPO')"
  fi
}
for p in podcast youtube broadcast audiobook rescue music; do run "preset-$p" --preset "$p"; done
for m in ai rnnoise classic; do for a in auto low medium high max; do run "denoise-$m-$a" --denoise "$m" --amount "$a"; done; done
for c in auto soft medium hard off; do run "compressor-$c" --compressor "$c"; done
EXTRA=()
[ -f "$WEB/intro.wav" ] && EXTRA+=(--intro "$WEB/intro.wav" --outro "$WEB/intro.wav")
[ -f "$WEB/cover.png" ] && EXTRA+=(--cover "$WEB/cover.png")
run "all-options" --all "${EXTRA[@]}"
exit $fail
