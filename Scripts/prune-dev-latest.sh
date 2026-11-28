#!/usr/bin/env bash
# Publish one rolling release. Verify current files before removing old packages.
set -euo pipefail
repo="${GITHUB_REPOSITORY:?}"
sha="${GITHUB_SHA:?}"
: "${GH_TOKEN:?}" "${MAC_VERSION:?}" "${ANDROID_VERSION:?}" "${MAC_PACKAGE:?}" "${ANDROID_PACKAGE:?}"
[[ "$MAC_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$ANDROID_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$MAC_PACKAGE" == "SIM-AI-Assistant-v$MAC_VERSION-macos-arm64.zip" ]]
[[ "$ANDROID_PACKAGE" == "SIMAI-Companion-v$ANDROID_VERSION-debug.apk" ]]
current_main() { [[ "$(gh api "repos/$repo/git/ref/heads/main" --jq '.object.sha')" == "$sha" ]]; }
current_main || { echo "Skip stale build"; exit 0; }
files=("$MAC_PACKAGE" "$MAC_PACKAGE.sha256" "$ANDROID_PACKAGE" "$ANDROID_PACKAGE.sha256" "SIMAI-Audio-Probe.jar" "SIMAI-Android-Signing.txt")
upload=()
for name in "${files[@]}"; do
  test -s "dist/$name"
  upload+=("dist/$name")
done
notes="Mac v$MAC_VERSION · Android v${ANDROID_VERSION}。支持 USB ADB 与 Shizuku Wi-Fi 两种连接方式。Apple Silicon 测试包，未经 Apple Developer ID 签名与公证。"
if ! gh release view dev-latest >/dev/null 2>&1; then
  gh release create dev-latest --target "$sha" --title "SIM AI Assistant v$MAC_VERSION" --prerelease --notes "$notes"
fi
gh release upload dev-latest "${upload[@]}" --clobber
release_id="$(gh api "repos/$repo/releases/tags/dev-latest" --jq '.id')"
assets="$(gh api --paginate "repos/$repo/releases/$release_id/assets?per_page=100" --jq '.[] | [.id,.name,.size,.state] | @tsv')"
for name in "${files[@]}"; do
  size="$(wc -c < "dist/$name" | tr -d '[:space:]')"
  if ! printf '%s\n' "$assets" | awk -F '\t' -v n="$name" -v s="$size" '$2==n && $3==s && $4=="uploaded" { found=1 } END { exit !found }'; then
    echo "::error::Latest upload missing or invalid: $name"; exit 1
  fi
done
current_main || { echo "Skip stale cleanup"; exit 0; }
old_tag="$(git ls-remote --refs origin refs/tags/dev-latest | awk '{print $1}')"
if [[ "$old_tag" != "$sha" ]]; then
  test -n "$old_tag"
  git push --force-with-lease="refs/tags/dev-latest:$old_tag" origin "$sha:refs/tags/dev-latest"
fi
gh release edit dev-latest --title "SIM AI Assistant v$MAC_VERSION" --notes "$notes" --prerelease
while IFS=$'\t' read -r id name size state; do
  [[ -n "$id" && -n "$name" ]] || continue
  keep=false
  for expected in "${files[@]}"; do
    if [[ "$name" == "$expected" ]]; then keep=true; break; fi
  done
  if [[ "$keep" == false ]]; then
    current_main || { echo "Skip stale cleanup"; exit 0; }
    echo "Removing obsolete asset: $name"
    gh api --method DELETE "repos/$repo/releases/assets/$id"
  fi
done <<< "$assets"
actual="$(gh api --paginate "repos/$repo/releases/$release_id/assets?per_page=100" --jq '.[].name' | sort)"
expected="$(printf '%s\n' "${files[@]}" | sort)"
[[ "$actual" == "$expected" ]] || { echo "::error::Unexpected remaining release assets"; exit 1; }
echo "Latest release verified: Mac $MAC_VERSION / Android $ANDROID_VERSION"
