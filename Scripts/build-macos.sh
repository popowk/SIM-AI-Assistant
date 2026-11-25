#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "错误：此构建脚本只能在安装 Xcode Command Line Tools 的 macOS 上执行。" >&2
  exit 1
fi

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "错误：请先运行 xcode-select --install 安装 Xcode Command Line Tools。" >&2
  exit 1
fi

echo "[1/5] 运行核心单元测试..."
swift test

echo "[2/5] 编译原生 macOS 应用..."
BUILD_TRIPLE_ARGS=()
if [[ -n "${TARGET_TRIPLE:-}" ]]; then
  BUILD_TRIPLE_ARGS=(--triple "$TARGET_TRIPLE")
  echo "目标架构：$TARGET_TRIPLE"
fi
swift build --configuration release --product SIMAIAssistant "${BUILD_TRIPLE_ARGS[@]}"
BIN_DIR="$(swift build --configuration release --show-bin-path "${BUILD_TRIPLE_ARGS[@]}")"
BIN="$BIN_DIR/SIMAIAssistant"
if [[ ! -x "$BIN" ]]; then
  echo "错误：未找到编译出的主程序 $BIN" >&2
  exit 2
fi

DIST="$ROOT/dist"
APP="$DIST/SIM AI Assistant.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/SIMAIAssistant"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -n "${ANDROID_COMPANION_APK_PATH:-}" ]]; then
  if [[ ! -s "$ANDROID_COMPANION_APK_PATH" ]]; then
    echo "错误：Android 伴侣 APK 不存在或为空：$ANDROID_COMPANION_APK_PATH" >&2
    exit 4
  fi
  APK_GRADLE="$ROOT/AndroidCompanion/app/build.gradle.kts"
  APK_NAME="$(sed -nE 's/^[[:space:]]*versionName[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$APK_GRADLE" | head -n 1)"
  APK_CODE="$(sed -nE 's/^[[:space:]]*versionCode[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$APK_GRADLE" | head -n 1)"
  if [[ -z "$APK_NAME" || -z "$APK_CODE" ]]; then
    echo "::error::无法从 Android build.gradle.kts 获取 APK 的真实版本号" >&2
    exit 7
  fi
  # Verify the compiled package, not just the version text in source.
  if [[ -n "${ANDROID_HOME:-}" && -x "$ANDROID_HOME/build-tools/35.0.0/aapt" ]]; then
    APK_BADGING="$("$ANDROID_HOME/build-tools/35.0.0/aapt" dump badging "$ANDROID_COMPANION_APK_PATH")"
    if ! printf '%s\n' "$APK_BADGING" | grep -Fq "versionCode='$APK_CODE'" ||
       ! printf '%s\n' "$APK_BADGING" | grep -Fq "versionName='$APK_NAME'"; then
      echo "::error::内置 APK 的 AndroidManifest 版本与 Gradle 版本不一致" >&2
      exit 8
    fi
  elif [[ "${CI:-}" == "true" ]]; then
    echo "::error::CI 环境缺少 aapt，无法验证内置 APK 的版本" >&2
    exit 9
  fi
  cp "$ANDROID_COMPANION_APK_PATH" "$APP/Contents/Resources/SIMAI-Companion.apk"
  printf 'v%s (versionCode %s)\n' "$APK_NAME" "$APK_CODE" > \
    "$APP/Contents/Resources/SIMAI-Companion-version.txt"
  echo "已内置并验证 Android Companion v$APK_NAME (versionCode $APK_CODE)"
else
  echo "注意：未设置 ANDROID_COMPANION_APK_PATH，当前本地构建不含 APK。"
fi

if [[ -n "${ANDROID_COMPANION_SIGNING_STATUS_PATH:-}" ]]; then
  if [[ ! -s "$ANDROID_COMPANION_SIGNING_STATUS_PATH" ]]; then
    echo "错误：Android APK 签名状态文件不存在。" >&2
    exit 6
  fi
  cp "$ANDROID_COMPANION_SIGNING_STATUS_PATH" "$APP/Contents/Resources/SIMAI-Android-Signing.txt"
fi

if [[ -n "${ANDROID_AUDIO_PROBE_JAR_PATH:-}" ]]; then
  if [[ ! -s "$ANDROID_AUDIO_PROBE_JAR_PATH" ]]; then
    echo "错误：Android 音频诊断助手文件缺失：$ANDROID_AUDIO_PROBE_JAR_PATH" >&2
    exit 5
  fi
  cp "$ANDROID_AUDIO_PROBE_JAR_PATH" "$APP/Contents/Resources/SIMAI-Audio-Probe.jar"
  echo "已内置 Android 13 电话音频兼容性助手"
else
  echo "注意：未设置 ANDROID_AUDIO_PROBE_JAR_PATH，本地构建不含电话音频诊断助手。"
fi

if [[ "$(uname -m)" == "arm64" && "${TARGET_TRIPLE:-arm64}" == arm64* ]]; then
  bash "$ROOT/Scripts/build-local-reception.sh" "$APP/Contents/Resources/LocalReception"
else
  echo "本地轻量模型目前只为 Apple Silicon 打包"
fi

chmod +x "$APP/Contents/MacOS/SIMAIAssistant"

if [[ -n "${TARGET_TRIPLE:-}" ]]; then
  EXPECTED_ARCH="${TARGET_TRIPLE%%-*}"
  if ! xcrun lipo -archs "$APP/Contents/MacOS/SIMAIAssistant" | grep -qw "$EXPECTED_ARCH"; then
    echo "错误：构建产物不包含目标架构 $EXPECTED_ARCH" >&2
    exit 3
  fi
fi

echo "[3/5] 校验 app plist..."
plutil -lint "$APP/Contents/Info.plist"

echo "[4/5] 本机临时签名（非 Apple 公证）..."
codesign --force --sign - "$APP"
codesign --verify --verbose "$APP"

echo "[5/5] 生成发行 ZIP..."
ARCH="${TARGET_TRIPLE%%-*}"
if [[ -z "${TARGET_TRIPLE:-}" ]]; then ARCH="$(uname -m)"; fi
VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.4.43")"
ARCHIVE="$DIST/SIM-AI-Assistant-v${VERSION}-macos-$ARCH.zip"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
echo "构建完成：$APP"
echo "发行包：$ARCHIVE"
echo "打开 App：open \"$APP\""
echo "说明：该应用未经 Apple 公证，仅用于自己 Mac 上的研发测试。"
