# Changelog

All notable changes to Hmunmawi are listed here, newest first. Version numbers follow [Semantic Versioning](https://semver.org).

## 1.6.2 (build 162), 27 Nov 2026

**Fixed & Improved**
- **Release date timezone alignment & Story ranking (`SubscriptionTruthView`, `StoryBoard`, `FrontPage`, `FlowMap`):** Converted App Store lookup UTC release timestamps into local calendar days via `ReleaseDates.dayString(fromISO:timeZone:)` so `ReleaseReportPart` and `ReleaseTimelinePart` always agree on the go-live date, calibrated declared rating-floor notices below live subscriber/revenue drops in `StoryBoard.declaredScore(for:)`, clarified `Money` and `Reach` chart sub-labels (`"Subscribers paying right now (4 weeks)"`, `"First-time App Store downloads a day (all apps)"`), and replaced the clipped rolling transition on `StepTile` so wide currency values in `Your journey` never truncate.
- **Exhausted grants & stale AI usage detection (`UsageWatch`, `AgentBridge`):** Added `Credits.isExhaustedGrant(_:left:)` to exclude depleted non-monthly credit grants from `"running hot"` and summarize them in a muted `"Finished grants: ..."` line, and added `"stale": Bool` plus stale/at-limit `"problem"` strings in `AgentBridge.usageRow(_:now:)` for `hm usage` and MCP `hm_read usage`.
- **Live-version freeze context & read-only Sentry triage (`FatalFreezes`, `ServiceWatch`, `PortalPages`, `AgentBridge`):** Updated `FreezeSummary.lines(for:liveVersion:)` to label freezes confined to older releases (including `; 0 on live <version>`), added read-only `SentryIssues` triage classification/ranking (`isHangTitle`, `isAggregate`, `sortedForTriage`) so `hm services` ranks real crashes/uptime issues ahead of hangs and `mac-jobs-ok` aggregate rollups, and added a read-only **Copy brief for Claude** button in `Stability` while keeping active Sentry resolution/archival with local Claude sessions.
- **Regression tests & E2E script (`TelemetryPolishTests`, `e2e_audit_snapshot.py`):** Added 6 unit tests covering date conversion, StoryBoard priority ranking, retired grants, stale usage rows, freeze live-version annotation, and Sentry triage ordering, and updated `e2e_audit_snapshot.py` paths, certificate check logic, and UI matchers.

Hmunmawi still does everything it did in 1.6.1. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## 1.6.1 (build 161), 27 Nov 2026

**Improved**
- **Today & Story ranking, app labels & baseline deltas (`StoryBoard`, `TodayStory`, `Insights`):** Unified `rankedWorries` across `StoryBoard` and the morning story headline, ranked revenue and subscriber drops above routine declared items and review-drought notices, added clear app badges and channel icons (`magnifyingglass`, `globe`, `play.rectangle.fill`, `bubble.left.and.text.bubble.fill`) to finding rows, and surfaced baseline percent deltas cleanly.
- **Automation timeline hover, future slots & Dark Mode clarity (`AutomationDay`, `AutomationsPage`):** Replaced 1D clamped bead lanes with collision-free 2D bead placement (`layoutBeads`, up to 7 vertical lanes plus offset columns) so every `12 am` dot is individually hoverable, added 2D nearest-dot hover (`hoveredID`) with an instant floating job callout pill synced to the detail card, gated future `JobLists` slots today (`slotAt > date`) so scheduled afternoon/evening runs stay `"Later today"` instead of `"Ran"`, and boosted Dark Mode contrast across sky beads, `DotKey`, and `LivingFlow`.
- **Outreach detail wrapping & README clarity (`OutreachSheet`, `FlowLayoutRow`, `README`):** Reused `FlowLayoutRow` to wrap checkboxes and `DatePicker` pairs in `OutreachDetail`, removed middle/line-limit truncation on campaign and suggestion links so full URLs remain visible and selectable, and updated [README.md](README.md) headlines to reflect outcomes across both Apple apps and website projects.

Hmunmawi still does everything it did in 1.6.0. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## 1.6.0 (build 160), 26 Nov 2026

**New**
- **Smart Setup, Keychain recovery & zero-touch Vercel discovery (`SecretRebinder`, `KeyFinder`, `VercelDetector`):** Find my key discovers and auto-rebinds `vercel/apiToken` (including local Vercel CLI `auth.json` and `vercel.env`), `vercel/githubToken` (`gh` CLI Keychain extraction), and all AI provider keys (`claude`, `openai`, `gemini`, `openrouter`, `groq`, `mistral`). On launch and via **Auto-fill** in Settings → Connections, `VercelDetector` automatically fetches Vercel teams, projects, custom domains mapped to Hmunmawi project members, GitHub repos, and production branches via the Vercel API and local repo checkouts. Added built-in pricing tables for OpenAI, Gemini, and Groq, an optional toggle to allow unpriced models, comma-separated multi-project Vercel polling with project-matched redeploys, and optional AI polish for Weekly Digest (enforcing `Wording.rules` and strictly forbidding developer-location leaks).
- **Customer Release Notifications (`ReleaseSubscribers`, `ReleaseSubscribersSheet`):** Integrated release-update subscriber management in **Apps → Notify Subscribers** with per-app opt-in lists, CSV/text import, live App Store Connect release detection and What's New snapshots, editable batch drafts in `Log → Waiting` (`release.notify`) with spam/wording/location lint, Mail DNS checks, **Send test**, per-recipient resume checkpointing, automatic unsubscribe/bounce mail detection with 1-click Undo, and matching `subscribers-list`, `subscribers-add`, `subscribers-remove`, and `release-notify-draft` CLI/MCP tools.
- **Smart Outreach, Zoho Safari Compose & Sign-In Handling (`SMTPClient`, `MailSender`, `ZohoSafariAuth`, `AppStorePitchExtract`):** Outreach bookkeeping updates replies, bounces, declines, and opt-outs automatically with 1-click Undo (`AutoApplied`), guards against self-authored reply misattribution (`ReplyMatch.isOwn`) and purges self-authored threads, enforces do-not-contact / embargo / 1-follow-up-per-outlet / patch-release repitch guards, extracts outcome-led highlights and correlations from live App Store Connect descriptions without unsolicited promo/coupon/lifetime codes (attaching a reserved code only when a reply explicitly asks), separates **Awaiting reply** emails from **Listings & forms**, adds a **Draft email** action in `Outreach`, supports editable approve-to-send over TLS/STARTTLS SMTP (ports 465/587; port 25 refused) or Zoho Mail Safari compose (including automatic sign-in redirect handling via `ZohoSafariAuth` and **Open Zoho Mail in Safari** in Setup), and shows rotating progress spinners and inline card error banners across `Log`, `Today`, and `Outreach`.
- **Smart Autopilot & workflow polish (`AgentPolicy`, `ShieldChecklist`, `ReviewDrafter`):** Added an HMAC-signed `Smart Autopilot (recommended)` tier in Settings → Rules → Agents (`|smart|1`), explicit `alwaysAsk` owner-only gates (`submit`, `vercel.redeploy`, `python-repair`, `outreach-send`, `release-notify-draft`, `review-reply`, `set-key`, `remove-*`, `publish`, scripts), `hm approve` CLI refusal for critical/external jobs, proactive Ready to submit checklist (`Fix X reversible`) on Rejection Shield, exact build-number `ShieldPrep` cards, proactive open review reply drafting into `Log → Waiting` (`review.reply`), 1-click Autopilot nudges on eligible rules, Next steps task brief copying (`Copy brief`), batched `set-key` Waiting cards with inline non-secret previews and auto-pruning of superseded setup items, and `Approve all non-critical` (skipping every critical `alwaysAsk` job).
- **Community setup:** Added GitHub Discussions categories, `.github/SUPPORT.md`, `.github/FUNDING.yml`, subtle **Sponsor on GitHub** link in Settings → About, updated `CONTRIBUTING.md`, issue template chooser links, and `scripts/github-settings.sh` (`has_discussions=true`).

Hmunmawi still does everything it did in 1.5.9. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## 1.5.9 (build 159), 24 Nov 2026

**New**
- **Replay a sale’s moment.** Right-click a purchase on Today, or choose Replay last purchase animation in the menu bar panel (also under View in the menu bar), to play that payment’s animation again. It uses the real row: no extra entry, no notification, and no change to your numbers. The moment is drawn above an open story card, so a replay from a purchase row is visible while you are looking at Purchases. Reduce Motion still turns it off.
- **Every payment gets its own moment.** Free trials, introductory offers, refunds and the other payment events now show in the purchases list, and each plays a short moment of its own (a count-up for paid sales and renewals, a gift moment for free trials and intro offers, a quieter one for refunds and billing). The ticker at the top of Today follows the same events. Payment notifications that were previously dropped (redeemed offers, plan changes, refund reversals, failed renewals, price increases, and the rest) are stored too.

**Fixed**
- **A sale that arrived while you were away still plays when you come back.** If Hmunmawi wasn’t in front when a payment arrived, the moment is kept and plays when you bring the window forward, instead of being skipped once more than a few minutes had passed.
- **The menu bar’s Latest list shows every payment.** Free trials, intro offers and the other payment kinds now appear there, same as Purchases and the ticker (today’s sales count is still only paid sales and renewals). Choosing Replay last purchase animation closes the panel first and brings the main window forward, so the moment is never hidden behind the panel.

Hmunmawi still does everything it did in 1.5.8. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## 1.5.8 (build 158), 22 Nov 2026

**Fixed**
- **No more "lost its tab" and no leftover Safari tabs.** Every Safari job of the app (X unfollows, the X numbers and reply reads, the Zoho Mail reader, the Payouts fill and the offer-code import) now goes through one helper, `SafariAuto`: jobs take turns on one lock file (`safari.lock` in Hmunmawi's folder), each opens its own tab and tags it as soon as the page has loaded (inside one AppleScript call that closes the tab itself if the page never loads), finds it again only by that tag and never by its position, and closes it on every path. Tabs with an old tag of ours (or an older mark), left by a run that was killed, are closed at the start of the next one. Before, X unfollows could stop for the day with "lost its tab" when another job added or closed a tab at the same moment, and the Payouts fill and the offer-code import left the tab they had opened.
- **A lost tab no longer stops X unfollows for the day.** The account is tried again with a fresh tab (it still counts towards the "different accounts failing in a row" stop); Safari being busy with another job only delays the next try.

Your own tabs are never closed. Only tabs on a few known hosts are asked for their tag name when leftovers are swept. Format for your own scripts: [Your private workspace](docs/PRIVATE-WORKSPACE.md#scripts-that-use-safari).

Hmunmawi still does everything it did in 1.5.7. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## 1.5.7 (build 157), 21 Nov 2026

**New**
- **"Needs a look" from your scripts.** A script-feed event `job.attention` shows as an amber **Needs a look** item instead of a red failure: counted in the health pill, listed in Today's Health card and timeline, and sent by the new rule "A script says something needs a look" (at most once a day). A `routine.ok` or `job.finished` for the same job clears it. Format: [Script feed](docs/SCRIPT-FEED.md#needs-a-look-amber-not-a-failure).

Hmunmawi still does everything it did in 1.5.6. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## 1.5.6 (build 156), 21 Nov 2026

**Fixed**
- Live sales is in **Settings → General**. The What's new buttons for the live-sales changes, the worker message in Live sales and the docs (Guide, relay doc, Security, capability list) said Connections; they now point to General.

Hmunmawi still does everything it did in 1.5.5. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## 1.5.5 (build 155), 21 Nov 2026

**Fixed**
- **A new token when Cloudflare refuses the saved one.** When the last update of your webhook worker was refused (no access, or the token sees no account), Live sales says so and shows a token field with **Update worker**, instead of offering only the saved token again.
- Start here's first row no longer has an "Open Today" button (it already shows on Today).

Hmunmawi still does everything it did in 1.5.4. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## 1.5.4 (build 154), 21 Nov 2026

**New**
- **What changed, in plain words.** The update window shows the notes of this version and the four before it, and after an update Today shows a one-time **What's new** card: what is new since the version you last used, a line or two each, with a button to the screen it is on (for example Settings → Jobs). **Got it** puts it away. A fresh install shows a short **Start here** instead.
- One source for both: `Resources/WhatsNew.json`. `release.sh` stops before building when a version has no notes and after building when the feed item has none.

Hmunmawi still does everything it did in 1.5.3. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## 1.5.3 (build 153), 21 Nov 2026

**Fixed**
- **Updating a worker with a token scoped to one account.** A Cloudflare token that can edit Workers and KV in one account but can't list accounts made the update stop with "That token can't see a Cloudflare account". Hmunmawi now uses the account the worker was deployed to (Cloudflare still refuses the upload if that's wrong).
- A newer app build gets one more automatic try at updating an older worker (still one try per build, never a loop), so this fix reaches setups where 1.5.2's try failed.

Hmunmawi still does everything it did in 1.5.2. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## 1.5.2 (build 152), 21 Nov 2026

**Safer**
- **Worker fixes now reach existing setups.** The Cloudflare workers Hmunmawi deploys report a code version (`code_version` at `/asc/capabilities`). When the webhook worker in your account is older than the app's, Hmunmawi updates it at start with the Cloudflare token you saved, keeping its address, store and relay key, and checks the new version. One try per version: a failure is said plainly in Live sales and never retried in a loop. This brings 1.5.1's live-sales protections (only your own apps, nothing over 64 KB) to workers set up before.

**New**
- **Update worker** next to Remove in Settings → General → Live sales, for the webhook worker and for a purchase worker you deployed from the app (with a token field when none is saved).

**Docs**
- Guide pictures of Settings retaken with the grouped sidebar (and a new one of Settings → Jobs with Set up…), in dark mode. New diagrams: how an agent's request is decided (Guide) and how the worker stays up to date (live-sales relay doc). Capability list, README, ROUTINES, the private-workspace AGENTS starter and AGENTS.md (new worker-version rule) follow 1.5.1 and 1.5.2.

Hmunmawi still does everything it did in 1.5.1: the daily answer, Apple apps with the Rejection Shield, live sales, websites and search with Search health, social (YouTube Shorts, Instagram Reels and carousels, Reddit, Discord and X: tracked, planned and reminded, never posted for you, with post drafts, reply ideas and opt-in automatic X unfollows), job switches, service watch, link and Python checks, publishing, outreach and mail, crashes and self-healing, money and offer codes, alerts, AI limits, share and show, Your extras, and autopilot with approval. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## 1.5.1 (build 151), 21 Nov 2026

**Safer**
- **Python repair:** only folders with a `pyvenv.cfg` count as Python environments (a folder with just a `bin/`, such as `~/go` or `~/.cargo`, is never shown as broken or repaired), an agent's edit of a "Check my workspace Python" routine turns automatic repair back to asking, and an automatic repair is logged as the routine's, not yours.
- **Agent badges:** once you have made a badge, an agent without one always waits for your OK, even in Full Autopilot, so it can't dodge an "ask" rule by leaving its badge out.
- **Mac jobs:** agents can schedule only your own Mac jobs (the same prefix check as `job-run`, never `com.apple.*`); a routine that starts a Mac job needs "Run or pause Mac jobs"; only you can change the Mac jobs prefixes.
- **Web checks** (link check, outreach check) read at most their size limit while downloading, give up after 30 seconds, and never follow a redirect to this Mac or your own network. Links to local addresses are skipped.
- **Fixed time zone** set by an agent now needs "Run or change routines" (it moves every routine's time).
- **Live sales:** the worker takes nothing until your app names are set (Hmunmawi asks for them before it deploys) and refuses bodies over 64 KB. Redeploy from Settings → General → Live sales to get it.
- The owner settings and key-folder environment variables only work in test profiles.

**Better**
- **Settings sidebar** is grouped the way System Settings is: General and Menu bar; Connections, Projects and Jobs; Rules and Permissions; Publish and Backups; About.
- **Settings → Jobs:** each "Run by Hmunmawi" job that isn't set up has a **Set up…** button that opens its routine form.
- **Settings → General:** Owner extras lists only what one person can have; what an owner settings file sets among Your extras shows there once.
- **Settings → Rules:** Full Autopilot's button says **Turn On…**.
- **Today:** a worry is never coloured green; the Money card's change says what it measures ("14-day earnings, −₹520 since last look"); the Health card's sentence is about its big number (crash-free sessions) and what needs a look moves to the line under it. A long change line goes under the number instead of being cut off.

**Fixed**
- `plan-remove` is offered by the MCP `hm_change` tool (it was refused); the MCP tool lists are now built from the same command lists, and `mail-status` and `wall-plan` are read-only tools. A test keeps every guide command reachable over MCP.
- Agent guide: `ai-pause-set` / `ai-pause-clear` need "routines" (as the app checks), `lint-text` points to Settings → General, the Zoho reader to Settings → Connections → Outreach replies, `mail-status` names Zoho too, routines are added under Automations → +, and the settings table shows each setting's permission.
- Docs: PRIVACY.md describes the Zoho reader as one of Your extras and lists only the true owner extras; two broken links fixed; the `x_unfollows` switch key is documented.

Hmunmawi still does everything it did in 1.5.0: the daily answer, Apple apps with the Rejection Shield, live sales, websites and search with Search health, social (YouTube Shorts, Instagram Reels and carousels, Reddit, Discord and X: tracked, planned and reminded, never posted for you, with post drafts, reply ideas and opt-in automatic X unfollows), job switches, service watch, link and Python checks, publishing, outreach and mail, crashes and self-healing, money and offer codes, alerts, AI limits, share and show, Your extras, and autopilot with approval. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## 1.5.0 (build 150), 21 Nov 2026

**New**
- **Your extras** (Settings → General). Things that used to need a hand-made owner settings file are now there for everyone, set in the app, by an agent or by your private workspace: a **workspace folder** (Find my key looks in it and Settings → Jobs finds its switch file), a **key folder** and a **repositories folder** for Find my key, the **AI job pause card** for your own AI runner, the **Zoho Mail reader** (through your Safari login, for Zoho plans without IMAP), **X numbers from a file** and a **fixed time zone** for every date in the app. Each row says whether it is on and where that comes from.
- **Workspace extras file.** Put `config/hmunmawi-extras.json` in your workspace folder (`key_folder`, `repos_folder`, `ai_pause_card`, `zoho_mail`, `x_file`, `time_zone`; relative paths are inside the workspace) and the extras switch on by themselves. A choice made in Settings wins over the file; a broken file is named and switches nothing on. Recipe: [Your extras from your workspace](docs/PRIVATE-WORKSPACE.md#your-extras-from-your-workspace).
- Agents: `hm extras` (read only; also `extras` in state.json) lists every extra with its state, value, source and whether an agent may set it; `hm set key=extras.workspace|extras.key_folder|extras.repos_folder|extras.ai_pause_card|extras.zoho_mail|extras.time_zone` changes one (`none` clears). Folders and the Zoho reader need the Connections permission. Extras an owner settings file sets, and owner-only ones, are refused.

**Fixed**
- A fixed time zone now applies to every time the app shows. Before, some labels (such as the quiet-hours pickers) still used the Mac's own zone while "today" used the fixed one. It changes nothing when the fixed zone is the Mac's own.
- Settings guide pictures show the new Settings sidebar.

**Stays owner-only (and why)**
- The **Keychain-prompt watcher** is built into the app on the Mac that makes it, with a script that is not in the repo; the published, notarized app can't carry anyone's own script, so it is listed but never in a public build. Running Safari steps through another program, the owner's own AI-pause script, typed keys kept in recovery files and Wall of Apps welcome drafts also stay owner-only: each runs a program of the owner's, keeps keys outside the Keychain, or is the maintainer's job.

**Unchanged**
- An owner settings file (`owner.json`) still wins over everything, so a Mac that has one behaves exactly as before; its Owner extras list is unchanged. A key folder is only read when you press Find my key; it never becomes an automatic key source.

Hmunmawi still does everything it did in 1.4.1: the daily answer, Apple apps with the Rejection Shield, live sales, websites and search with Search health, social (YouTube Shorts, Instagram Reels and carousels, Reddit, Discord and X: tracked, planned and reminded, never posted for you, with post drafts, reply ideas and opt-in automatic X unfollows), job switches, service watch, link and Python checks, publishing, outreach and mail, crashes and self-healing, money and offer codes, alerts, AI limits, share and show, and autopilot with approval. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## 1.4.1 (build 141), 21 Nov 2026

**Fixed**
- **Settings shows every pane again.** With ten panes, the Settings toolbar ran out of room and hid the last ones (Permissions, Publish, Backups, About) behind a ">>" menu. Settings now lists its panes in a sidebar, like System Settings, so all ten are always in view at any window size. Nothing moved inside the panes.
- `hm set settings.tab` now also opens Menu bar, Publish and Backups (it only knew seven panes).

Hmunmawi still does everything it did in 1.4.0: the daily answer, Apple apps with the Rejection Shield, live sales, websites and search with Search health, social (YouTube Shorts, Instagram Reels and carousels, Reddit, Discord and X: tracked, planned and reminded, never posted for you, with post drafts, reply ideas and opt-in automatic X unfollows), job switches, service watch, link and Python checks, publishing, outreach and mail, crashes and self-healing, money and offer codes, alerts, AI limits, share and show, and autopilot with approval. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## 1.4.0 (build 140), 20 Nov 2026

**New**
- **Watch my services** (routine, Automations → +). Every 15 minutes it reads what the Sentry and Vercel connections found. Each new open Sentry problem comes as one plain sentence (a new crash, a website Sentry Uptime saw down, a job Sentry Crons saw late), and again when it closes; the first read only remembers, so connecting never floods you. When a website's production doesn't run its branch's newest commit (no deploy started after 10 minutes, or the build failed or ran over 30 minutes), it tells you once per commit and puts a **Redeploy** in Log → Waiting. Nothing deploys until you approve it.
- **Vercel connection.** Visitors and page views from Vercel Web Analytics (every 3 hours, a card on the Reach page), and every 15 minutes which commit production runs and whether your branch (read from GitHub; a read-only token only for a private repo) has a newer one. Its one action, Redeploy, runs only after your OK and is refused if the branch moved on since you approved.
- **Mac-alive heartbeat (Sentry)** (routine). A check-in to a Sentry Crons monitor every 5 to 60 minutes; Sentry makes the monitor from the first check-in. When check-ins stop because the Mac is asleep, off or Hmunmawi isn't running, Sentry tells you by its own email or app. Optional: report "error" while a Mac job Hmunmawi watches is failing.
- **Check links on my site** (routine, weekly by default). Reads your sitemap (up to 200 pages, 50 by default), checks up to 400 outside links four at a time, and calls a link dead only after two runs in a row found it gone (404, 410 or no such site); sites that block checkers or are briefly down never count. App Store links are checked with Apple's public lookup. New dead links are told once, with the page they're on. It never edits your site.
- **Check my workspace Python** (routine). Finds the Python environments your script routines and Mac jobs run with, tells you once when an upgrade broke one (with the exact fix), and keeps each working one's package list. **Repair…** keeps the old folder as `<name>.broken-<date>`, makes a fresh one and reinstalls the packages. Automatic repair is a switch only you can turn on.
- **Words I never use** (Settings → General). One word, phrase or `re:` pattern per line, with an optional reason. Post drafts and reply ideas that use one are skipped, the AI that refills your bank is told to avoid them, and scripts and agents check any text or file with `hm lint-text`.
- **Topics and "Never about" for post drafts**, and "Never about" for reply ideas. Topics now match from the start of a word ("health" matches "HealthKit", "ai" no longer matches "said").
- **Check before adding** in the outreach editor and `hm outreach-check`: is the page there, an email or contact form, paid-only wording, its language, and is the outlet already on your list (same name, website or address). `hm outreach-add` takes `url=` and `contact=` and answers `duplicate_of` for a likely duplicate (it still saves).
- **Plans and trials** in the expiry watchdog (and `hm plan-add`): a trial that ends or a plan that renews, reminded like a certificate.
- **Keep this Mac awake for routines** (Settings → General; Off, While plugged in, Always; off by default). Stops idle sleep while Hmunmawi runs; the screen still sleeps and a closed lid still sleeps the Mac. Agents: `hm set key=mac.keep_awake`.
- **Next steps: pages nobody clicks.** A page Google shows on its first page 100+ times in 28 days with under half your site's own click rate is suggested for a new title and description. Marked Done, its clicks are compared 14 days later, even after it stops showing as a suggestion (this now works for search-query steps too).
- New agent commands: `services`, `deploy-redeploy` and `python-repair` (both always wait for the owner), `links-dead`, `lint-text`, `outreach-check`, `python-check`, `plan-list`, `plan-add`, `plan-remove`.

**Changed**
- **Settings → Jobs → Run by Hmunmawi** lists every job Hmunmawi runs for you (X unfollows, Watch my services, the heartbeat, link and Python checks), with "Not set up" or an on/off switch.
- **Key watch** can also tell you when a connection hasn't worked for a day for any reason (on when you add a key-watch routine in the app; switch it on in older ones).
- **Sentry connection 0.2.0:** checks every 30 minutes and, with the token's `event:read` scope, reads your open issues; without that scope the crash numbers arrive as before.
- **Search Console** reads 50 pages with their average position (the Google detail still shows the top 10).

**Docs**
- Capability list, README, guide, routines, hm commands, add-ons, privacy, security, X setup and the private workspace guide updated; new diagram "How Watch my services works". New workspace recipes: checked plan steps, search titles with a ledger, a claims check in your PR gate, keeping your workspace in step with GitHub, Sentry uptime monitors.

Hmunmawi still does everything it did in 1.3.0: the daily answer, Apple apps with the Rejection Shield, live sales, websites and search with Search health, social (YouTube Shorts, Instagram Reels and carousels, Reddit, Discord and X: tracked, planned and reminded, never posted for you, with post drafts, reply ideas and opt-in automatic X unfollows), job switches, publishing, outreach and mail, crashes and self-healing, money and offer codes, alerts, AI limits, share and show, and autopilot with approval. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## 1.3.0 (build 130), 20 Nov 2026

**New**
- **X unfollows (automatic), opt-in.** A new routine (Automations → + → X unfollows (automatic)) that unfollows accounts that don't follow you back for you, through your own signed-in Safari: up to 25 a day by default (at most 40), only inside your window (10:00-20:00 by default), at least 10 minutes apart and spread through the day. The list is made once, from your Following page or Grok Bot's file, and never grows by itself (Rebuild list makes a new one); mutuals, your keeps, accounts with 50,000+ followers and anyone whose page shows "Follows you" are never touched. Each account gets one background tab that is checked (handle and user id, signed in as you, says Following), clicked (Following → Unfollow), checked again (now says Follow) and closed; your other tabs are never touched. A login page, challenge, rate limit, "Something went wrong", the wrong account, a lost tab or 3 accounts failing in a row stop it for the day with one message; two hard stops in a row hold it until you press Resume. One summary a day. **Try 3 (no unfollow)** checks the next profiles without clicking. A list made from Safari holds what X loads at first in a background tab (about your 50 most recent follows); press Rebuild list when it's done, or use Grok Bot's file for a longer one. Off by default; owner-only (agents may only pause or resume it).
- **Settings → Jobs** shows the new routine's on/off switch, and your switch file's `x` (now also covering automatic unfollows) and new `x_unfollows` keys turn it off too.
- The manual X unfollow list is unchanged and now points to the automatic one.

**Fixes**
- Profile checks match the exact `@handle` (a page for `@name2` is never taken for `@name`).

Hmunmawi still does everything it did in 1.2.0: the daily answer, Apple apps with the Rejection Shield, live sales, websites and search with Search health, social (YouTube Shorts, Instagram Reels and carousels, Reddit, Discord and X: tracked, planned and reminded, never posted for you), job switches, publishing, crashes and self-healing, money and offer codes, alerts, AI limits and autopilot with approval. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## 1.2.0 (build 120), 20 Nov 2026

**New**
- **Settings → Jobs: one-tap on/off switches for the jobs your scripts run.** Hmunmawi reads a small JSON switch file in your workspace (`config/hmunmawi-switches.json`, else `config/social_channels.json`, found through your workspace folder; or any file you choose) and shows each true/false as a switch with a one-line explanation: each channel (Reddit, Discord, Instagram, YouTube Shorts, X), Instagram details (post suggestions, new carousels, warm-up sessions), "account warmed up" per platform (Reddit, Discord, Instagram), and any other switch your file has (name them with `_labels` and `_help`). Flipping one changes only that value, in place: your `_comment`, unknown keys, order and spacing stay exactly as they were. The file is checked, then written atomically, and each flip is noted in the activity log. A file that isn't valid JSON, or a value that isn't true or false, is left alone and the tab says why; with no file, the tab explains how to add one. Your scripts see the change on their next run, so turning a job off never needs a code change. Pausing a whole scheduled Mac job stays on its row in Automations (… → Pause / Resume). Format and an example reader: [Job switches](docs/PRIVATE-WORKSPACE.md#job-switches).
- Agents can open the new tab with `hm set key=settings.tab value=jobs`.

Hmunmawi still does everything it did in 1.1.4: the daily answer, Apple apps with the Rejection Shield, live sales, websites and search with Search health, social (YouTube Shorts, Instagram Reels and carousels, Reddit, Discord and X: tracked, planned and reminded, never posted for you), publishing, crashes and self-healing, money and offer codes, alerts, AI limits and autopilot with approval. Full list: [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

**Docs**
- Gap check of the docs against the code: the capability list now also covers the daily answer, live sales, outreach and mail, the Search health card, share cards, the portal, the Wall of Apps, and install, updates, keys and backups, and says which parts are built in and which come from your own scripts. The private workspace guide adds job lists, a table of hand-off files, the Search health report format and script contract, fifteen workflow recipes (publishing on a schedule, social planning, search health, AI jobs and more) and an optional second AI while the first is paused. New diagrams, each with a plain-text list first: how it fits together, alerts, the morning answer, a workspace feeding the app, AI jobs, social planning, publishing, search health fixes, key recovery after an update, the Wall of Apps, the release gate and live sales. The script feed guide documents card `items`, figure formats and the events that start a fix script. Docs only.
- New guide, [Your private workspace](docs/PRIVATE-WORKSPACE.md): how to build your own private repo of scripts, data and AI briefs that drives Hmunmawi, with a folder layout and `.gitignore`, a script feed example, how each capability is fed, running AI jobs on your own Mac (pause and one-at-a-time lock), a blank STATE.md, an AGENTS.md starter with the capability-sync rule, and where keys live. Linked from the README, the capability list, the guide and AGENTS.md. Docs only.
- The README's Win / Worry / Next table now highlights every capability (Apple apps, websites and search, YouTube Shorts, Instagram Reels and carousels, Reddit, Discord and X as tracked and queued work, publishing, crashes, money, alerts and autopilot with approval) and has a "What it can run for you" list below it. The add-ons and script feed guides, and the guide's Connections section, say the same, and say plainly that Hmunmawi never posts to a platform for you.
- The README's "Next" row now covers more than X: your own scripts can feed in Shorts or Reels plans, carousels, Reddit or Discord post ideas, X posts and articles as to-dos (this uses the existing script feed and Mac jobs add-ons; nothing new is built in). Added a "Post ideas and to-dos" section to the script feed guide.
- The README's Win / Worry / Next table now shows what Hmunmawi looks after for your Apple apps and for everything else you run through add-ons. The three flow diagrams in the docs have a plain-text list before them and no `<br/>` in their labels, so they read cleanly in the GitHub iOS app and other viewers.
- The docs now match 1.1.4: the YouTube Google sign-in file, key re-import and the fresh Keychain item, the signing-identity banner, the release signature gate and the CI-gated publish step, the connection check intervals, and the pull-request rules for `main` (SECURITY and RELEASING agreed). Removed a repeated section in RELEASING and closed an unclosed fold in the guide.

## 1.1.4 (build 114), 20 Nov 2026

**Fixes**
- **YouTube recovers by itself:** the YouTube connection can now use a Google sign-in file (client id, client secret and refresh token, the kind your own upload scripts already use) instead of an API key, and re-imports it from its saved file at launch with no typing. Any connection with a known key file is re-imported the same way, and a key typed in Settings is also kept in a private file (mode 0600) in `~/.config/hmunmawi/keys/` (owner extras only; a normal install keeps keys in the Keychain alone), so a later signature change can't leave a connection needing a re-entry.
- **Key check:** `Hmunmawi --verify-secrets` no longer reports the old YouTube API key as failed when the YouTube Google sign-in is in place: a connection satisfied by an alternative credential counts as ok.

**Release process**
- A release is refused unless its code-signing designated requirement is identical to the previous release's (`scripts/check-designated-requirement.sh`, run by `release.sh` and again by `publish-release.sh`), so an update can never re-ask macOS permissions or Keychain keys.

## 1.1.3 (build 113), 20 Nov 2026

**Fixes**
- **Moving between a development build, the release build or a new certificate:** keys saved by the earlier copy of the app can't be read or changed by the new one without a Keychain password box, which Hmunmawi never shows, so every connection with a key file stayed "needing attention". Hmunmawi now saves such a key in a fresh Keychain item of its own (the old one is left alone) and re-imports it from its saved file at launch, with no click and no password box. The same applies to its other saved settings (trust key, flags).
- **New signing identity noticed:** when the app is signed differently from the last launch, Settings → Permissions and the activity log say so and list exactly which macOS permissions to switch on again (Full Disk Access, Files & Folders, Calendars, Accessibility, Automation), because macOS ties those grants to the signature.

## 1.1.2 (build 112), 19 Nov 2026

**Fixes**
- **Launch never freezes on a permission prompt:** if a saved key file is in a protected folder (Documents, Desktop, Downloads, iCloud or an external drive), macOS may ask permission the first time, for example after an update. Hmunmawi now reads those files in the background after the window and menu bar are up, instead of stopping at launch until you answer. Each file is read once per launch. If macOS refuses a file or it takes long, that connection is marked as needing attention (and noted in the activity log), and connections check in as soon as their keys are in.

## 1.1.1 (build 111), 19 Nov 2026

**Fixes**
- **Mac jobs tile:** a routine that failed and then ran fine again no longer keeps the tile red. Any later successful run clears the earlier failure. The record of a successful run is internal only: it never shows in the activity log, Today, notifications or the menu bar, can't trigger a rule, and only the latest one per routine is kept.
- **Failure messages:** a failed routine now shows the line that explains the problem (an error, a timeout, a denied permission), not just the last line of its output.

## 1.1.0 (build 110), 19 Nov 2026

**Fixes**
- **AI pause:** AI-credit messages no longer pause AI routines. Only a real session or weekly limit does, and a date more than about a week away is ignored.
- **Post drafts:** the routine now checks X's published algorithm daily instead of weekly.
- **Ticker:** a sale's age keeps moving. Yesterday's sale no longer reads "1 minute ago" all day.
- **Ages everywhere stay current:** "5 minutes ago", "yesterday" and the like now update by themselves every minute in
  the menu bar panel, Today, Log, Settings, Reviews, Status and the rest of the app, using one shared formatter.
- **Menu bar panel:** App Store Connect version updates are labelled "App Store Connect" instead of "Hmunmawi", so one
  app's review status no longer looks like Hmunmawi's own.
- **UI test helper:** `scripts/uitest/ax.swift menubar` opens the panel on macOS versions where the system hosts
  menu bar icons, including when the icon is tucked behind the notch.

**Easier to reach the menu bar panel**
- **Shortcut from anywhere:** ⌃⌥H opens and closes the panel, even when macOS hides the icon behind the notch. Change
  it or turn it off in Settings → Menu bar. It needs no extra permission.
- **Panel button** in the window's toolbar, with the shortcut as its hint.
- **Slimmer icon:** a narrower "H" with its dot. New installs show the icon alone; a number you already chose stays.
- **A one-time tip** when macOS has hidden the icon: how to open the panel and how to ⌘-drag the icon into view.

**For maintainers**
- **Releases wait for CI:** `scripts/publish-release.sh <version>` pushes `main`, waits for the CI workflow on
  that commit to pass, and only then tags and publishes the GitHub release. If CI fails, nothing is published.
- **Build tooling:** CI uses `actions/checkout` and `actions/setup-node` v7, and the live-sales worker tests run on
  Vitest 5 with the latest Cloudflare test plugin.

## 1.0.0 (build 100)

The first public version. Hmunmawi is a calm Mac app for indie app developers: it reads your numbers, tells you
what matters each day, and asks before it acts. Free and open source.

**Every day**
- **Today:** one page with what went well, what to watch and what to do next, written in plain words from your own
  numbers. Money, reach and health at a glance, your projects (apps and websites) side by side.
- **Money:** earnings by month up to today (Apple's monthly reports, and the current month from Apple's daily
  sales so far), where each payment stands (paid, due, overdue), and where every rupee or dollar went.
- **Costs and profit:** your tools and plans (free ones from a startup program listed, never counted), API credits
  with their spend read from Anthropic's cost report, OpenAI, xAI, OpenRouter and DeepSeek accounts, plan limits
  with reset times, and an AI job pause for your own scripts.
- **Menu bar:** an "H" with a health dot, an optional number (sales, downloads, reviews, things waiting or things to
  fix) and a panel with today, your connections, the latest moments and anything waiting for your OK. A sale that
  arrives while the window is closed plays its moment when you come back.
- **Mac notifications** that stay quiet: grouped per app, bursts combined, quiet hours respected, never for sample
  numbers, and a problem only if it's still there 7 minutes later (the same one at most every 12 hours).

- **Publish from an agent:** `hm publish` writes your portal and runs your approved upload command (waits for your OK
  unless you allowed it). A public copy now also drops any list line that names an amount.

**Your sources**
- Connections for App Store Connect, RevenueCat, PostHog, Sentry, Google Search Console, Bing Webmaster Tools,
  YouTube, X, Cloudflare and your own scripts. Live purchase updates through a small worker in your own
  Cloudflare account. A day reported by two sources is counted once.
- Works for apps on every Apple platform: iPhone, iPad, Apple Watch, Mac, Apple TV and Vision Pro. Releases, TestFlight builds
  and Submit for Review follow each version's own platform.
- Keys stay in your Mac's Keychain. Connections run as separate, sandboxed add-ons you approve, never see your keys,
  and can be disconnected (keys deleted) from Settings → Connections.
- **Your own numbers:** a small script can add cards to any page (see docs/SCRIPT-FEED.md).

**Doing things for you**
- **Routines:** reminders, website checks, offer-code expiry warnings, post drafts from your bank, AI briefs about
  your numbers, outreach follow-ups, your own scripts (with an optional settings file) and your Mac's own scheduled
  jobs, one or several times a day or every 1–60 minutes, each with a try-out mode first. Everything that changes
  something waits for your OK.
- **X, the way the maintainer runs it:** your X numbers through your Safari login (no API, no key), your X at a
  glance (pinned post, latest article, a post that's taking off, your top replies), drafts at your best
  hours, reply ideas and a daily unfollow list from Grok Bot or, without it, found by Hmunmawi through your
  Safari login (replies drafted free by Apple's on-device AI, or your AI key), all checked; you always post, reply and unfollow by hand
  (docs/X-SETUP.md).
- **Post drafts that follow X:** weak drafts are skipped, the best goes first, and the ranking follows X's published
  algorithm (checked weekly, no AI; changes logged and undoable).
- **Publish:** your numbers as a portal web page in the app's colours, light or dark (earnings by month, apps, the App
  Store, subscribers, retention, trends, X, Google Search and Bing, YouTube, outreach, attention, startup programs, your account and more), with sections you choose, a "safe to show anyone" switch and an
  optional upload command for Cloudflare Pages or Netlify.
- **Share cards** for a week of your numbers, ready to post.
- **Agents** (Claude Code, Cursor and others) can read what the app shows and stored numbers (`hm data-read`), and
  ask for actions through `hm` or MCP, under the same approval rules.

**Wall of Apps**
- Add your app from Settings → About; every entry is checked against the App Store automatically, and the README
  shows a mosaic of app icons with a full list, both rebuilt by themselves. Once your app is on the wall you can
  share it on X, and you can browse the community's apps in the app.

**Safety**
- Self-healing: a Mac job that fails is started once more; a connection that stops answering is restarted; missed
  runs catch up; fix scripts you pick in Settings (for example, free disk space when it runs low) run by themselves
  and wait for a new OK if the file changes.
- Daily backups (a full copy, the settings when they changed, and small daily snapshots), with an encrypted copy in
  iCloud Drive if you want one; a damaged database is restored automatically.
- Signed activity log, signed approvals, and nothing personal in the app or its code.
- Signed with Developer ID and notarized by Apple; in-app updates through Sparkle 2.10.1 (signed feed).
