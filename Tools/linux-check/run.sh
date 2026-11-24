#!/usr/bin/env bash
# Quick checks on Linux (without Xcode):
#  1. builds + runs the tests for the portable code (hau-di/Core)
#  2. checks the syntax (swiftc -parse) of all the app's Swift files
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SWIFT_BIN="${SWIFT_BIN:-swift}"
SWIFTC_BIN="${SWIFTC_BIN:-swiftc}"
WORK="${HAU_DI_CHECK_DIR:-$(mktemp -d)}"

rm -rf "$WORK/Sources" "$WORK/Tests"
mkdir -p "$WORK/Sources/HauDiCore" "$WORK/Tests/HauDiCoreTests"
cp "$ROOT"/hau-di/Core/*.swift "$WORK/Sources/HauDiCore/"
cp "$ROOT"/Tools/linux-check/Tests/*.swift "$WORK/Tests/HauDiCoreTests/"
cp "$ROOT"/Tools/linux-check/Package.swift "$WORK/Package.swift"

echo "== Syntax check (swiftc -parse) =="
fail=0
while IFS= read -r -d '' file; do
  if ! "$SWIFTC_BIN" -parse "$file" >/dev/null 2>"$WORK/parse.err"; then
    echo "FAIL: ${file#$ROOT/}"; cat "$WORK/parse.err"; fail=1
  fi
done < <(find "$ROOT/hau-di" -name '*.swift' -print0)
[ "$fail" -eq 0 ] && echo "OK: all files have valid syntax"

echo "== Core build + tests =="
cd "$WORK"
"$SWIFT_BIN" test 2>&1 | tail -40
exit $fail
