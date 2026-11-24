#!/bin/bash
# Check every non-merge commit in BASE..HEAD has a Signed-off-by line for the author email.
# Not needed for Dependabot / GitHub bots, or a pull request that only adds a Wall of Apps entry.
# Usage: scripts/check-signoffs.sh <base-sha> <head-sha>
set -euo pipefail
BASE="${1:?usage: scripts/check-signoffs.sh <base-sha> <head-sha>}"
HEAD="${2:?usage: scripts/check-signoffs.sh <base-sha> <head-sha>}"

files=$(git diff --name-only "$BASE...$HEAD")
if [ "$files" = "docs/wall-of-apps.json" ]; then
  echo "Wall of Apps entry only: no sign-off needed."
  exit 0
fi

bad=0
for c in $(git rev-list --no-merges "$BASE..$HEAD"); do
  email=$(git log -1 --format='%ae' "$c")
  case "$email" in *"[bot]@users.noreply.github.com") continue;; esac
  if ! git log -1 --format='%B' "$c" | grep -qiE "^Signed-off-by: .+ <${email}>$"; then
    echo "::error::Commit $(git log -1 --format='%h %s' "$c") has no 'Signed-off-by:' line for $email. Use: git commit -s --amend"
    bad=1
  fi
done
exit "$bad"
