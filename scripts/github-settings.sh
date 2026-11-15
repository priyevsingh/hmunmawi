#!/bin/zsh
# Applies the repository's GitHub settings (security, merge rules, Actions limits) with the gh CLI.
# Run it after creating the repo, and again after making it public (some features only exist for public repos).
#   scripts/github-settings.sh [owner/repo]
set -u
R="${1:-priyevsingh/hmunmawi}"
ok() { echo "✓ $1"; }; skip() { echo "– $1 (not available: $2)"; }
api() { gh api "$@" >/dev/null 2>/tmp/ghs.err; }

# Merging: squash only (one clean commit per change), delete merged branches, sign-off required on web edits.
api -X PATCH "repos/$R" -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true -F allow_update_branch=true -F web_commit_signoff_required=true \
  -F has_wiki=false -F has_issues=true && ok "merge settings" || skip "merge settings" "$(cat /tmp/ghs.err)"

# Actions: only GitHub's own actions, read-only token by default, workflows can't approve pull requests.
api -X PUT "repos/$R/actions/permissions" -F enabled=true -f allowed_actions=selected && \
api -X PUT "repos/$R/actions/permissions/selected-actions" -F github_owned_allowed=true -F verified_allowed=false && \
api -X PUT "repos/$R/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false \
  && ok "actions limited to GitHub's own, read-only" || skip "actions limits" "$(cat /tmp/ghs.err)"
# Outside contributors' workflow runs wait for the maintainer's approval (public repos).
api -X PUT "repos/$R/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors \
  && ok "fork pull requests need approval to run" || skip "fork approval" "public repos only"

# Dependencies: alerts and automatic security fixes.
api -X PUT "repos/$R/vulnerability-alerts" && ok "Dependabot alerts" || skip "Dependabot alerts" "$(cat /tmp/ghs.err)"
api -X PUT "repos/$R/automated-security-fixes" && ok "Dependabot security updates" || skip "Dependabot security updates" "$(cat /tmp/ghs.err)"

# Public-repo security features: secret scanning + push protection, private vulnerability reporting, CodeQL.
api -X PATCH "repos/$R" --input - <<'J' && ok "secret scanning + push protection" || skip "secret scanning" "public repos only"
{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}
J
api -X PUT "repos/$R/private-vulnerability-reporting" && ok "private vulnerability reporting" || skip "private vulnerability reporting" "public repos only"
api -X PATCH "repos/$R/code-scanning/default-setup" -f state=configured -f query_suite=default \
  && ok "CodeQL code scanning (default setup)" || skip "CodeQL" "public repos only"

# Rulesets: main needs a pull request with green checks and the code owner's review; no force pushes or deletion.
# Release tags v* can't be moved or deleted. Repository admins (the maintainer) can bypass, for releases.
upsert_ruleset() {  # name, json
  local id; id=$(gh api "repos/$R/rulesets" -q ".[] | select(.name==\"$1\") | .id" 2>/dev/null | grep -E '^[0-9]+$' | head -1)
  if [ -n "$id" ]; then echo "$2" | api -X PUT "repos/$R/rulesets/$id" --input -; else echo "$2" | api -X POST "repos/$R/rulesets" --input -; fi
}
# main can never be force-pushed or deleted, by anyone (no bypass). Outside contributors cannot push at all: they fork and open
# a pull request, which only the maintainer can merge. A "require pull request" rule is NOT used: the Wall of Apps workflow commits
# its rebuilt mosaic straight to main with GitHub's own token, and GitHub only lets the Actions app bypass rules on organization
# repositories (a personal repo answers 422 "Actor GitHub Actions integration must be part of the ruleset source or owner organization").
upsert_ruleset "Protect main" '{"name":"Protect main","target":"branch","enforcement":"active",
 "bypass_actors":[],
 "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},
 "rules":[{"type":"deletion"},{"type":"non_fast_forward"}]}' \
  && ok "ruleset: protect main" || skip "ruleset main" "$(cat /tmp/ghs.err)"
upsert_ruleset "Protect release tags" '{"name":"Protect release tags","target":"tag","enforcement":"active",
 "bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],
 "conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},
 "rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"update"}]}' \
  && ok "ruleset: protect release tags" || skip "ruleset tags" "$(cat /tmp/ghs.err)"
