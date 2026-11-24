#!/bin/bash
# publish-release.sh <version> — wait for CI on main, then tag and publish.
# Order: merge the release change with scripts/merge-pr.sh (sign-off + required checks green),
# then scripts/release.sh, then this script. This script does not add commits to main
# (main only moves through squash-merged pull requests).
# Nothing is tagged or published unless the CI workflow on origin/main succeeds.
set -euo pipefail
VERSION="${1:?usage: scripts/publish-release.sh <version>}"
cd "$(dirname "$0")/.."
ZIP="build/Hmunmawi-$VERSION.zip"
[[ -f "$ZIP" ]] || { echo "Missing $ZIP: run scripts/release.sh first" >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree not clean" >&2; exit 2; }
[[ "$(git branch --show-current)" == main ]] || { echo "Not on main" >&2; exit 2; }
git fetch -q origin main
# Refuse to push new commits: main is updated only by merging a pull request.
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "publish-release: local main and origin/main differ. Merge your change with scripts/merge-pr.sh, then pull, then run this again. Do not push commits to main." >&2
  exit 2
fi
NOTES="$(awk -v v="$VERSION" 'index($0,"## "v)==1{f=1;next} f&&/^## /{exit} f' CHANGELOG.md)"
[[ -n "${NOTES//[[:space:]]/}" ]] || { echo "No CHANGELOG.md section for $VERSION" >&2; exit 2; }

# The zip about to be published must be signed with the same designated requirement as the previous release.
scripts/check-designated-requirement.sh "$ZIP" || { echo "Signature differs from the previous release; not publishing" >&2; exit 4; }

git push origin main
SHA="$(git rev-parse HEAD)"
echo "Waiting for CI on $SHA..."
RUN=""
for _ in $(seq 1 60); do
  RUN="$(gh run list --workflow ci.yml --commit "$SHA" --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
  [[ -n "$RUN" ]] && break
  sleep 10
done
[[ -n "$RUN" ]] || { echo "CI run for $SHA never started; not publishing" >&2; exit 3; }
if ! gh run watch "$RUN" --exit-status >/dev/null; then
  echo "CI failed on $SHA (run $RUN); not tagging or publishing" >&2; exit 3
fi
echo "CI passed (run $RUN)."

git tag -a "v$VERSION" -m "Hmunmawi $VERSION" "$SHA"
git push origin "v$VERSION"
ASSETS=("$ZIP")
[[ -f build/feed/appcast.xml ]] && ASSETS+=(build/feed/appcast.xml)
gh release create "v$VERSION" "${ASSETS[@]}" --title "Hmunmawi $VERSION" --notes "$NOTES" --verify-tag
echo "Published v$VERSION. CodeQL runs separately; check: gh run list --workflow codeql"
