#!/bin/bash
# Copies the Windows sources to the Parallels VM (ssh alias "winvm") and builds there.
# Usage: tools/sync-vm.sh [build]
set -euo pipefail
cd "$(dirname "$0")/.."
ssh winvm "cmd /c if exist openphonic-win\OpenPhonic rmdir /s /q openphonic-win\OpenPhonic"
ssh winvm "cmd /c if not exist openphonic-win mkdir openphonic-win"
scp -q -r OpenPhonic tools winvm:openphonic-win/
if [ "${1:-}" = "build" ]; then
  ssh winvm "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\giuseppelupo\\openphonic-win\\tools\\build.ps1"
fi
