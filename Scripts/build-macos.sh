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
  cp "$ANDROID_COMPANION_APK_PATH" "$APP/Contents/Resources/SIMAI-Companion.apk"
  echo "已内置 Android Companion APK"
else
  echo "注意：未设置 ANDROID_COMPANION_APK_PATH，当前本地构建不含 APK。"
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
ARCHIVE="$DIST/SIM-AI-Assistant-v0.4.2-macos-$ARCH.zip"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
echo "构建完成：$APP"
echo "发行包：$ARCHIVE"
echo "打开 App：open \"$APP\""
echo "说明：该应用未经 Apple 公证，仅用于自己 Mac 上的研发测试。"
