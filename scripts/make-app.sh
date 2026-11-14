#!/bin/zsh
# Builds Hmunmawi and its built-in add-ons into build/Hmunmawi.app.
# Usage: scripts/make-app.sh [debug|release]
#
# Two kinds of build:
#   HM_FLAVOR=owner   your own Mac's build (the default when the git-ignored marker scripts/.owner-build exists):
#                     also bundles the Keychain-prompt watcher that texts the owner (see OwnerConfig).
#   HM_FLAVOR=public  what other people download (the default otherwise): nothing personal is bundled.
#
# Two kinds of signature:
#   SIGN_MODE=development (default)  "Apple Development" certificate pinned in scripts/.sign-id or SIGN_ID: your saved
#                                    Keychain keys keep working across rebuilds. Only runs on Macs you registered.
#   SIGN_MODE=developer-id           "Developer ID Application" certificate (SIGN_ID to pick one): hardened runtime,
#                                    secure timestamp, then (NOTARIZE=1, the default for this mode) Apple's notary
#                                    check, stapling and a Gatekeeper assessment, so any Mac opens it.
#     Notary credentials, first found: NOTARY_PROFILE (saved with `xcrun notarytool store-credentials`), or
#     NOTARY_KEY (.p8 path) + NOTARY_KEY_ID + NOTARY_ISSUER, or NOTARY_ASC_CONFIG (a config.toml with
#     issuer_id, key_id and private_key_path; an App Store Connect team key with the Developer role or higher).
#   scripts/release.sh does a public, Developer ID, notarized release build in one step.
set -euo pipefail

config=${1:-debug}
root=${0:A:h:h}
cd "$root"
flavor=${HM_FLAVOR:-$([[ -f "$root/scripts/.owner-build" ]] && echo owner || echo public)}
[[ "$flavor" == owner || "$flavor" == public ]] || { echo "make-app: HM_FLAVOR must be owner or public" >&2; exit 2; }
sign_mode=${SIGN_MODE:-development}

# A Command Line Tools update can leave its default SDK unreadable; fall back to Xcode's SDK so builds keep working.
if ! xcrun --show-sdk-version >/dev/null 2>&1; then
    xsdk="$(xcode-select -p 2>/dev/null)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    [[ -d "$xsdk" ]] || xsdk=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
    export SDKROOT="$xsdk"
    echo "make-app: default SDK unreadable, using $SDKROOT"
fi

# Release builds keep this Mac's folder names out of the binary: source and build paths are written as "." / "/hm".
prefix=()
if [[ "$config" == release ]]; then
  prefix=(-Xswiftc -file-prefix-map -Xswiftc "$root=." -Xswiftc -debug-prefix-map -Xswiftc "$root=." -Xcc "-ffile-prefix-map=$root=." -Xlinker -oso_prefix -Xlinker "$root")
fi
swift build -c "$config" "${prefix[@]}"
bins="$(swift build -c "$config" "${prefix[@]}" --show-bin-path)"
if [[ "$config" == release ]]; then
  # Drop debugging symbols (they name the build folders) from every program that ships.
  for b in "$bins"/*(N); do [[ -f "$b" && -x "$b" ]] && file -b "$b" | grep -q Mach-O && strip -S "$b" 2>/dev/null || true; done
fi
if [[ "$sign_mode" == developer-id ]]; then
    # Public releases: the Developer ID Application certificate (never made here; see docs/RELEASING.md).
    sign_id=${SIGN_ID:-}
    if [[ -z "$sign_id" ]]; then
        ids=("${(@f)$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2 }')}")
        ids=(${ids:#})
        if (( ${#ids[@]} == 0 )); then
            echo "make-app: no \"Developer ID Application\" certificate in this Mac's keychain." >&2
            echo "  Make one once in Xcode → Settings → Accounts → (your team) → Manage Certificates → + → Developer ID Application," >&2
            echo "  then run this again. See docs/RELEASING.md." >&2
            exit 3
        fi
        if (( ${#ids[@]} > 1 )); then
            echo "make-app: several Developer ID Application certificates; pick one with SIGN_ID=\"<name or hash>\":" >&2
            printf '  %s\n' "${ids[@]}" >&2
            exit 1
        fi
        sign_id=${ids[1]}
    elif ! security find-identity -v -p codesigning | grep -Fq -- "$sign_id"; then
        echo "make-app: signing identity $sign_id is not in this Mac's keychain" >&2
        exit 1
    fi
    # Every piece gets the hardened runtime and a secure timestamp (the notary service refuses anything without).
    ts=(--timestamp)
else
# One signing identity, always. macOS ties "Always Allow" for Keychain items to the app's signing identity, and the
# Apple Development identity is the certificate's name; a build signed by a different certificate would be asked about
# its keys again. Order: SIGN_ID, then the pinned hash in scripts/.sign-id (ignored by git), then the only identity found.
# Several identities and nothing pinned: stop and say how to pin one, instead of picking one at random.
pinned=""; [[ -f "$root/scripts/.sign-id" ]] && pinned=$(tr -d '[:space:]' < "$root/scripts/.sign-id")
sign_id=${SIGN_ID:-$pinned}
if [[ -z "$sign_id" ]]; then
    ids=("${(@f)$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2 }')}")
    if (( ${#ids[@]} > 1 )); then
        echo "make-app: ${#ids[@]} Apple Development identities found; pin one (so saved keys keep working):" >&2
        printf '  %s\n' "${ids[@]}" >&2
        echo "  security find-identity -v -p codesigning   # then put the hash in scripts/.sign-id or set SIGN_ID" >&2
        exit 1
    fi
    sign_id=${ids[1]:--}
fi
if [[ "$sign_id" == "-" ]]; then
    # Ad-hoc signatures change on every build, so macOS treats each build as a new app: saved keys stop being readable.
    echo "make-app: WARNING no Apple Development identity; ad-hoc signing means saved Keychain keys won't survive rebuilds" >&2
elif ! security find-identity -v -p codesigning | grep -Fq -- "$sign_id"; then
    echo "make-app: signing identity $sign_id (SIGN_ID or scripts/.sign-id) is not in this Mac's keychain" >&2
    exit 1
fi
ts=()
[[ "$sign_id" != "-" ]] && ts=(--timestamp)
fi
echo "make-app: $flavor build, $sign_mode signature"

app="${OUT_APP:-$root/build/Hmunmawi.app}"
# Keep the bundle folder itself (only its contents are replaced): macOS remembers privacy answers per app, and
# a deleted-and-recreated bundle can make it ask for Documents access again after every build.
rm -rf "$app/Contents"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources/Add-ons"

# SwiftPM stamps the deployment target as the SDK version, which makes macOS fall back to the
# pre-Liquid Glass look. Record the real SDK so the system draws current controls.
vtool -set-build-version macos 26.0 "$(xcrun --show-sdk-version)" -replace -output "$app/Contents/MacOS/Hmunmawi" "$bins/Hmunmawi"
# SwiftPM embeds target resources (e.g. ai_policy.py) in a sibling .bundle next to the binary — copy it into the app.
if [[ -d "$bins/Hmunmawi_HmunmawiApp.bundle" ]]; then
  rm -rf "$app/Contents/MacOS/Hmunmawi_HmunmawiApp.bundle"
  cp -R "$bins/Hmunmawi_HmunmawiApp.bundle" "$app/Contents/MacOS/"
  codesign --force --sign "$sign_id" --options runtime "${ts[@]}" "$app/Contents/MacOS/Hmunmawi_HmunmawiApp.bundle"
fi
# Sparkle (in-app updates): embed the framework next to the app and sign its parts inside out, as Sparkle's docs ask
# for Developer ID apps (the app is not sandboxed, so its XPC services are left out).
mkdir -p "$app/Contents/Frameworks"
sparkle="$bins/Sparkle.framework"
[[ -d "$sparkle" ]] || sparkle="$root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Hmunmawi" 2>/dev/null || true
sp="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "$sign_id" --options runtime "${ts[@]}" "$sp/Autoupdate"
codesign --force --sign "$sign_id" --options runtime "${ts[@]}" "$sp/Updater.app"
codesign --force --sign "$sign_id" --options runtime "${ts[@]}" "$app/Contents/Frameworks/Sparkle.framework"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"   # from scripts/make-icon.swift
cp "$root/Resources/PrivacyInfo.xcprivacy" "$app/Contents/Resources/PrivacyInfo.xcprivacy"   # Apple privacy manifest
# Live sales: the small Cloudflare worker Hmunmawi uploads to your own account when you switch it on.
cp -R "$root/Resources/LiveWorker" "$app/Contents/Resources/LiveWorker"
# Login agent: starts Hmunmawi at login and relaunches it if it ever crashes.
mkdir -p "$app/Contents/Library/LaunchAgents"
cp "$root/Resources/io.github.priyevsingh.Hmunmawi.agent.plist" "$app/Contents/Library/LaunchAgents/"
if [[ "$flavor" == owner ]]; then
  # The owner's Keychain-prompt watcher (texts the owner when a Keychain box waits). Never in a public build.
  app_abs="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
  sed "s|__HM_APP_ROOT__|$app_abs|g" "$root/Resources/io.github.priyevsingh.Hmunmawi.keychain-watch.plist" \
    > "$app/Contents/Library/LaunchAgents/io.github.priyevsingh.Hmunmawi.keychain-watch.plist"
  # The watcher script is the maintainer's own (not in the repo): ~/.config/hmunmawi/keychain-prompt-watch.sh.
  watch_src="${HM_KEYCHAIN_WATCH:-$HOME/.config/hmunmawi/keychain-prompt-watch.sh}"
  [[ -f "$watch_src" ]] || { echo "make-app: owner build needs $watch_src" >&2; exit 1; }
  cp "$watch_src" "$app/Contents/Helpers/keychain-prompt-watch.sh"
  chmod +x "$app/Contents/Helpers/keychain-prompt-watch.sh"
  codesign --force --sign "$sign_id" --options runtime "${ts[@]}" "$app/Contents/Helpers/keychain-prompt-watch.sh"
fi

# GPU shaders (the animated background) compiled into the app's Metal library.
xcrun -sdk macosx metal -c "$root/Resources/Shaders.metal" -o "$root/build/Shaders.air"
xcrun -sdk macosx metallib "$root/build/Shaders.air" -o "$app/Contents/Resources/Hmunmawi.metallib"

# Programs live in Contents/Helpers (where Apple expects helper code); each add-on folder in
# Resources holds its manifest and a link to its program.
for manifest in "$root"/AddOns/*/manifest.json; do
  id=$(plutil -extract id raw "$manifest")
  exe=$(plutil -extract executable raw "$manifest")
  dest="$app/Contents/Resources/Add-ons/$id.hmplugin"
  mkdir -p "$dest"
  cp "$manifest" "$dest/manifest.json"
  cp "$bins/$exe" "$app/Contents/Helpers/$exe"
  codesign --force --sign "$sign_id" --options runtime "${ts[@]}" "$app/Contents/Helpers/$exe"
  ln -s "../../../Helpers/$exe" "$dest/$exe"
done

# The agent helper (command line + MCP): signed with the hardened runtime like every helper.
cp "$bins/hmunmawi-cli" "$app/Contents/Helpers/hm"
codesign --force --sign "$sign_id" --options runtime "${ts[@]}" "$app/Contents/Helpers/hm"

codesign --force --sign "$sign_id" --options runtime "${ts[@]}" --entitlements "$root/Resources/Hmunmawi.entitlements" "$app"
codesign --verify --deep --strict "$app"
# Saved keys follow the certificate's name (the app's designated requirement), not the build: show it so a change is seen.
echo "$app (signed: $sign_id; $(codesign -d -r- "$app" 2>&1 | grep -o 'leaf\[subject.CN\] = "[^"]*"' || echo 'ad-hoc'))"

# Public release: Apple's notary check, stapled ticket, Gatekeeper assessment.
if [[ "$sign_mode" == developer-id && "${NOTARIZE:-1}" == 1 ]]; then
    zip="$root/build/Hmunmawi-notarize.zip"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    creds=()
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        creds=(--keychain-profile "$NOTARY_PROFILE")
    else
        key=${NOTARY_KEY:-}; key_id=${NOTARY_KEY_ID:-}; issuer=${NOTARY_ISSUER:-}
        if [[ -z "$key" && -n "${NOTARY_ASC_CONFIG:-}" && -f "${NOTARY_ASC_CONFIG}" ]]; then
            toml() { sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\(.*\)\"/\1/p" "$NOTARY_ASC_CONFIG" | head -n 1; }
            key=$(toml private_key_path); key_id=$(toml key_id); issuer=$(toml issuer_id)
            key=${key/#\~/$HOME}
        fi
        if [[ -z "$key" || -z "$key_id" || -z "$issuer" || ! -f "$key" ]]; then
            echo "make-app: signed with Developer ID, but no notary credentials (NOTARY_PROFILE, NOTARY_KEY+NOTARY_KEY_ID+NOTARY_ISSUER or NOTARY_ASC_CONFIG)." >&2
            echo "  The app is NOT notarized yet; other Macs will warn before opening it." >&2
            exit 4
        fi
        creds=(--key "$key" --key-id "$key_id" --issuer "$issuer")
    fi
    echo "make-app: sending to Apple's notary service (usually 1-5 minutes)…"
    xcrun notarytool submit "$zip" "${creds[@]}" --wait --timeout 30m
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=4 "$app"
    rm -f "$zip"
    version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
    ditto -c -k --keepParent "$app" "$root/build/Hmunmawi-$version.zip"
    echo "make-app: notarized and stapled: $root/build/Hmunmawi-$version.zip"
fi
