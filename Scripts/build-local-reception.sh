#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"
test "$(uname -s)" = Darwin
test "$(uname -m)" = arm64
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT/lib" "$WORK/models" "$WORK/runtime"
RUNTIME="https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts-lib.tar.bz2"
MODEL="https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/resolve/204ad334e2e683fd295359930cc16fc0432a23ac"
download() { curl --fail --location --retry 3 --connect-timeout 20 --max-time 240 "$1" -o "$2"; }
download "$RUNTIME" "$WORK/runtime.tar.bz2"
printf '%s  %s\n' f3e0cbd86cc3f38dad30c97921b40e9a8bcc6f2c943777eb76ad77176993e417 "$WORK/runtime.tar.bz2" | shasum -a 256 -c -
tar -xjf "$WORK/runtime.tar.bz2" -C "$WORK/runtime"
API="$(find "$WORK/runtime" -name 'libsherpa-onnx-c-api.dylib' -print -quit)"
test -n "$API" && test -f "$API"
LIBDIR="$(dirname "$API")"
for dylib in "$LIBDIR"/*.dylib; do cp -Pp "$dylib" "$OUT/lib/"; done
HEADER="$(find "$WORK/runtime" -name c-api.h -print -quit)"
if [[ -z "$HEADER" ]]; then
  download "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/sherpa-onnx/c-api/c-api.h" "$WORK/c-api.h"
  HEADER="$WORK/c-api.h"
fi
for filename in encoder-epoch-99-avg-1.int8.onnx decoder-epoch-99-avg-1.int8.onnx joiner-epoch-99-avg-1.int8.onnx tokens.txt; do
  download "$MODEL/$filename" "$WORK/models/$filename"
  test -s "$WORK/models/$filename"
done
download "$MODEL/README.md" "$OUT/MODEL-README.md"
# Only the checksum manifest is bundled; model weights stay outside the app.
(cd "$WORK/models" && shasum -a 256 *.onnx tokens.txt) > "$OUT/model-sha256.txt"
download "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/LICENSE" "$OUT/LICENSE-sherpa-onnx.txt"
printf '%s\n' 'Model: csukuangfj/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23 (Apache-2.0), revision 204ad334e2e683fd295359930cc16fc0432a23ac; runtime: sherpa-onnx v1.13.8.' > "$OUT/THIRD-PARTY.txt"
# Library bundle may ship copyright/third-party notices.
find "$WORK/runtime" -type f \( -iname '*license*' -o -iname '*notice*' \) -exec cp -n {} "$OUT/" \;
xcrun clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=13.0 \
  -I"$(dirname "$HEADER")" "$ROOT/LocalReception/asr-main.cc" \
  -L"$OUT/lib" -lsherpa-onnx-c-api -Wl,-rpath,@loader_path/lib \
  -Wl,-headerpad_max_install_names -o "$OUT/simai-local-asr"
# Make any absolute third-party install name relocatable.
for binary in "$OUT/simai-local-asr" "$OUT/lib/"*.dylib; do
  [[ -L "$binary" ]] && continue
  while IFS= read -r dependency; do
    case "$dependency" in
      @*|/usr/lib/*|/System/Library/*) continue ;;
    esac
    name="$(basename "$dependency")"
    if [[ -e "$OUT/lib/$name" ]]; then
      if [[ "$binary" == "$OUT/simai-local-asr" ]]; then rel="@loader_path/lib/$name"; else rel="@loader_path/$name"; fi
      install_name_tool -change "$dependency" "$rel" "$binary"
    fi
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
done
for binary in "$OUT/lib/"*.dylib; do
  [[ -L "$binary" ]] && continue
  codesign --force --sign - "$binary"
done
codesign --force --sign - "$OUT/simai-local-asr"
# Exercise real bundled weights and 16-kHz PCM, not only linking/launch.
download "$MODEL/test_wavs/0.wav" "$WORK/source.wav"
afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/source.wav" "$WORK/test.wav"
python3 - "$OUT" "$WORK/test.wav" "$WORK/models" <<'PY'
import pathlib, subprocess, sys, wave
root = pathlib.Path(sys.argv[1])
with wave.open(sys.argv[2], 'rb') as f:
    assert (f.getnchannels(),f.getsampwidth(),f.getframerate()) == (1,2,16000)
    audio = f.readframes(f.getnframes())
audio += b'\0' * (16000 * 2 * 4)
audio += b'\0' * (-len(audio) % 640)
data = b''.join(b'\0' + audio[i:i+640] for i in range(0,len(audio),640))
p = subprocess.run([str(root/'simai-local-asr'), sys.argv[3]], input=data, capture_output=True, timeout=60)
assert p.returncode == 0, f"ASR exited {p.returncode}: {p.stderr[-500:]}"
assert b'SIMAI_READY' in p.stdout and b'SIMAI_TEXT ' in p.stdout, 'ASR did not recognize fixture'
print('LOCAL_ASR_PCM_FIXTURE_OK')
print('LOCAL_MODEL_BYTES=' + str(sum(x.stat().st_size for x in pathlib.Path(sys.argv[3]).glob('*') if x.is_file())))
PY
test ! -e "$OUT/models"
du -sh "$OUT"
