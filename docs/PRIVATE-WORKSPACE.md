# Your private workspace

Hmunmawi is the public app. Your **private workspace** is a small private repository of your own: scripts, data,
drafts and notes that feed the app and that nobody else should see. Together they let one Mac run the whole
list in [CAPABILITIES.md](CAPABILITIES.md): your Apple apps, websites and search, social plans, publishing,
crash and money alerts, and autopilot with your approval.

You don't need one to use Hmunmawi. Everything built in works without it. Build one when you want Hmunmawi to
show and track things that no built-in connection knows about.

## What it is, and why it is private

- **Hmunmawi** is the app: open source, on GitHub, the same for everyone.
- **Your workspace** is yours: a private repo (or just a folder) with your scripts, your numbers, your post and
  article drafts, your AI briefs and your keys.

Keep them apart. Your revenue, drafts, customer names and secrets stay off GitHub, and Hmunmawi stays something you
can update without touching your own work. Hmunmawi only remembers where your scripts are; it never copies them
anywhere ([Script feed](SCRIPT-FEED.md)).

## An example folder layout

Names are only a suggestion. Use whatever you like.

```text
my-workspace/
  STATE.md          what runs, what changed, what is planned (see the template below)
  AGENTS.md         rules for AI agents working in this repo (starter below)
  scripts/          your scripts: feeds, jobs, checks
  data/             small files your scripts read and write (queues, lists, caches)
  briefs/           written instructions you give an AI agent for one job
  out/              reports and drafts your scripts produce
  secrets/          keys and tokens (gitignored, never committed)
  .gitignore
```

A `.gitignore` to start with:

```gitignore
# Keys and tokens never go to GitHub
secrets/
*.env
*.p8
*.pem
*.key

# Output and scratch files
out/
tmp/
*.log

# Personal exports (sales, mail, customer lists)
data/private/
.DS_Store
```

Make the repo **private** on GitHub, or don't push it at all and keep it in your normal backups.

## How scripts feed the app

There are three ways your scripts and Hmunmawi meet. Mix them freely.

1. **Script feed: a script that shows numbers.** In **Settings → Connections → Script feed** you give Hmunmawi the
   path to one script. Every 10 minutes it runs the script, which prints a little JSON, and Hmunmawi draws it as a
   card. The script has 2 minutes, must exit with 0 and should only read. Full format:
   [SCRIPT-FEED.md](SCRIPT-FEED.md).
2. **Routines: a script that runs on a clock.** **Automations → Your routines → Run my script** runs a script at
   the times you choose (with a time limit of 1 to 60 minutes, 10 by default), keeps its output, and has a **Try out** switch that runs it
   with `--dry-run` (or the word you choose) so you can test without changing anything. Details:
   [ROUTINES.md](ROUTINES.md).
3. **Mac jobs: scheduled jobs you already have.** The Mac jobs connection watches your scheduled jobs (launchd),
   flags the ones that fail and lets you **Run now** or **Pause**; a routine can also run one of them on a schedule.
   See [ADD-ONS.md](ADD-ONS.md).

### A tiny example

`scripts/signups.py` prints one card. Replace the counting with your own backend or spreadsheet.

```python
#!/usr/bin/env python3
import json, time, datetime

today = datetime.date.today().isoformat()
signups_today, signups_week = 7, 42          # read these from your own source

print(json.dumps({"events": [{
    "kind": "section.snapshot",
    "app": "My backend",
    "occurredAt": int(time.time() * 1000),    # milliseconds, not seconds
    "dedupeKey": f"signups-{today}",
    "payload": {
        "id": "signups",
        "title": "Sign-ups",
        "page": "growth",
        "outcome": f"{signups_week} people signed up this week",
        "figures": [{"label": "Today", "value": signups_today},
                    {"label": "Last 7 days", "value": signups_week}],
        "items": [{"title": "Reply to new testers", "action": "Thank this week's sign-ups"}]
    }
}]}))
```

Run `chmod +x scripts/signups.py`, paste its full path in Settings → Connections → Script feed, **Allow** it, then
press **Check Now**. You can also ask your AI agent: "Write a Hmunmawi script feed that shows ..., following
docs/SCRIPT-FEED.md."

## How the work maps to what Hmunmawi can do

Hmunmawi tracks, plans, queues and reminds. It never posts to YouTube, Instagram, Reddit, Discord or X for you.
Your scripts (or an AI job you run) do the thinking and hand over cards, to-dos and drafts; you do the posting.

| You want | Your workspace does | Hmunmawi shows |
|---|---|---|
| **Apple apps** | Nothing needed. Connect App Store Connect and RevenueCat in Settings. Add scripts only for numbers from your own backend | Sales, subscriptions, reviews, releases, the Rejection Shield, offer codes |
| **Websites and search** | A script that checks a page, a sitemap or your analytics and prints a card; a routine can also watch a website address | Cloudflare, Google Search Console and Bing numbers, "website down", next steps such as searches with no page yet |
| **Social: Shorts, Reels, carousels, Reddit, Discord, X** | A script or AI job writes plans and drafts into `out/` and prints a card whose `items` have an `action` (a plain sentence). X drafts can sit in a bank (`hm bank-add`) | To-do lines on a card, routine reminders, X drafts at your best hours, the Social posts group on the Automations map |
| **Publishing: articles and posts** | A job that produces the article or post file and a card saying what is due | To-dos and jobs on the Automations map: what is due, what ran, what failed |
| **Crashes and health** | Nothing needed for Sentry. A script can print a card for anything else, such as your own server health | Crash-free sessions, failed Mac jobs, keys and certificates nearing expiry |
| **Money and offer codes** | A script can fill the Startup programs card; tools and plans are typed in the app | Payday, forecast, profit, AI credits, offer codes and their expiry |
| **Alerts** | Nothing needed. Alerts go out through iMessage, ntfy and the calendar | One message, only if it is still true 7 minutes later, with quiet hours |
| **Autopilot with approval** | Scripts you trust become routines; agents call `hm` | Anything that changes something waits in Log → Waiting |

### Approval comes first

- **Reading never needs approval.** `hm status`, `hm data-read`, `hm routine-list` and the like just answer.
- **Changes wait for your OK.** Unless you allowed that kind of change in **Settings → Rules → Agents**, a request
  from an agent waits in **Log → Waiting**.
- **Scripts are yours alone.** Only you can add or change a script routine, in the app. An agent may run or pause
  one, never point it at a different command.
- **Your drafts are only drafts.** Nothing is posted, sent or changed on any platform without you.

The whole list of commands is in [HM-COMMANDS.md](HM-COMMANDS.md) and `hm guide`.

## Running AI jobs on your own Mac

AI is optional. When you want it, there are three places it can run:

- **Your own AI session on your Mac.** Your scripts can start an agent you already use, such as Claude Code, with a
  brief from `briefs/`. Hmunmawi does not start it for you and does not need to know your login.
- **Apple's on-device AI.** Free and private on a Mac with Apple Intelligence (macOS 26 or later). Hmunmawi uses it
  itself for X reply ideas and mail reply reading; nothing leaves the Mac
  ([AI-AND-COSTS.md](AI-AND-COSTS.md#apples-on-device-ai)).
- **A provider key you add in Settings.** Claude, OpenAI, Gemini, Ollama (free, on your Mac) and others, with a
  monthly limit you set and, per AI routine, its own monthly cap.

### Queueing, limits and pause

What the app supports today:

- **One AI job at a time.** Hmunmawi has no job queue of its own. If your scripts run AI jobs, run them through one
  small wrapper script that creates a lock file while a job runs. Hmunmawi's AI routines wait while that file
  exists (the `HMAILockFile` setting, see [ROUTINES.md](ROUTINES.md#safety)); a lock older than an hour counts as
  stale so it can't block forever.
- **Pause.** `hm ai-pause-set until=<time> reason=<text>` (up to 30 days) or `indefinite=true` pauses your AI jobs;
  `hm ai-pause-clear` lifts it. Your wrapper script asks `hm ai-pause-check` before it starts a job: it answers
  available or deferred. If it says deferred, the wrapper exits and tries again later.
- **Limits.** Plan limits are shown under **AI & subscriptions**, with an alert rule at 80%. Spend is capped by your
  monthly AI limit.
- **Hmunmawi never starts a paid AI call without a key you added.**

A wrapper can be this small:

```sh
#!/bin/sh
# scripts/ai_job.sh <brief-file>   one AI job at a time, only when not paused
LOCK="$HOME/.my-workspace/ai.lock"
mkdir -p "$(dirname "$LOCK")"
hm ai-pause-check 2>/dev/null | grep -q '"available"' || { echo "AI paused, try later"; exit 0; }
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT
# start your own AI agent here, giving it the brief at "$1"
```

`hm` prints its answer as JSON, with `"result":"available"` or `"result":"deferred"`, so the wrapper looks for the
word. Run `hm ai-pause-check` once by hand to see it on your copy.

## STATE.md: a blank template

`STATE.md` is the work log for you and for your agents. One line per change, newest at the bottom.

```markdown
# STATE

What runs on its own, what is planned, who owns it. Update after every change.

## Running

| Job | When | What it does | Owner |
|---|---|---|---|
|  |  |  |  |

## Planned

-

## Log

| Date | What changed | Report |
|---|---|---|
| YYYY-MM-DD |  | out/reports/<name>.md |
```

### How agents should use it

- **Read `STATE.md` first**, before planning or changing anything.
- **Update it after acting**: the date, what changed, and a link to the report in `out/`.
- Keep entries short and true. Never put keys, customer names or exact private figures in it if the repo might ever
  be shared.

## AGENTS.md (or CLAUDE.md) starter for your private repo

Copy this to the root of your workspace and edit the parts in angle brackets.

```markdown
# Notes for AI agents in this workspace

Read STATE.md before planning or changing anything. Update it after acting.

## Rules
- Secrets live in the macOS Keychain or in files under secrets/ with permissions 0600. Never print them, paste them
  into chats or reports, or commit them.
- Scripts that feed Hmunmawi only read and print JSON (see Hmunmawi's docs/SCRIPT-FEED.md). Anything that changes
  something goes through Hmunmawi (`hm`) so it waits for my OK.
- Never post, reply, send or publish for me on any platform. Produce drafts and to-dos.
- Before running an AI job, check `hm ai-pause-check`; if it says deferred, stop.
- One AI job at a time (use scripts/ai_job.sh).
- Test with --dry-run first.

## Docs rule: keep the capability list in sync
Every docs, README, release-note or description update about this workspace or Hmunmawi must check and keep the
full capability list in sync (Apple apps, websites and search, social: YouTube Shorts, Instagram Reels and
carousels, Reddit, Discord, X; publishing; crashes; money and offer codes; alerts; AI limits; autopilot with
approval). Never under-sell or drop a capability; verify claims against the code. The single canonical list is
Hmunmawi's docs/CAPABILITIES.md.

## Commit rules
- Small commits with a plain description. <your own rules>
```

## Secrets

- **Keychain first.** Hmunmawi keeps its own keys only in the macOS Keychain, and add-ons never see them
  ([SECURITY.md](../SECURITY.md)). Add a key with `hm set-key connection=<id> field=<key> value=-`, which reads it
  from standard input, never from the command line.
- **Your scripts' keys** go in the Keychain too (read with the `security` command), or in a file under `secrets/`
  that only you can read: `chmod 600 secrets/<service>.env`.
- **Never commit a key.** `secrets/` and `*.env` are in the `.gitignore` above. Check with `git status` before every
  commit, and keep keys out of `STATE.md`, briefs, reports and chat messages.
- **Read-only keys where you can.** A key that can only read cannot cause damage if it leaks.
- If a key is ever committed, treat it as leaked: revoke it at the service and make a new one.
