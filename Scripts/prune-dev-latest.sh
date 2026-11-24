#!/usr/bin/env bash
# Remove old assets only from the rolling dev-latest release.
# Keep Mac v0.4.26 and Android v0.3.11 as rollback during real-call validation.
set -euo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY missing}"
test -n "${GH_TOKEN:-}" || { echo "GH_TOKEN missing"; exit 1; }
main_sha="$(gh api "repos/$repo/git/ref/heads/main" --jq '.object.sha')"
if [[ "$main_sha" != "${GITHUB_SHA:-}" ]]; then
  echo "Skip cleanup: another commit is already on main."
  exit 0
fi
release_id="$(gh api "repos/$repo/releases/tags/dev-latest" --jq '.id')"
test -n "$release_id"
# All filenames here contain no spaces.
assets="$(gh api --paginate "repos/$repo/releases/$release_id/assets?per_page=100" \
  --jq '.[] | [.id, .name] | join(" ")')"
names="$(printf '%s\n' "$assets" | cut -d ' ' -f2)"
for required in \
  SIM-AI-Assistant-v0.4.30-macos-arm64.zip \
  SIM-AI-Assistant-v0.4.30-macos-arm64.zip.sha256 \
  SIMAI-Companion-v0.3.13-debug.apk \
  SIMAI-Companion-v0.3.13-debug.apk.sha256 \
  SIMAI-Audio-Probe.jar \
  SIMAI-Android-Signing.txt; do
  printf '%s\n' "$names" | grep -Fxq "$required" || {
    echo "::error::Refusing cleanup: required asset missing: $required"
    exit 1
  }
done

deleted=0
kept=0
while read -r asset_id asset_name; do
  [[ -n "$asset_id" && -n "$asset_name" ]] || continue
  case "$asset_name" in
    SIM-AI-Assistant-v0.4.30-macos-arm64.zip|\
    SIM-AI-Assistant-v0.4.30-macos-arm64.zip.sha256|\
    SIM-AI-Assistant-v0.4.29-macos-arm64.zip|\
    SIM-AI-Assistant-v0.4.29-macos-arm64.zip.sha256|\
    SIMAI-Companion-v0.3.13-debug.apk|\
    SIMAI-Companion-v0.3.13-debug.apk.sha256|\
    SIM-AI-Assistant-v0.4.28-macos-arm64.zip|\
    SIM-AI-Assistant-v0.4.28-macos-arm64.zip.sha256|\
    SIM-AI-Assistant-v0.4.27-macos-arm64.zip|\
    SIM-AI-Assistant-v0.4.27-macos-arm64.zip.sha256|\
    SIMAI-Companion-v0.3.12-debug.apk|\
    SIMAI-Companion-v0.3.12-debug.apk.sha256|\
    SIM-AI-Assistant-v0.4.26-macos-arm64.zip|\
    SIM-AI-Assistant-v0.4.26-macos-arm64.zip.sha256|\
    SIMAI-Companion-v0.3.11-debug.apk|\
    SIMAI-Companion-v0.3.11-debug.apk.sha256|\
    SIM-AI-Assistant-v0.4.25-macos-arm64.zip|\
    SIM-AI-Assistant-v0.4.25-macos-arm64.zip.sha256|\
    SIM-AI-Assistant-v0.4.23-macos-arm64.zip|\
    SIM-AI-Assistant-v0.4.23-macos-arm64.zip.sha256|\
    SIMAI-Companion-v0.3.8-debug.apk|\
    SIMAI-Companion-v0.3.8-debug.apk.sha256|\
    SIMAI-Companion-v0.3.10-debug.apk|\
    SIMAI-Companion-v0.3.10-debug.apk.sha256|\
    SIMAI-Audio-Probe.jar|\
    SIMAI-Android-Signing.txt)
      kept=$((kept + 1))
      ;;
    *)
      echo "Deleting outdated attachment: $asset_name"
      gh api --method DELETE "repos/$repo/releases/assets/$asset_id"
      deleted=$((deleted + 1))
      ;;
  esac
done <<< "$assets"
echo "dev-latest cleanup: deleted=$deleted, kept=$kept"
