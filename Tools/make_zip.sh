#!/usr/bin/env bash
# Creates dist/hau-di.zip with the project ready to open in Xcode.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p dist
# Haudi.zip is the archive from before the rename: delete it, so that it is not downloaded by mistake.
rm -f dist/hau-di.zip dist/Haudi.zip
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/hau-di"
cp -R hau-di.xcodeproj hau-di Config Tools README.md LICENSE BRANDING.md THIRD_PARTY_NOTICES.md .gitignore .gitattributes "$STAGE/hau-di/"
find "$STAGE" -name '.DS_Store' -delete
find "$STAGE" -name '__pycache__' -type d -prune -exec rm -rf {} +
(cd "$STAGE" && zip -qr -X "$ROOT/dist/hau-di.zip" hau-di)
rm -rf "$STAGE"
echo "Created: $ROOT/dist/hau-di.zip ($(du -h dist/hau-di.zip | cut -f1))"
