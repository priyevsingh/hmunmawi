# Security

Hmunmawi holds keys to your App Store Connect account and other services, so security reports are taken seriously and handled before anything else.

## Reporting a problem

Please **don't open a public issue**. Report it privately through GitHub: on the repository's **Security** tab, choose **Report a vulnerability**. Include:

- what an attacker could do,
- the steps or code to reproduce it,
- the Hmunmawi version (Settings → About) and your macOS version.

You'll get a reply as soon as the report is read. Once a fix is released you'll be credited in the release notes, unless you'd rather not be.

## What counts

For example:

- a key or token that could leak: into a log, a file, the activity log, a URL, an error message or another add-on,
- an add-on reaching hosts, files or keys it didn't declare and wasn't approved for,
- an agent (through `hm` or the MCP server) doing something that should have waited for your OK,
- a way to change approvals, agent permissions or the activity log without the app noticing,
- the live-sales worker accepting a notification that wasn't signed by Apple.

## How Hmunmawi protects you

- Keys live only in your macOS Keychain. Add-ons never receive them: they write `{{secret:NAME}}` in a request and the app fills it in when it sends the request to a host the add-on declared.
- Add-ons run in a macOS sandbox by default: no network of their own (web calls go through the app, only to declared hosts), no starting other programs, no reading anywhere in your home folder, other users' folders or external disks except their own folder and state, no writing anywhere except their own state folder, and no side doors out (no Apple Events, opening links or apps, clipboard, Keychain service or system web-request service). It is a safety layer, not a guarantee, so install add-ons you trust. If the sandbox can't be applied, the add-on doesn't start.
- An add-on runs only after you approve it, and needs your approval again whenever any file in its folder changes. It runs from a read-only copy that the app checks against your approval right before every start, so a file can't be swapped in between. A link that points outside its folder is refused. It lists the kinds of event it may send (shown when you approve it); anything else is dropped and noted in the activity log, and only the bundled script feed may send any kind. An add-on allowed to send iMessages can send them only to the recipient you set.
- Approvals, agent permissions, routines that run something, your bots' jobs (their whole text and on/off), the heal-script and sandbox settings, and every activity-log entry are signed with a key only the app keeps (in the Keychain), so changes made outside the app don't count. Fix scripts for self-healing are picked in Settings → General (signed at once); one that appears in config.json outside the app is listed there with an Allow button and never runs before it. A changed or removed log entry, or a cut-off end of the log, is reported at the next start. The "done once" marks for these checks live in the Keychain too, not in preferences.
- Publish's optional upload command runs only once you approve its exact text; the approval is signed with the same app key, so editing preferences can't approve a command. It runs as you in the portal folder with a plain environment (no Hmunmawi keys) and is stopped after 2 minutes.
- Text from other people, bots, websites and AI in agent replies is marked as data (`untrusted_text`), never instructions.
- The activity log is hash-chained, so a single entry changed or reordered in the middle shows up; it is not proof against someone who can rewrite the whole database file.
- App Store Connect changes wait for your OK, unless you have switched on "Fix releases in App Store Connect" for an agent (or Steroid mode) in Settings → Rules → Agents. Submitting a version for review always waits, whatever you allow.
- A website redeploy (Vercel) and a Python environment repair always wait for your OK in Log → Waiting (or run from your own tap), whatever an agent is allowed and even in Full Autopilot. The redeploy is refused if your branch moved on since you approved it. Automatic Python repair can only be switched on by you, in the app; agents can't set it, and any agent edit of that routine turns it back to asking. Only folders with a `pyvenv.cfg` count as Python environments, so a folder that merely has a `bin/` (`~/go`, `~/.cargo`) is never touched. A repair renames the broken folder instead of deleting it.
- Once you have made any agent badge, an agent that sends no badge shows as unverified and **always** waits for your OK (also in Full Autopilot), so dropping the badge can't dodge an "ask" rule.
- Agents can run, pause or schedule only your own Mac jobs (names starting with your Mac jobs prefixes, never `com.apple.*`); a routine that starts a Mac job needs the "Run or pause Mac jobs" permission, and only you can change the prefixes.
- Web reads for link checks and outreach checks never call this Mac or your own network, also not through a redirect (each hop is checked), stop at a size limit while reading and give up after 30 seconds.
- The live-sales worker takes notifications only for the bundle ids you listed (no list: nothing is taken) and refuses bodies over 64 KB. Workers report a code version; when the one in your Cloudflare account is older than the app's, Hmunmawi updates it with your saved Cloudflare token (once per version and app build, never in a loop; same address, store and relay key; a token scoped to one account works too), so worker fixes reach existing setups. **Update worker** in Settings → Connections → Live sales does it on demand.
- A key may be tied to certain hosts (`secretHosts` in the manifest): the Vercel token only ever goes to `api.vercel.com` and the optional GitHub token only to `api.github.com`, even though the add-on declares both hosts.
- If the Keychain does not answer, no approval counts until it does: add-ons stay off instead of being waved through.
- Limits, said plainly: the add-on sandbox is a safety layer, not a guarantee (it blocks the network, the home folder and other side doors, but is not a full allow-list). A web address is checked for private and local names, but a public name that resolves to a private address is not caught, and the live-sales worker has no replay window (its writes are idempotent). Anything running as you on this Mac that can change Hmunmawi itself or read its Keychain item can get around these protections. Development builds (`scripts/make-app.sh` default) also accept `--approve-addon` and `--set-secret` on the command line for tests; release builds do not, so use a release build as your everyday app. The environment variables that point at another `owner.json` or key folder (`HMUNMAWI_OWNER_CONFIG`, `HMUNMAWI_TYPED_KEYS`) work only in a test profile; the real app ignores them.

- Release builds (`HM_FLAVOR=public`) contain no Keychain watcher LaunchAgent and no personal paths; owner extras need an `owner.json` the app never writes on its own. Your extras (1.5.0) only name folders, a file and a time zone: a key folder is read only when you press Find my key and never becomes an automatic key source; agents change folders and the Zoho reader only with the Connections permission and can't change anything an owner settings file sets. Tests run in a test profile with keys in memory only, so `swift test` can never read or write your real Keychain.

## How the project is protected

- **Every change is checked before it can merge:** the app is built and its tests run on a GitHub-hosted Mac, the
  live-sales worker's tests run on Linux, and every commit needs a sign-off. Outside contributors can't push to `main`: they open a pull request, which needs
  all checks green and the maintainer's review. Force pushes and deleting `main` or a release tag are blocked for
  everyone, and release tags can't be moved.
- **Outside contributors' code doesn't run unseen:** a first-time contributor's workflow runs wait for the
  maintainer's approval. Workflows get a read-only token by default, may only use GitHub's own actions (pinned to an
  exact version), and can't approve pull requests.
- **Dependencies are watched:** Dependabot alerts and security fixes are on, with weekly update pull requests for the
  GitHub Actions and the worker's test tools that CI tests like any other change. Sparkle is pinned to an exact version and
  updated by hand after reading its release notes; Dependabot alerts still cover it.
- **Secrets stay out:** secret scanning with push protection blocks a pushed key, and CodeQL scans the code. The
  repository holds no secrets at all, and releases are signed and notarized on the maintainer's own Mac, so the
  signing certificate never reaches GitHub.

The settings are kept in `scripts/github-settings.sh`, so they can be checked and re-applied.

## Supported versions

Fixes go into the latest release. Please update before reporting.

## Keychain: why there is never a password box (6 Nov 2026)

Hmunmawi keeps API keys and its trust key in the Mac's Keychain. Findings from Apple's own documentation (TN3137 "On Mac keychain APIs and implementations", the `kSecUseDataProtectionKeychain` page and "Sharing access to keychain items among a collection of apps"), and from tests on this Mac:

- macOS has two keychain implementations. The SecItem API defaults to the older **file-based keychain**, which protects each item with an access control list tied to the code identity of the app that saved it. When a differently signed copy (an ad-hoc build, another certificate, a rebuilt unsigned binary) asks for that item, macOS shows "wants to use your confidential information ... enter the login keychain password". "Always Allow" records that exact identity, so a build whose identity changes is asked again.
- Apple's technote says to default to the **data protection keychain** (no access lists, no password box). On macOS it needs an `application-identifier` or `keychain-access-groups` entitlement that is authorized by an embedded provisioning profile. Tested here: a program signed with an Apple Development certificate and no profile gets error -34018 (errSecMissingEntitlement) when it uses it. So Hmunmawi cannot use it until a build is signed with a provisioning profile.
- Connection approvals are signed against a hash of what the add-on may do (hosts, events, keys it uses), not the add-on's code signature, so rebuilding or re-signing the app does not ask you again when nothing about permissions changed.
- What the app does today: it stays on the file-based keychain under the service name `io.github.priyevsingh.Hmunmawi.keys.v2` (so items saved by an older build with a different certificate are ignored instead of blocking reads), creates and reads only its own items with a stable signing identity (no prompt), and switches macOS keychain dialogs off for the whole process (`SecKeychainSetUserInteractionAllowed(false)`, tested: a read of an item it is not trusted for fails in 0.01 s with no box). It then says in plain words what to do, and on read failure it can re-import from the file path recorded when you used **Find my key** (only the path and field name are stored in `secret-sources.json`, never the secret). `Hmunmawi --rebind-secrets` does that import without opening the window. Saving in Settings replaces an unreadable item when macOS allows deletion (you may see one Allow dialog). Setup and Settings → Permissions have a "Keep your keys safe (Keychain)" check that saves, reads and removes a test item. When the trust key can be read, a copy of it is stored in app preferences as `HMTrustKeyB64` so a new Developer certificate can still verify signed add-on approvals without redoing every connection; the Keychain item is rewritten when macOS allows.
- Keys saved by an older Hmunmawi (10 Nov 2026): at every launch and with `Hmunmawi --rebind-secrets`, any key that exists under the older service name `io.github.priyevsingh.Hmunmawi` but not under `.keys.v2` is copied across (`LegacySecretMigrator`). It never overwrites a current item (even one it can't read), never deletes the old item, never copies the app's own trust state (`hmunmawi/…`), and never shows a password box: an old item saved by a copy signed with a different certificate is reported as "needs one OK" instead. **Find my key** lists such an item as "Keychain · <service>" (value never shown); picking it is the one case where macOS may ask once, because you chose it. `Keychain.neverPrompt()` now switches the box off again every time it is called (before, it only did so once, so a brief allow stayed on).
- Moving between signing identities (20 Nov 2026, 1.1.3): when a key item was saved by a differently signed copy and can't be read or changed without a password box, Hmunmawi saves the key again in a fresh Keychain item of its own (the old one is left alone) from the file path it already knows, and does the same for its trust key and flags. Key files are read in the background after the window is up, once per launch, so a macOS prompt for a protected folder never blocks launch; a refused or slow read marks only that connection as needing attention. A changed signing identity is shown in Settings → Permissions and the activity log, with the permissions to switch on again. Only with owner extras on, a key typed in Settings is also written to a `0600` file in `~/.config/hmunmawi/keys/` (folder `0700`), for the same re-import.
- Releases keep the same signature (1.1.4): `scripts/check-designated-requirement.sh` makes `release.sh` and `publish-release.sh` fail if a build's designated requirement differs from the previous release's, so an update never re-asks macOS permissions or Keychain access.
- Test profile (`HMUNMAWI_PROFILE=<name>` plus a separate bundle identifier): secrets live in memory only, backups are off, the data folder is separate. A test run never touches the real Keychain, iCloud backups or settings.
- Release plan: sign with Developer ID and a provisioning profile that authorizes the app's keychain access group, move items to the data protection keychain (read the old item once, write the new one, delete the old), keep the file-based path only as a fallback for builds without a profile.
