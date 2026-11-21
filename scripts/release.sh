#!/bin/zsh
# A public release in one step: release configuration, nothing personal bundled, Developer ID signature, hardened
# runtime, Apple's notary check, stapled ticket and a Gatekeeper (spctl) assessment. See docs/RELEASING.md.
#   NOTARY_PROFILE=hmunmawi-notary scripts/release.sh
#   NOTARY_ASC_CONFIG=~/path/config.toml scripts/release.sh
set -euo pipefail
root=${0:A:h:h}
# Every release has its user-facing notes (Today's What's new card and the update window) before anything is built.
"$root/scripts/release-notes.py" html "$(plutil -extract CFBundleShortVersionString raw "$root/Resources/Info.plist")" >/dev/null \
  || { echo "release: stopped, add this version's notes to Resources/WhatsNew.json first" >&2; exit 1; }
HM_FLAVOR=public SIGN_MODE=developer-id NOTARIZE=${NOTARIZE:-1} OUT_APP="${OUT_APP:-$root/build/release/Hmunmawi.app}" \
  "$root/scripts/make-app.sh" release

app="${OUT_APP:-$root/build/release/Hmunmawi.app}"
# Nothing from this Mac's home folder may ship inside the app (build paths, user names).
if grep -rlaF "$HOME/" "$app" >/dev/null 2>&1; then
  echo "release: stopped, the app contains paths from $HOME:" >&2; grep -rlaF "$HOME/" "$app" >&2; exit 1
fi
# Updates must keep every macOS permission and Keychain key: the signing designated requirement must equal the previous release's.
"$root/scripts/check-designated-requirement.sh" "$app" || { echo "release: stopped, the signature would make every user re-grant permissions (see docs/RELEASING.md)" >&2; exit 1; }
[[ "${NOTARIZE:-1}" == 1 ]] || { echo "release: the update feed needs the notarized zip; run with NOTARIZE=1" >&2; exit 1; }

# The Sparkle update feed for this version: appcast.xml signed with the EdDSA key file SPARKLE_KEY_FILE (default ~/.config/hmunmawi/sparkle_ed_private.key, chmod 600; exported once from the Keychain account
# "hmunmawi"), pointing at the zip on this version's GitHub release. Upload both files to release v<version>.
version=$(plutil -extract CFBundleShortVersionString raw "${OUT_APP:-$root/build/release/Hmunmawi.app}/Contents/Info.plist")
feed="$root/build/feed"
rm -rf "$feed"; mkdir -p "$feed"
cp "$root/build/Hmunmawi-$version.zip" "$feed/"
# Notes shown in the update window: this version and the four before it (one feed item, so someone skipping updates
# still reads what changed), embedded in the item's <description> by generate_appcast (same base name as the zip).
"$root/scripts/release-notes.py" html "$version" > "$feed/Hmunmawi-$version.html"
"$root/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" --ed-key-file "${SPARKLE_KEY_FILE:-$HOME/.config/hmunmawi/sparkle_ed_private.key}" \
  --download-url-prefix "https://github.com/priyevsingh/hmunmawi/releases/download/v$version/" \
  --embed-release-notes --link "https://github.com/priyevsingh/hmunmawi" "$feed"
"$root/scripts/release-notes.py" check "$feed/appcast.xml" "$version" || { echo "release: stopped, the update feed has no release notes" >&2; exit 1; }
echo "release: upload $feed/Hmunmawi-$version.zip and $feed/appcast.xml to GitHub release v$version"
