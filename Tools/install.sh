#!/usr/bin/env bash
# Builds hau-di (Release, Apple Silicon) and installs it in /Applications,
# so that it runs independently of Xcode.
#
#   ./Tools/install.sh                           builds the current sources and installs
#   ./Tools/install.sh ~/Downloads/hau-di.zip    first updates the project from the zip (keeping the Team chosen in Xcode),
#                                                then builds and installs
#
# The move from the old name (Haudi, until 2026-11-23) is automatic:
#   - if the project has no Team, it takes it from the old Haudi/ project next to it (../Haudi/Haudi.xcodeproj);
#   - stops and deletes /Applications/Haudi.app, then clears the old permissions (ro.cx.app.haudi).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/Tools/install.sh"
# The archive path is made absolute before `cd`, so that relative paths work too.
if [ $# -ge 1 ]; then
  [ -f "$1" ] || { echo "Cannot find the archive $1"; exit 1; }
  set -- "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
fi
APP_NAME="hau-di"
BUNDLE_ID="ro.cx.app.hau-di"
APP_DEST="/Applications/hau-di.app"
PBX="$ROOT/hau-di.xcodeproj/project.pbxproj"
# The old versions, cleaned up on install: bundle IDs, apps and processes.
LEGACY_BUNDLE_IDS=("ro.cx.app.haudi" "ro.haudi.app")
LEGACY_APPS=("/Applications/Haudi.app")
LEGACY_PROCESSES=("Haudi")
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cd "$ROOT"
if [ ! -d "hau-di.xcodeproj" ] || [ ! -d "hau-di" ]; then
  echo "Cannot find hau-di.xcodeproj in $ROOT. Run the script from the hau-di project folder."
  exit 1
fi

# The signing Team chosen in Xcode (DEVELOPMENT_TEAM) from a project.pbxproj; empty if there is none.
team_of() {
  if [ -f "$1" ]; then
    grep -m1 -oE 'DEVELOPMENT_TEAM = [A-Z0-9]{10};' "$1" | sed -E 's/DEVELOPMENT_TEAM = ([A-Z0-9]{10});/\1/' || true
  fi
}

TEAM="$(team_of "$PBX")"

if [ $# -ge 1 ]; then
  ZIP="$1"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  unzip -q "$ZIP" -d "$TMP"
  SRC="$TMP/hau-di"
  if [ ! -d "$SRC/hau-di" ] || [ ! -d "$SRC/hau-di.xcodeproj" ]; then
    echo "The archive does not have the expected structure (hau-di/hau-di and hau-di/hau-di.xcodeproj)."
    exit 1
  fi

  # The install script in the zip is newer: use it for the remaining steps.
  if [ -z "${HAU_DI_INSTALL_UPDATED:-}" ] && [ -f "$SRC/Tools/install.sh" ] && ! cmp -s "$SRC/Tools/install.sh" "$SELF"; then
    cp "$SRC/Tools/install.sh" "$SELF.new" && chmod +x "$SELF.new" && mv "$SELF.new" "$SELF"
    rm -rf "$TMP"
    trap - EXIT
    echo "-> The install script was updated; continuing with the new version."
    exec env HAU_DI_INSTALL_UPDATED=1 bash "$SELF" "$@"
  fi

  echo "-> Updating the project from $ZIP..."
  rsync -a --delete "$SRC/hau-di/" "$ROOT/hau-di/"
  rsync -a --exclude 'xcuserdata' "$SRC/hau-di.xcodeproj/" "$ROOT/hau-di.xcodeproj/"
  rsync -a "$SRC/Tools/" "$ROOT/Tools/"
  rsync -a "$SRC/Config/" "$ROOT/Config/"
  for f in README.md LICENSE BRANDING.md THIRD_PARTY_NOTICES.md .gitignore .gitattributes; do
    if [ -f "$SRC/$f" ]; then rsync -a "$SRC/$f" "$ROOT/$f"; fi
  done
fi

# No Team in the project (new zip or freshly unpacked project): take it from the old Haudi project, if it is next to it.
if [ -z "$TEAM" ]; then
  for old in "$ROOT/../Haudi/Haudi.xcodeproj/project.pbxproj" "$ROOT/Haudi.xcodeproj/project.pbxproj"; do
    TEAM="$(team_of "$old")"
    if [ -n "$TEAM" ]; then
      echo "   Signing Team taken from the old project: $old"
      break
    fi
  done
fi
if [ -n "$TEAM" ]; then
  sed -i '' -E "s/DEVELOPMENT_TEAM = \"\";/DEVELOPMENT_TEAM = $TEAM;/g" "$PBX"
  echo "   Signing Team: $TEAM"
else
  echo "   WARNING: the project has no Team selected. Choose one in Xcode (Signing & Capabilities),"
  echo "   otherwise macOS asks for the permissions again after every build."
fi

BUILD="$ROOT/build"
LOG="$BUILD/xcodebuild.log"
mkdir -p "$BUILD"
# A unique build number on every install (e.g. 261121.2345). macOS (Dock, Finder) caches icons
# by app version: without a new version, the Dock may keep showing the old icon.
STAMP="$(date +%y%m%d%H%M)"
BUILD_NUMBER="${STAMP:0:6}.$((10#${STAMP:6:4}))"
echo "-> Building hau-di (Release, arm64). The first time takes a few minutes..."
if ! xcodebuild \
    -project hau-di.xcodeproj \
    -scheme hau-di \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$BUILD/DerivedData" \
    -allowProvisioningUpdates \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build >"$LOG" 2>&1; then
  echo "ERROR: build failed. First errors:"
  grep -E "error:" "$LOG" | head -30 || tail -30 "$LOG"
  echo "Full log: $LOG"
  exit 1
fi

APP="$BUILD/DerivedData/Build/Products/Release/hau-di.app"
[ -d "$APP" ] || { echo "Build succeeded, but cannot find $APP"; exit 1; }

# The bundle IDs of the apps installed so far (the current one and the old ones).
PREVIOUS_IDS=""
for app in "$APP_DEST" "${LEGACY_APPS[@]}"; do
  if [ -d "$app" ]; then
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
    PREVIOUS_IDS="$PREVIOUS_IDS $id"
  fi
done

for proc in "$APP_NAME" "${LEGACY_PROCESSES[@]}"; do
  if pgrep -x "$proc" >/dev/null; then
    echo "-> Stopping the running $proc instance..."
    pkill -x "$proc" || true
    for _ in $(seq 1 20); do
      pgrep -x "$proc" >/dev/null || break
      sleep 0.25
    done
  fi
done

echo "-> Installing to $APP_DEST..."
rm -rf "$APP_DEST"
ditto "$APP" "$APP_DEST"
for app in "${LEGACY_APPS[@]}"; do
  if [ -d "$app" ]; then
    echo "-> Deleting the old version $app..."
    "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
    rm -rf "$app"
  fi
done
# macOS caches icons: announce that the app has changed, so that the new icon shows up.
touch "$APP_DEST"
"$LSREGISTER" -f "$APP_DEST" >/dev/null 2>&1 || true

# Moving from an old bundle ID: macOS sees the app as a new one. Remove the old entries
# from Accessibility / Microphone, so that the old version does not stay in the lists too.
CHANGED_ID=""
for legacy in "${LEGACY_BUNDLE_IDS[@]}"; do
  case " $PREVIOUS_IDS " in *" $legacy "*) found=1 ;; *) found="" ;; esac
  if [ -n "$found" ] || [ -n "${HAU_DI_RESET_LEGACY:-}" ]; then
    [ -n "$found" ] && CHANGED_ID="$legacy"
    echo "-> Clearing the old permissions for $legacy..."
    tccutil reset Accessibility "$legacy" >/dev/null 2>&1 || echo "   (Accessibility: remove the old entry from the list manually)"
    tccutil reset Microphone "$legacy" >/dev/null 2>&1 || true
    tccutil reset ListenEvent "$legacy" >/dev/null 2>&1 || true
    tccutil reset PostEvent "$legacy" >/dev/null 2>&1 || true
  fi
done

open "$APP_DEST"
echo "OK: hau-di ($BUNDLE_ID, build $BUILD_NUMBER) is running from /Applications; you can close Xcode."
if [ -n "$CHANGED_ID" ]; then
  echo "   New ID ($CHANGED_ID -> $BUNDLE_ID): grant Microphone and Accessibility again in the Start window"
  echo "   and turn on General -> Launch hau-di at login again. The settings, history, models and API key"
  echo "   are moved automatically (macOS may ask for your password once, for the key in the Keychain)."
fi
