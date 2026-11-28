#!/usr/bin/env bash
# Prune only exact merged PR heads, plus two explicitly retired old heads.
# Never delete main, protected branches, branches in open PRs, or changed heads.
set -euo pipefail
repo="${GITHUB_REPOSITORY:?}"
sha="${GITHUB_SHA:?}"
: "${GH_TOKEN:?}"
current_main() { [[ "$(gh api "repos/$repo/git/ref/heads/main" --jq '.object.sha')" == "$sha" ]]; }
current_main || exit 0
merged="$(gh api --paginate "repos/$repo/pulls?state=closed&per_page=100" --jq ".[] | select(.merged_at != null and .base.ref == \"main\" and .head.repo.full_name == \"$repo\") | [.head.ref,.head.sha] | @tsv")"
retired=$'fix/wifi-adb-readiness\t37eb8a701663bb24e2adc1055abb9b6624ec6bdc\nmaintenance/prune-legacy-release-assets-20261125\t6456fff462fc53bc3c314e5842f54e5918c24680'
branches="$(gh api --paginate "repos/$repo/branches?per_page=100" --jq '.[] | select(.protected == false) | [.name,.commit.sha] | @tsv')"
while IFS=$'\t' read -r branch head; do
  [[ -n "$branch" && -n "$head" && "$branch" != main ]] || continue
  printf '%s\n%s\n' "$merged" "$retired" | grep -Fxq "$branch"$'\t'"$head" || continue
  current_main || exit 0
  open="$(gh api --paginate "repos/$repo/pulls?state=open&per_page=100" --jq ".[] | select(.head.repo.full_name == \"$repo\" or .base.repo.full_name == \"$repo\") | .head.ref, .base.ref")"
  if printf '%s\n' "$open" | grep -Fxq "$branch"; then continue; fi
  echo "Pruning retired branch: $branch"
  git push --force-with-lease="refs/heads/$branch:$head" origin ":refs/heads/$branch"
done <<< "$branches"
