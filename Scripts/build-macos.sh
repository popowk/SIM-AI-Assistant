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
ARCHIVE="$DIST/SIM-AI-Assistant-v0.1.0-macos-$ARCH.zip"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
echo "构建完成：$APP"
echo "发行包：$ARCHIVE"
echo "打开 App：open \"$APP\""
echo "说明：该应用未经 Apple 公证，仅用于自己 Mac 上的研发测试。"
