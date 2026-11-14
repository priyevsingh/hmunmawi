#!/bin/zsh
# Makes a sealed-off copy of a built Hmunmawi for first-run testing, and optionally launches it.
#   scripts/fresh-copy.sh [built.app] [--launch] [--reset] [--fixture nohub] [--dark|--light]
# The copy has its own bundle id (io.github.priyevsingh.Hmunmawi.freshtest), so it never hands over to, or is
# mistaken for, your real Hmunmawi; it runs with HMUNMAWI_PROFILE=fresh (keys only in memory, its own data folder)
# and CFFIXED_USER_HOME=/tmp/hmfresh/home (its own settings, Library and preferences). Nothing it does touches your
# Keychain, defaults, database or live stream. It is never signed with your certificate (ad-hoc only).
set -euo pipefail
root=${0:A:h:h}
src="$root/build/Hmunmawi.app"
launch=0; reset=0; fixture=""; appearance=""
while (( $# )); do
  case "$1" in
    --launch) launch=1 ;;
    --dark) appearance=dark ;;
    --light) appearance=light ;;
    --reset) reset=1 ;;
    --fixture) shift; fixture="$1" ;;
    *.app) src="$1" ;;
    *) echo "fresh-copy: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
base=${HM_FRESH_DIR:-/tmp/hmfresh}
app="$base/HmunmawiFresh.app"
home="$base/home"
bid=io.github.priyevsingh.Hmunmawi.freshtest
[[ -d "$src" ]] || { echo "fresh-copy: no app at $src (run scripts/make-app.sh first)" >&2; exit 1; }
# Stop only an earlier fresh copy (matched by its own path), never the real app.
# Its add-ons run from its own home, so they are matched by that path too.
for pid in $(pgrep -f "$app/Contents/MacOS/Hmunmawi" || true) $(pgrep -f "$home/Library/" || true); do kill -TERM "$pid" 2>/dev/null || true; done
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -f "$app/Contents/MacOS/Hmunmawi" >/dev/null || pgrep -f "$home/Library/" >/dev/null || break
  sleep 0.5
done
if (( reset )); then
  # Add-ons run from read-only locked copies, so make them writable first.
  for _ in 1 2 3; do chmod -R u+w "$home" 2>/dev/null || true; rm -rf "$home" 2>/dev/null && break; sleep 1; done
  [[ -e "$home" ]] && { echo "fresh-copy: couldn't clear $home" >&2; exit 1; }
  # macOS keeps preferences per bundle id in the real home (cfprefsd ignores CFFIXED_USER_HOME): clear the copy's own.
  pkill -f "HmunmawiFresh.app/Contents/MacOS" 2>/dev/null || true
  defaults delete "$bid" >/dev/null 2>&1 || true
fi
mkdir -p "$home/Library/Application Support" "$home/Library/Preferences"
rm -rf "$app"; mkdir -p "$base"
ditto "$src" "$app"
# No login agent, no Keychain watcher in a test copy.
rm -rf "$app/Contents/Library/LaunchAgents" "$app/Contents/Helpers/keychain-prompt-watch.sh"
plutil -replace CFBundleIdentifier -string "$bid" "$app/Contents/Info.plist"
plutil -replace CFBundleName -string "HmunmawiFresh" "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app" >/dev/null 2>&1
echo "fresh-copy: $app ($bid, home $home)"
if (( launch )); then
  look=(); [[ -n "$appearance" ]] && look=(-HMAppearance "$appearance")
  env HMUNMAWI_PROFILE=fresh HMUNMAWI_ALLOW_SECOND_INSTANCE=1 CFFIXED_USER_HOME="$home" HOME="$home" ${fixture:+HMUNMAWI_FIXTURE=$fixture} \
    "$app/Contents/MacOS/Hmunmawi" "${look[@]}" >"$base/fresh.log" 2>&1 &
  echo "fresh-copy: launched pid $!"
fi
