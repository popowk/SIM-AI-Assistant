#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS framework integration requires a Mac; running portable core tests only."
  swift test
  exit 0
fi
swift test
swift build -c debug --product SIMAIAssistant
printf '\n核验通过：运行 scripts/build-macos.sh 打包应用。\n'
