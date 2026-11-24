#!/bin/bash
# merge-pr.sh <pr-number>
# The pre-merge helper: every commit must be signed off, every required check must be green, then squash-merge.
# Required checks: App, Worker, Sign-off. CodeQL is not required (it runs separately and slowly).
#   scripts/merge-pr.sh 8
set -euo pipefail
cd "$(dirname "$0")/.."
PR="${1:?usage: scripts/merge-pr.sh <pr-number>}"

meta=$(gh pr view "$PR" --json state,title,url,baseRefName,headRefOid,baseRefOid)
echo "$meta"
eval "$(python3 -c '
import json,sys
d=json.load(sys.stdin)
print("pr_state="+d["state"])
print("pr_base_branch="+d["baseRefName"])
print("pr_base="+d["baseRefOid"])
print("pr_head="+d["headRefOid"])
' <<<"$meta")"

if [ "$pr_state" != "OPEN" ]; then
  echo "merge-pr: pull request #$PR is not open" >&2
  exit 2
fi
if [ "$pr_base_branch" != "main" ]; then
  echo "merge-pr: only merges into main" >&2
  exit 2
fi

git fetch -q origin "$pr_base" "$pr_head"
scripts/check-signoffs.sh "$pr_base" "$pr_head"

required='App (swift build and test)
Live-sales worker (Node tests)
Every commit is signed off'

echo "Waiting for required checks on #$PR..."
while :; do
  json=$(gh pr checks "$PR" --json name,state,bucket 2>/dev/null || echo '[]')
  result=$(REQUIRED_LIST="$required" CHECKS_JSON="$json" python3 - <<'PY'
import json, os
checks = json.loads(os.environ.get("CHECKS_JSON") or "[]")
required = [l for l in os.environ["REQUIRED_LIST"].splitlines() if l]
by = {c["name"]: c for c in checks}
failed, pending = [], []
for n in required:
    c = by.get(n)
    if c is None:
        pending.append(n)
        continue
    bucket, state = c.get("bucket"), c.get("state")
    if bucket == "fail" or state in ("FAILURE", "ERROR", "CANCELLED"):
        failed.append(n)
    elif bucket != "pass" and state not in ("SUCCESS", "SKIPPED"):
        pending.append(n)
if failed:
    print("failed:" + ",".join(failed))
elif pending:
    print("pending:" + ",".join(pending))
else:
    print("green")
PY
)
  echo "  $result"
  case "$result" in
    green) break ;;
    failed:*)
      echo "merge-pr: a required check failed" >&2
      gh pr checks "$PR" || true
      exit 3
      ;;
    pending:*) sleep 15 ;;
    *) echo "merge-pr: unexpected check status: $result" >&2; exit 3 ;;
  esac
done

echo "Required checks are green. Squash-merging #$PR..."
gh pr merge "$PR" --squash --delete-branch=false
echo "Merged #$PR."
