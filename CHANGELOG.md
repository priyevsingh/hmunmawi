# Changelog

All notable changes to Hmunmawi are listed here, newest first. Version numbers follow [Semantic Versioning](https://semver.org).

## Unreleased

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
