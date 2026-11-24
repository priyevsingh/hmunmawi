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
  # Escape the email so a '+' in a GitHub noreply address is not treated as a regex quantifier.
  if ! git log -1 --format='%B' "$c" | EMAIL="$email" python3 -c '
import os, re, sys
email = os.environ["EMAIL"]
body = sys.stdin.read()
sys.exit(0 if re.search(r"(?im)^Signed-off-by: .+ <" + re.escape(email) + r">$", body) else 1)
'; then
    echo "::error::Commit $(git log -1 --format='%h %s' "$c") has no 'Signed-off-by:' line for $email. Use: git commit -s --amend"
    bad=1
  fi
done
exit "$bad"
