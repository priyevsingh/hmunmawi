# Routines

Routines are things Hmunmawi does on its own clock while it's open (it starts when you log in). You'll find them in
**Automations → Your routines**, and agents can reach the same list through `hm`.

Every routine has a time, either one or several times of day on chosen days, or every 1, 5, 15, 30 or 60 minutes. A run that was
missed (the Mac was asleep) still starts if it's within the routine's catch-up window, and never runs twice.

## What a routine can do

| Kind | What it does | Needs |
|---|---|---|
| Remind me | Sends your words at set times | iMessage or ntfy |
| Watch a website | Checks an address; tells you after 2 failed checks in a row, and when it's back | the address |
| Warn before offer codes expire | Warns 30, 7 and 1 day(s) before an App Store offer code expires | App Store Connect |
| Ask AI about my numbers | Asks your AI about the week's numbers, your search terms or crashes; costs nothing when there's nothing new | an AI key |
| Post drafts from my bank | A few ready drafts a day from a bank, the best one first; weak drafts (too short, a sentence lifted from an article, nothing to reply to) are skipped. The ranking follows X's published algorithm (checked daily). The AI writes more only when the bank runs low. Optional **Stay on these topics** (`topics`) and **Never about** (`avoid`); drafts naming an app version that isn't the current one, or using one of your **Words I never use**, are skipped too, and the drafting AI is told your topics and avoided words. You post them yourself | a bank or an AI key |
| X reply ideas | One ready X reply at each of your times. From Grok Bot (its daily reply-targets file) or, without Grok Bot, from Hmunmawi itself: a daily X search for your topics through your Safari login, replies drafted free by Apple's on-device AI, or your AI key, or none (you write them). Skips posts older than 48 hours, off your topics (a topic matches from the start of a word: "health" matches "HealthKit", "ai" doesn't match "said"), about anything on your **Never about** list (`avoid`, whole words), with a link, an outdated version, or a reply using one of your Words I never use. You post it yourself ([set up](X-SETUP.md#-reply-ideas)) | Grok Bot's file, or Read via your Safari login and your topics |
| X unfollow list | Once a day a short list (10 by default, at most 25) of accounts that don't follow you back, to unfollow by hand, from Grok Bot's list or your own Following page read through Safari (accounts with 50,000+ followers kept); your keeps are never listed. This one never unfollows for you ([set up](X-SETUP.md#-unfollows-by-hand-or-automatic)) | Grok Bot's list, or Read via your Safari login |
| X unfollows (automatic) | Opt-in, off until you add it. Every 5 minutes it checks whether the next unfollow is due: up to 25 a day (at most 40) inside your window (10:00-20:00 by default), at least 10 minutes apart, from a list made once (your Following page or Grok Bot's file) that never grows by itself. One Safari tab per account, checked before and after; mutuals, keeps, big accounts and anyone showing *Follows you* are never touched. Stops for the day at any sign of trouble, holds after two hard stops in a row; one summary a day. **Try 3 (no unfollow)**, **Rebuild list** and **Resume** in its form; on/off also in Settings → Jobs. Owner-only: agents can only pause or resume it | Read via your Safari login, with your X handle; Hmunmawi allowed to control Safari |
| Follow-up reminders | Which outreach follow-ups are due (one per outlet) | an outreach list |
| Warn when a key stops working | A connection refused, expired or revoked twice in a row: told once, and again when it works. With **Also tell me when a connection hasn't worked for a day** (`long=1`; on when you add a key-watch routine in the app, off for ones made before 1.4.0 or by agents unless they pass `long=1`) a connection failing for 24 hours for any other reason is told once too | nothing |
| Watch my services | Every 15 minutes: each new open Sentry problem once in plain words (a new crash, a website Sentry Uptime saw down, a job Sentry Crons saw late), and again when it closes; the first read only remembers. A website whose production doesn't run its branch's newest commit (no deploy started after `behind` minutes, 10 by default, or the build failed or ran over 30 minutes) is told once per commit and a **Redeploy** waits in Log → Waiting; told again when production catches up. Switch parts off with `issues=0` or `deploys=0` | the Sentry connection (with `event:read`) or the Vercel connection |
| Mac-alive heartbeat (Sentry) | Every 5, 15, 30 or 60 minutes a check-in to a Sentry Crons monitor (Sentry makes the monitor itself from the first one, an interval schedule with a margin of half the interval, at least 5 minutes). When check-ins stop (the Mac asleep or off, Hmunmawi quit), Sentry tells you by its own email or app. With `jobs=1` the check-in says "error" while a Mac job Hmunmawi watches is failing. A failed check-in never alarms you itself | your Sentry project's DSN (`dsn`), a monitor name (`slug`, default `hmunmawi-mac`) |
| Check links on my site | Weekly by default (Mondays): reads your sitemap (or sitemap index, or the one page you give), up to `pages` pages (50 by default, at most 200), collects up to 400 links to other websites and checks them four at a time (HEAD, then GET). Dead only after two runs in a row found it gone (404, 410 or no such site); 401, 403, 429, 5xx and timeouts never count. App Store links are dead only when Apple's public lookup finds nothing and the page answers 404. New dead links are told once (with the page they're on), and again when one works. Never edits your site | your site's address |
| Check my workspace Python | Finds the Python environments (venvs) your script routines and Mac jobs run with (from their commands and scripts' first lines), plus `folders` you name. A broken one (its Python removed or upgraded away) is told once with the fix; a working one's package list is saved about once a day. **Repair…** (in its form) or `hm python-repair` keeps the old folder as `<venv>.broken-<date>`, makes a fresh one with this Mac's python3 and reinstalls the saved packages. `repair=auto` (owner-only, in the app) repairs at once | nothing (reads your LaunchAgents and scripts) |
| Judge my changes | After 7 to 28 days, keep / improve / undo for each change you asked it to watch | a change to watch |
| Run one of my Mac jobs | Starts one of your Mac jobs (LaunchAgents) on this schedule. "Take over its own timer" keeps a copy of the job's file and removes its own schedule; switching the routine off or deleting it puts the original back. A job that fails is started once more a minute later | a Mac job |
| Outreach replies | Matches replies in your mail to your outreach list; each change waits for your tap | a mail source (Settings → Connections → Outreach replies) and an outreach list |
| Run my script | Your own script (time limit 1–60 minutes, 10 by default), output kept; optional working folder and a settings file of KEY=VALUE lines the script gets; **Try out** runs it with its dry-run argument and records only | a script |
| Morning story, Weekly digest | The app's own summaries; switch them off here. The morning story can add one line from your AI | — |

Recipes that combine routines with your own scripts (publishing on a schedule, social planning, search health, AI jobs): [Your private workspace](PRIVATE-WORKSPACE.md#workflows-you-can-build).

Every routine can tell you by iMessage or ntfy, and can also tell you each time it runs. Messages respect quiet
hours (urgent ones, like a site going down, still go out).

## Words I never use

Settings → General → **Words I never use**: one per line, a word or phrase (whole words, any case) or `re:` and a
pattern, then `|` and why (optional). Post drafts and reply ideas that use one are skipped, the AI that refills
your bank is told to avoid them, and your scripts and agents can check any text or file with `hm lint-text`
(`clean: false` lists each hit and why). The file is `wording-rules.json` in Hmunmawi's folder, so a script or an
agent can edit it too; an invalid pattern is shown in Settings and ignored.

## Safety

- **Signed.** Routines are signed with a key only Hmunmawi has. One edited outside the app shows "Changed
  outside the app" and doesn't run until you approve it. This includes your bots' and cloud jobs: their whole text
  and on/off are signed, and one edited outside the app is left out of the message you paste into the bot until you
  approve it.
- **Removing is undoable.** A removed routine (by you or an agent) stays 30 days under "Recently deleted" in
  Your routines, with a Restore button, and exactly as it was (still approved).
- **AI spends only within limits.** Each AI routine has its own monthly cap on top of the app's AI budget, and
  waits while another program's AI job holds the lock file (`HMAILockFile`).
- **AI never acts on its own.** AI results are summaries sent to you or drafts you post yourself. The judge
  only suggests; nothing is undone for you.
- **Nothing outside Hmunmawi changes by itself.** A website redeploy and a Python repair always wait for your OK
  (or your own tap), even in Full Autopilot. Automatic Python repair can only be switched on by you, in the app.
- **Scripts are yours alone.** Only you can add or change a script routine, in the app. Agents may run or
  pause one, never point it at a different command. Scripts run directly, never through a shell.

## Bots

A bot you chat with (such as Grok Bot) has no shell. In **Your routines → Set up your bot** you'll find:

- **The bot's name.**
- **A shared folder.** The default is `~/Documents/Hmunmawi Bot`. It's created only when you copy the message or
  press Show, and Hmunmawi keeps a `routines.md` there.
- **A message to paste into the bot.** It lists the bot's jobs, their times and the file each one should leave
  behind. When the jobs change, the list says so; copy the message again.

Add a bot's job as a listed routine ("Runs on: bot"). Give it a **proof file** (`{date}` becomes the day's date)
and choose **Tell me if it's late**. Hmunmawi then tells you when the file hasn't arrived by that time.

A bot that can't do a job writes `problem-<job>-<date>.txt` in the shared folder, and Hmunmawi passes it on
(at most 10 a day).

Agents that can run commands (Claude Code, Cursor, cloud agents) need nothing pasted. They use `hm`.

## For agents (`hm`)

| Command | What it does |
|---|---|
| `routine-list` | Every routine with its state, last run and proof file |
| `data-read` | Stored numbers by kind (`kind=… since=YYYY-MM-DD`), newest first; with no kind, the list of kinds stored |
| `job-run` | Start one of your Mac jobs now |
| `routine-run`, `routine-pause`, `routine-resume` | Run a routine now (at most once per 10 minutes), or switch it off or on |
| `routine-add`, `routine-set` | Make or change a routine; `who=bot proof=… late=60` lists a bot's job |
| `routine-remove` | Remove a routine (needs the "deletes" permission); it is kept 30 days in Recently deleted |
| `bot-setup` | The message for a bot without a shell |
| `bank-list`, `bank-add` | Ready drafts |
| `outreach-list`, `outreach-add`, `outreach-followed-up` | The outreach list |
| `metric-list`, `change-add`, `change-list`, `change-remove` | Changes to judge |
| `services`, `deploy-redeploy` | Sentry's open problems and each website's deploy state; a redeploy always waits for the owner |
| `links-dead` | Dead links each Check links on my site routine found |
| `python-check`, `python-repair` | The venvs your scripts use and which are broken; a repair always waits for the owner |
| `lint-text` | Check text against your Words I never use |

Changes need the "Run or change routines" permission (Settings → Rules → Agents). Without it, a request waits
for your OK in Log → Waiting. Bad values are refused right away, with the format expected. `hm guide` lists every
field.

## Files

All of these are in `~/Library/Application Support/Hmunmawi/`, and all are in the daily backup:

| File | Holds |
|---|---|
| `joblists/my-routines.json` | The routines |
| `banks/<name>.json` | Ready drafts |
| `outreach.json` | The outreach list |
| `changes.json` | Changes being judged |
| `wording-rules.json` | Your Words I never use (`{"never": ["phrase", {"text": "…", "why": "…"}, "re:pattern"]}`) |
| `link-check-<id>.json` | Each link check's dead and to-check-again links |
| `python-locks/<venv>.txt` | The package list of each working venv, for a repair (not backed up) |
| `routine-logs/<id>.log` | Each script routine's output (not backed up) |


## Post drafts that follow X's algorithm

**What you get:** the drafts you're sent are the ones most likely to get replies and reads on X today, and they stay
that way when X changes what it rewards, without you reading the code yourself.

- **Weak drafts are skipped:** under 18 words, a sentence lifted from an article with no view of your own, or a post
  with neither your voice ("I", "we") nor a question. The routine's note says which draft was skipped and why.
- **The best draft goes first,** scored on: a closing question (replies), 30+ words (reading time), how-to and lesson
  wording (posts people pass on) and concrete numbers.
- **Weights from X's own code:** X publishes its ranking at
  [github.com/xai-org/x-algorithm](https://github.com/xai-org/x-algorithm). At most once a day the routine asks GitHub
  whether it changed. Only then it reads X's weights for replies, copying the link, sharing by DM and time spent (in
  `home-mixer/params/param.rs`) and turns them into the draft weights by fixed formulas, each kept between 0 and 3.
  No AI is involved, so the same X code always gives the same rules. For example, X's 13 November 2026 release set
  copying a link to 0 (it was 20), so concrete numbers now count less and questions keep their weight.
- **You can see and undo it:** every change is written to the activity log (Log → Every step) and the routine's note,
  with the old and new weights and the X commit. The rules live in `x-rules.json` in Hmunmawi's data folder, the
  previous ones in `x-rules.prev.json`; delete `x-rules.json` to go back to the built-in rules.
- **At your best hours:** with X numbers (your Safari login or Grok Bot's file) and about 5 recent posts, drafts go
  out at the hours your own posts got the most replies and likes, scored with X's current weights, at least your gap
  apart and never at night. Off with `best_hours=0`.
- **Switch it off** with `follow_x=0` on the routine (`hm routine-set id=<id> follow_x=0`); the built-in weights are then used.
