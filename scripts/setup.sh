#!/bin/bash
# One-time local setup: Python env, DeepFilterNet binary, RNNoise model.
set -euo pipefail
cd "$(dirname "$0")/.."

DF_VERSION=0.5.6
RNN_URL="https://raw.githubusercontent.com/GregorR/rnnoise-models/master/somnolent-hogwash-2018-09-01/sh.rnnn"

command -v ffmpeg >/dev/null || { echo "ffmpeg >= 7 is required (brew install ffmpeg / apt install ffmpeg)"; exit 1; }
command -v uv >/dev/null || { echo "uv is required: https://docs.astral.sh/uv/"; exit 1; }

uv venv -p 3.12 .venv
uv pip install -p .venv -r requirements.txt
[ "${WITH_ASR:-1}" = "1" ] && uv pip install -p .venv -r requirements-asr.txt

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  T=aarch64-apple-darwin ;;
  Darwin-x86_64) T=x86_64-apple-darwin ;;
  Linux-aarch64) T=aarch64-unknown-linux-gnu ;;
  Linux-x86_64)  T=x86_64-unknown-linux-musl ;;
  *) echo "No DeepFilterNet build for this platform: RNNoise will be used"; T="" ;;
esac
mkdir -p bin models
if [ -n "$T" ]; then
  curl -fL -o "bin/deep-filter-$DF_VERSION-$T" \
    "https://github.com/Rikorose/DeepFilterNet/releases/download/v$DF_VERSION/deep-filter-$DF_VERSION-$T"
  chmod +x "bin/deep-filter-$DF_VERSION-$T"
  xattr -d com.apple.quarantine "bin/deep-filter-$DF_VERSION-$T" 2>/dev/null || true
fi
curl -fL -o models/std.rnnn "$RNN_URL"
echo "Ready: .venv/bin/uvicorn app.main:app --port 8765"
