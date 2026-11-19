#!/bin/bash
# publish-release.sh <version> — push main, wait for CI to pass on that commit, then tag and publish.
# Run after scripts/release.sh has built build/Hmunmawi-<version>.zip (and build/feed/appcast.xml if present).
# Nothing is tagged or published unless the CI workflow on the pushed commit succeeds.
set -euo pipefail
VERSION="${1:?usage: scripts/publish-release.sh <version>}"
cd "$(dirname "$0")/.."
ZIP="build/Hmunmawi-$VERSION.zip"
[[ -f "$ZIP" ]] || { echo "Missing $ZIP: run scripts/release.sh first" >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree not clean" >&2; exit 2; }
[[ "$(git branch --show-current)" == main ]] || { echo "Not on main" >&2; exit 2; }
NOTES="$(awk -v v="$VERSION" 'index($0,"## "v)==1{f=1;next} f&&/^## /{exit} f' CHANGELOG.md)"
[[ -n "${NOTES//[[:space:]]/}" ]] || { echo "No CHANGELOG.md section for $VERSION" >&2; exit 2; }

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
