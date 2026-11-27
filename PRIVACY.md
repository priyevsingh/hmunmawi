# Privacy

Hmunmawi runs on your Mac and works for you alone. It has **no telemetry, no analytics and no account**, and its author never receives any of your data.

## What stays on your Mac

- **Your data:** a SQLite database in `~/Library/Application Support/Hmunmawi/`, with the numbers your connections fetch, your rules, and the activity log.
- **Your keys:** in the macOS Keychain only. (Only with owner extras on: a key you type in Settings is also kept in a private `0600` file in `~/.config/hmunmawi/keys/` so it can be re-imported after the app's signature changes.)
- **Settings:** the app's preferences and settings file in the same folder.
- **Checks you set up:** `wording-rules.json` (your Words I never use), `link-check-<id>.json` (each link check's dead links and links to check again), `python-locks/` (the package list of each working Python environment your scripts use, for a repair), and your Plans and trials (service, date and note, in the app's preferences).
- **Customer release subscribers:** `~/Library/Application Support/Hmunmawi/release-subscribers.json` keeps your per-app customer email lists and release delivery checkpoints locally in a `0600` file (never synced to GitHub). Individual update emails are sent directly from your configured mailer only after explicit owner approval, and incoming unsubscribe replies and bounces mark subscribers inactive automatically.
- **Backups:** once a day in `~/Library/Application Support/Hmunmawi/Backups/`: a full copy of the database (the last 7 kept, 2 if it grows past 300 MB), the settings file whenever it changed, and small snapshots (the last 30 days plus the first of each month for a year). If iCloud Drive is on, an **encrypted** copy also goes to *iCloud Drive › Hmunmawi Backups*. The key stays in your Keychain, and a recovery code is shown in Settings → Backups.
- **Your published portal (only if you press Publish):** one `index.html` with your numbers, written to `~/Library/Application Support/Hmunmawi/Portal/` or the folder you choose in Settings → Publish. Hmunmawi doesn't upload it; if you set and approve your own upload command, that command (your tool, your login) sends it where you chose. With "Safe to show anyone" on, no money amounts, sales list or problem list are in it. Dated copies of the last 8 days stay in the `earlier` folder next to it. Sample numbers are never published.

- **Apple payouts (only if you press "Fill paid months from App Store Connect" or switch on "Keep them filled"):** the amounts Apple sent to your bank are read from App Store Connect's Payments page in your own signed-in Safari (Apple's API doesn't offer them) and kept in `payouts.json`. Read only; nothing is changed in App Store Connect, and the automatic check only runs when an App Store Connect tab is already open.

## What leaves your Mac, and why

Only these, and each one only for the reason given:

| To | When | What is sent |
|---|---|---|
| Each service you connect (App Store Connect, PostHog, Sentry, Google Search Console, Bing, YouTube, X, Cloudflare, Vercel, RevenueCat, ntfy) | On its regular check, once you've connected and approved it | The requests that service needs, with your key for it. Sentry is strictly **read-only** (never resolves or modifies issues); with `event:read`, it returns your open issues' titles and counts, and **Copy brief for Claude** writes a summary only to your local clipboard |
| GitHub (`api.github.com`) | Only with the Vercel connection and a repository set: every 15 minutes | A request for your production branch's newest commit (with your optional read-only GitHub token for a private repository) |
| Vercel (`api.vercel.com`), a deploy | Only when you approve a Redeploy in Log → Waiting | One request to deploy that commit to production, with your Vercel token |
| Sentry's check-in address (`*.ingest.sentry.io`) | Only if you add a *Mac-alive heartbeat* routine: on its schedule | A check-in with "ok" (or "error" while a watched Mac job fails), the monitor name, its schedule and your time zone, to your own Sentry project's DSN |
| The outside websites linked from your pages, and Apple's public lookup (`itunes.apple.com/lookup`) | Only if you add a *Check links on my site* routine: weekly by default | Your sitemap and pages are read like a browser would; each outside link gets a normal HEAD or GET request (user agent "Hmunmawi link check"); App Store links send only the app id and country to Apple's lookup |
| An outlet's page | Only when you press Check in the outreach editor, or an agent runs `hm outreach-check` | One normal request for the page you entered |
| The AI provider you choose (optional) | When you ask for AI help, or a feature you turned on writes a summary | The numbers and text that summary is about. Nothing is sent when no provider is set |
| Messages (iMessage) | When a rule you made says to text you | A short alert (no passwords or key values) |
| Apple's public App Store lookup (`itunes.apple.com`) | About once a day | Your apps' public App Store IDs, to read release dates and ratings |
| Currency rates (`frankfurter.app` / `frankfurter.dev`, European Central Bank rates) | Once a day, when money is shown in another currency | Nothing about you; only the currencies asked for |
| Hacker News, Bluesky and GitHub public search | When you switch on "mentions" for your apps | Your app names or the repository you entered, to find public posts about them |
| `rdap.org` | When you watch a domain's expiry | The domain name |
| Each service's own website | When its icon is first shown | A normal request for its icon, like a browser tab; cached afterwards |
| Your own Cloudflare account | Only if you switch on live sales or instant App Store Connect updates; then also when a new Hmunmawi version brings worker changes (once per version and app build) or you press Update worker | The small worker(s) that receive Apple's notifications, uploaded to *your* account with the Cloudflare token you saved; the worker's address, store and relay key stay the same on an update |
| Apple's system status page and the Apple Developer news feed | While the app runs (at most every 30 minutes, news every few hours) | Normal page requests; nothing about you |
| Your own websites, and connectivity checks (`apple.com`, `cloudflare.com/cdn-cgi/trace`) | When you add a website to watch, on its schedule | A normal request to the address you entered, to see it is up |
| Apple's public App Store search (`itunes.apple.com/search`) | When you use competitor tracking or the outreach coverage watch | The competitor or outlet names you entered |
| The contact domains you entered for outreach | When the coverage watch runs | A request for `/feed` or `/rss` on that domain, to look for a post about your app |
| Apple's notification history (`api.storekit.itunes.apple.com`) | Only in "Within minutes" live sales mode | A request signed with the In-App Purchase key you gave it |
| xAI, DeepSeek, OpenAI and OpenRouter balance or cost pages | Only if you added those keys | The key, to read your balance or spend |
| GitHub (`github.com`, the update feed) | When Hmunmawi checks for updates (Sparkle) | A normal request for `appcast.xml`, which carries the app's version |
| Apple's public App Store lookup and GitHub, through your own `gh` login | Only when you press "Add my app to the Wall of Apps" and confirm | Your app's public name, App Store link, icon and developer name, as a pull request to `docs/wall-of-apps.json` |
| x.com, through your own Safari login | Only if you switch on *Read via your Safari login* (X numbers): every 6 hours | Opens your own X profile in a background Safari tab, reads the counts X's page already loaded (followers, your posts' views, likes, replies, which post is pinned, your articles' titles and who your replies answered), closes the tab. Nothing is clicked, posted or sent; the result stays in `x-file.json` on your Mac |
| x.com search and your Following page, through your own Safari login | Only for an *X reply ideas* or *X unfollow list* routine set to read via Safari: once a day each | Opens X's search for your topics, or your Following page, in a background Safari tab, reads what the page loaded (posts, or who follows you back), closes the tab. Nothing is clicked or sent. Drafts by Apple's on-device AI stay on your Mac; with your AI key instead, each chosen post's text goes to your AI provider to draft a reply |
| x.com profiles of accounts you follow, through your own Safari login | Only if you add *X unfollows (automatic)* (off by default): up to your daily number, inside your window | Opens one profile per account in a background tab, reads the page, clicks **Following → Unfollow** on that profile only, checks it worked and closes the tab. The list and progress stay on your Mac (Hmunmawi's folder, `x-unfollows/`); nothing goes anywhere else |
| GitHub (`api.github.com` and `raw.githubusercontent.com`, X's public algorithm code) | Only while a *Post drafts* routine is on: at most once a day, and the file only when X's code changed | A normal request for the latest commit of `xai-org/x-algorithm` and one public file; nothing about you |
| GitHub (`raw.githubusercontent.com`, the public Wall of Apps list) | Only if you switch on "Show the community's apps" or added your own app (to offer Share on X): about twice a day | A normal request for the public list; nothing about you |
| Your mail (only if you choose a source under Settings → Connections → Outreach replies) | Every 10 minutes at most (read); outbound only on your Approve click | *Reading:* **Apple Mail**, TLS **IMAP**, or **Zoho Mail** (`zoho-safari`, in a background tab with Safari's existing login) reads senders, subjects and dates across your inbox, and reads the message body (`BODY.PEEK[TEXT]` up to 32 KB, or Zoho `md.do`) **only for messages matching your outreach list** (or to mark incoming unsubscribe/bounce replies inactive for `release-subscribers.json`), leaving unread status untouched. If you enable AI drafting, matched reply snippets are sent to your chosen AI provider to pre-draft your next outreach email locally in Log → Waiting. *Sending:* only when you explicitly approve an `outreach.send` or `release.notify` draft in Log → Waiting / Needs your OK does Hmunmawi send that email over **TLS/STARTTLS SMTP** (port 465 or 587; plaintext port 25 is refused) or **Zoho Mail compose in Safari** |

Nothing else is sent anywhere. Add-ons can only reach the hosts listed in their manifest, which you see before approving them.

## Files Hmunmawi reads outside its own folder

Only with your permission, which you give once during setup (or later in Settings → Permissions). The app re-checks status without presenting a system box, and a job that still needs a grant waits instead of asking mid-run.


- **Find my key** (only when you press it): your Keychain entries whose name mentions the service, `.env` and `config.toml` files in folders you add with "Also look in a folder…", `~/.config` and your home folder, and `AuthKey_*.p8` files in Downloads, Documents, Desktop and iCloud Drive (plus Vercel/GitHub tokens from local Vercel CLI config or `gh` CLI when requested). It does not look in any project folders unless you add them. Values are never shown, only where they were found. When you pick a file, Hmunmawi stores only that file path and field name in `secret-sources.json` (never the secret) so it can re-import after a rebuild.
- **Detect from repo… (Vercel)** (only when you press it): reads `.vercel/project.json` and `.git/config` in the local repository folder you pick to fill Project ID, GitHub repo, and production branch locally without sending any secrets.
- **Saved key files:** files you picked with **Find my key** (path and field name are remembered, never the secret) are read again at launch, in the background and once per launch, to re-import a key after an update. A connection's own sign-in file, such as the YouTube Google sign-in, is read the same way. If macOS refuses a protected folder, that connection is marked as needing attention.
- **Mac jobs:** the list of your own LaunchAgents (`~/Library/LaunchAgents`) and their log files, to show what ran.
- **Check my workspace Python** (only if you add it): the commands of your script routines and LaunchAgents and the first line of the scripts they run, to find the Python environments they use; a working environment's own Python is run once a day as `pip freeze` to save its package list. A **repair** (only on your tap or approval, or with automatic repair you switched on) renames the broken folder to `<name>.broken-<date>` and makes a fresh one in the same place; nothing is deleted.
- **Files you point it to:** offer-code CSVs, a JSON file your bot writes, a folder of App Store Connect reports, a usage folder.
- **Your job switch file** (Settings → Jobs): the JSON file of on/off values in your workspace (or the one you chose) is read every few seconds while that tab is open, and **written** only when you flip a switch there: just that one value changes, the file is replaced atomically, and the change is noted in the activity log. Nothing in it leaves your Mac.
- **Another tool's usage figure:** if you named your bot "Grok" (Automations → Your routines → Set up your bot), Grok Bot's local cache folder under `~/Library/Application Support/Grok Bot/` is read for its weekly usage figure, only to show it.
- **Safari**, only for what you switch on: reading a tracker page you're signed in to (the one address you gave, once), and, with the Zoho Mail reader on (Your extras), the Zoho Mail source (it opens Zoho's list page in a background tab, at most every 10 minutes, reads sender, subject and folder, and reads `md.do` message text **only** for threads matching your outreach list; outbound compose runs only when you approve an `outreach.send` draft). Every Safari job opens its own tab, tags it, and closes it when it ends; jobs take turns on one lock file, and tabs left behind by a killed run are closed at the next run. Your own tabs are never closed; on x.com, Zoho, the Claude Console, Google sign-in and App Store Connect pages a tab's window name is read to find our leftovers.

- **Your extras** (Settings → General, or your workspace's `config/hmunmawi-extras.json`; all off by default): a workspace, key and projects folder that Find my key looks in only when you press it, the AI pause card, the Zoho Mail reader through your Safari login, an X numbers file and a fixed time zone. Nothing in them is a key, and nothing is sent anywhere.
- **Owner extras** (off unless you create `owner.json` in the app's data folder): only what one person can have: a Keychain-prompt alert in their own builds, keys also kept in 0600 files under `~/.config/hmunmawi/keys`, and Safari steps run through a program they name. `owner.json` can also set any of Your extras, and then wins over Settings. A new install has none of these, and the app ignores environment variables that point at another `owner.json` or key folder.
- **Mac notifications** stay on your Mac (macOS Notification Center). Review text and buyer details are hidden unless you switch on "Show details" in Settings → Menu bar, and sample data never notifies.

## Removing everything

Quit Hmunmawi and delete the app, these folders, and the preferences file:

- `~/Library/Application Support/Hmunmawi/` (your data, including outreach notes and mail text; routines you remove stay in `routines-deleted.json` for 30 days so you can restore them; `AddOnRun/` holds read-only copies of approved add-ons)
- `~/Library/Application Support/Hmunmawi/release-subscribers.json` (your local `0600` customer release subscriber lists and release delivery checkpoints, never synced to GitHub; deleted along with the folder above)
- `~/Library/Logs/Hmunmawi/` (app logs)
- `~/Library/Preferences/io.github.priyevsingh.Hmunmawi.plist` (settings, including your sending address and cached AI text)
- *iCloud Drive › Hmunmawi Backups* (if you used iCloud backups)
- `~/.local/bin/hm` (the command-line link, if you installed it)

Keys can be removed one by one in Settings → Connections → Disconnect, or in Keychain Access. Items are named `io.github.priyevsingh.Hmunmawi`, including the backup key, the key that signs your approvals and the activity log, and a few small "done once" marks and checkpoints for those checks. Removing the backup key means encrypted iCloud backups can't be opened again.

Hmunmawi doesn't delete data on other services (your App Store Connect, Sentry, PostHog or AI provider accounts); manage those there.

## Removing your data

Everything Hmunmawi keeps is listed above. To remove it all, follow [Remove Hmunmawi](README.md#remove-hmunmawi) in the README.
