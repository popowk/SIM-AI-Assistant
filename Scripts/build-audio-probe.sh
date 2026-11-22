#!/bin/bash
# Build a short-lived, permission-limited Android 13+ audio compatibility probe.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ANDROID_JAR="$SDK/platforms/android-35/android.jar"
D8="$SDK/build-tools/35.0.0/d8"
[[ -f "$ANDROID_JAR" && -x "$D8" ]] || { echo "Android SDK 35/build-tools 35.0.0 required" >&2; exit 1; }
TMP="$ROOT/AudioProbe/build"
mkdir -p "$TMP/classes" "$ROOT/dist"
rm -rf "$TMP/classes"
mkdir -p "$TMP/classes"
javac --release 11 -cp "$ANDROID_JAR" -d "$TMP/classes" \
    "$ROOT/AudioProbe/src/dev/popowk/simai/probe/"*.java
OUT="$ROOT/dist/SIMAI-Audio-Probe.jar"
rm -f "$OUT"
"$D8" --min-api 33 --lib "$ANDROID_JAR" --output "$OUT" \
    "$TMP"/classes/dev/popowk/simai/probe/*.class
test -s "$OUT"
jar tf "$OUT" | grep -q "classes.dex"
echo "Android audio capability test helper built: $OUT"
