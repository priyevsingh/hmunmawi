# Releasing Hmunmawi

A public build must open on any Mac without a warning. That needs Apple's **Developer ID Application** certificate,
the hardened runtime, Apple's notary check and a stapled ticket. `scripts/release.sh` does all of it.

## One-time setup (the account holder)

1. **Developer ID Application certificate.** Xcode → Settings → Accounts → your team → *Manage Certificates…* →
   **+** → *Developer ID Application*. (Only the Account Holder, or an Admin allowed by them, can create one.) It goes
   into your login keychain; `security find-identity -v -p codesigning` then lists it.
2. **Notary credentials**, one of:
   - an App Store Connect **team** API key with the *Developer* role or higher:
     `NOTARY_KEY=~/path/AuthKey_ABC.p8 NOTARY_KEY_ID=ABC NOTARY_ISSUER=<issuer uuid>`, or `NOTARY_ASC_CONFIG=<config.toml>`
     with `issuer_id`, `key_id` and `private_key_path`;
   - or a saved profile: `xcrun notarytool store-credentials hmunmawi-notary` (then `NOTARY_PROFILE=hmunmawi-notary`).

## Each release

```sh
# bump CFBundleShortVersionString / CFBundleVersion in Resources/Info.plist, update CHANGELOG.md, then:
NOTARY_PROFILE=hmunmawi-notary scripts/release.sh
```

It builds the `release` configuration as a **public** flavour (no owner extras, no Keychain-prompt watcher),
signs every helper and the app with the Developer ID certificate, hardened runtime and secure timestamp, sends the
zip to Apple (`notarytool submit --wait`), staples the ticket, validates it, runs `spctl --assess` and leaves
`build/Hmunmawi-<version>.zip` ready to upload.

If no Developer ID certificate exists the script stops (exit 3) and says which step above is missing. It never makes
a certificate itself.

## Owner builds

Your own Mac's builds (`scripts/make-app.sh`) keep the Apple Development signature so saved Keychain keys keep working
across rebuilds, and, with the git-ignored marker `scripts/.owner-build`, include the owner-only Keychain-prompt
watcher. Owner extras in the app itself come from `owner.json` in the app's data folder (see `OwnerConfig`).

## Keychain names after a bundle id change

Saved keys live under the Keychain service `io.github.priyevsingh.Hmunmawi.keys.v2`, trusted by the app's designated
requirement (bundle id + certificate). A Developer ID build has a different certificate, so it cannot read items
saved by a development build without a prompt: a first public build starts with empty keys, which is right for new
users. Never rename the service or bundle id for an existing install without adding the old name to
`LegacySecretMigrator.legacyServices`.

## Testing a fresh install

`scripts/fresh-copy.sh build/Hmunmawi.app --reset --launch` runs a sealed-off copy (own bundle id, own data folder,
keys in memory only). `scripts/launch_smoke.sh` does the same for a 60-second crash check. Neither touches your real
app, Keychain, preferences, database or live stream.

## Signing and saved keys

- Saved keys are Keychain items whose access list trusts the app's **designated requirement**: its bundle id,
  Apple's anchor and the leaf certificate's name. Any build signed with the same certificate name reads them with no
  prompt; a renewed certificate keeps the name, so it keeps working. Ad-hoc signing or a different certificate does
  not.
- `scripts/make-app.sh` signs with `SIGN_ID`, else the identity pinned in `scripts/.sign-id` (git-ignored), else
  your only Apple Development certificate. It stops if the pinned identity isn't in the keychain, warns loudly on
  ad-hoc, and prints the certificate name it used. Never sign "just once" with another certificate: keys saved by
  that build are unreadable to normal builds.
- Check keys with `Hmunmawi --verify-secrets` (ok/fail only, never values) and copy them forward after a
  certificate change with `--rebind-secrets`.
- Don't change `KeychainSecretStore.service`. If you ever must, add the old name to
  `LegacySecretMigrator.legacyServices` so the next launch copies keys forward. (The data protection keychain, which
  needs no access list, requires a provisioning profile; see SECURITY.md "Keychain: why there is never a password
  box".)

## Owner builds

`make-app.sh` builds the *owner* flavour (adds a Keychain-prompt watcher for the maintainer's own Mac) only when
the git-ignored file `scripts/.owner-build` exists. `HM_FLAVOR=public`, and `scripts/release.sh` always, leave it
out, so public releases never contain it.

## Thanking new Wall of Apps entries

For the release notes, print a welcome line for every app that joined since the last release:

```sh
python3 scripts/wall-of-apps.py --since 2026-11-14   # the previous release's date
```

## Repository settings

`scripts/github-settings.sh` applies the repository's GitHub settings with the `gh` CLI: squash merges only, merged
branches deleted, sign-off required on web edits, only GitHub's own Actions with a read-only token, Dependabot alerts
and security updates, and, for a public repository, approval before outside contributors' workflows run, secret
scanning with push protection, private vulnerability reporting, CodeQL code scanning, and rulesets that protect
`main` (no force pushes, no deletion, no bypass for anyone) and the `v*` release
tags (no moving or deleting; only the maintainer can bypass, to publish releases). `main` has no "require a pull request" rule on purpose: the Wall of Apps workflow commits its rebuilt mosaic straight to `main`, and GitHub lets the Actions app bypass rules only on organization repositories. Outside contributors cannot push at all; they fork and open a pull request. Run it after creating the repository and again after
making it public; it says which settings it applied and which aren't available yet.
