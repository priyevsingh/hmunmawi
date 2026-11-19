#!/bin/bash
# check-designated-requirement.sh <new> [<previous>]
# Fails (exit 1) unless the new build's code-signing designated requirement is identical to the previous release's.
# macOS ties every permission grant (Full Disk Access, Files & Folders, Calendars, Accessibility, Automation) and every
# Keychain "Always Allow" to that requirement, so a difference means every user is asked again after updating.
#   <new>       a .app folder, a .zip containing Hmunmawi.app, or a .txt file holding the "designated => ..." text
#   <previous>  the same three forms; omitted: the newest GitHub release other than the new version's (downloaded with gh,
#               into a temporary folder that is removed afterwards)
# Exit codes: 0 same, 1 different or unreadable, 2 usage / previous release not found.
set -euo pipefail

new="${1:?usage: scripts/check-designated-requirement.sh <new .app|.zip|.txt> [<previous .app|.zip|.txt>]}"
prev="${2:-}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/hm-dr.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Prints the designated requirement of an app, a zip holding one, or a text file that already has it.
requirement() {
  local src="$1" label="$2" app="$1" dir
  if [[ -f "$src" && "$src" == *.txt ]]; then
    sed -n 's/^designated => //p' "$src" | head -1
    return
  fi
  if [[ -f "$src" && "$src" == *.zip ]]; then
    dir="$tmp/$label"; mkdir -p "$dir"
    ditto -x -k "$src" "$dir"
    app="$dir/Hmunmawi.app"
  fi
  [[ -d "$app" ]] || { echo "check-designated-requirement: no app at $src" >&2; return 1; }
  codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p' | head -1
}

if [[ -z "$prev" ]]; then
  version=""
  if [[ -d "$new" ]]; then version="$(plutil -extract CFBundleShortVersionString raw "$new/Contents/Info.plist" 2>/dev/null || true)"
  elif [[ "$new" == *.zip ]]; then
    mkdir -p "$tmp/ver"; ditto -x -k "$new" "$tmp/ver"
    version="$(plutil -extract CFBundleShortVersionString raw "$tmp/ver/Hmunmawi.app/Contents/Info.plist" 2>/dev/null || true)"
  fi
  tag="$(gh release list --limit 20 --json tagName,isDraft,isPrerelease -q '[.[] | select(.isDraft|not)] | map(.tagName) | .[]' 2>/dev/null | grep -vx "v$version" | head -1 || true)"
  [[ -n "$tag" ]] || { echo "check-designated-requirement: no previous GitHub release found to compare with" >&2; exit 2; }
  mkdir -p "$tmp/dl"
  gh release download "$tag" --pattern 'Hmunmawi-*.zip' --dir "$tmp/dl" >/dev/null 2>&1 || { echo "check-designated-requirement: could not download the $tag zip" >&2; exit 2; }
  prev="$(ls "$tmp"/dl/Hmunmawi-*.zip | head -1)"
  prev_name="release $tag"
else
  prev_name="$prev"
fi

new_dr="$(requirement "$new" new)" || exit 1
prev_dr="$(requirement "$prev" prev)" || exit 1
[[ -n "$new_dr" ]] || { echo "check-designated-requirement: the new build has no designated requirement (unsigned?)" >&2; exit 1; }
[[ -n "$prev_dr" ]] || { echo "check-designated-requirement: the previous build has no designated requirement" >&2; exit 1; }

if [[ "$new_dr" == "$prev_dr" ]]; then
  echo "designated requirement: same as $prev_name (updates keep permissions and keys)"
  exit 0
fi
{
  echo "designated requirement: DIFFERENT from $prev_name. Updating would re-ask every macOS permission and Keychain key."
  echo "  previous: $prev_dr"
  echo "  new:      $new_dr"
} >&2
exit 1
