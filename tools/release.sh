#!/bin/bash
# Builds every edition for the version in VERSION, computes SHA-256 checksums and publishes a GitHub
# release that the apps' self-updater picks up.
#
#   tools/release.sh --dry-run   build and stage everything in dist/release/, publish nothing
#   tools/release.sh             build, then tag vX.Y.Z and create the GitHub release
#
# Needs: the Mac build tools (macos/tools/build-app.sh), the Windows VM reachable as "winvm"
# (windows/tools/sync-vm.sh), gh logged in. Release notes come from the matching CHANGELOG.md section.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="$(head -1 VERSION | tr -d '[:space:]')"
TAG="v$VERSION"
OUT="$ROOT/dist/release"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# release notes: the CHANGELOG section of this version
NOTES="$(awk -v v="## $VERSION" '$0==v {on=1; next} /^## / && on {exit} on' CHANGELOG.md)"
[ -n "$(echo "$NOTES" | tr -d '[:space:]')" ] || { echo "Manca la sezione '## $VERSION' in CHANGELOG.md"; exit 1; }
if [ $DRY = 0 ]; then
  [ -z "$(git status --porcelain)" ] || { echo "Ci sono modifiche non committate: committa prima di rilasciare"; exit 1; }
  git rev-parse "$TAG" >/dev/null 2>&1 && { echo "Il tag $TAG esiste già: alza VERSION"; exit 1; }
fi

rm -rf "$OUT"; mkdir -p "$OUT"

echo "== Mac $VERSION"
macos/tools/build-app.sh
cp macos/dist/OpenPhonic-macos.zip "$OUT/"

echo "== Windows $VERSION (VM)"
windows/tools/sync-vm.sh
for rid in win-x64 win-arm64; do
  ssh winvm "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\giuseppelupo\\openphonic-win\\tools\\build.ps1 -Rid $rid -Zip"
  scp -q "winvm:openphonic-win/dist/OpenPhonic-$rid.zip" "$OUT/"
done

echo "== SHA-256"
(cd "$OUT" && for f in *.zip; do shasum -a 256 "$f" > "$f.sha256"; cat "$f.sha256"; done)
printf '%s\n' "$NOTES" > "$OUT/NOTE.md"

if [ $DRY = 1 ]; then
  echo "Prova completata: pacchetti in $OUT (niente pubblicato)"
  exit 0
fi

echo "== GitHub release $TAG"
git tag -a "$TAG" -m "OpenPhonic $VERSION"
git push origin "$TAG"
gh release create "$TAG" --verify-tag --title "OpenPhonic $VERSION" --notes-file "$OUT/NOTE.md" "$OUT"/*.zip "$OUT"/*.sha256
echo "Pubblicata: $(gh release view "$TAG" --json url --jq .url)"
