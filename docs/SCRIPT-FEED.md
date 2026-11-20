# Your own numbers: the script feed

Hmunmawi can show numbers that no built-in connection knows about: your own backend, a spreadsheet export, a
website you run, anything a small script can read. You write a script that prints a little JSON; Hmunmawi runs it
every 10 minutes and shows what it prints as a card in the app.

Nothing about your script leaves your Mac. Hmunmawi only remembers where the script is.

## Set it up (5 minutes)

1. Write a script in any language and make it executable (`chmod +x my-numbers.py`).
2. In Hmunmawi open **Settings → Connections → Script feed**, enter the script's full path and press **Save**,
   then **Allow** the connection.
3. Press **Check Now**. Your card appears on the page you chose (see `page` below).

Or ask your AI agent: *"Write a Hmunmawi script feed that shows <what you want>, following docs/SCRIPT-FEED.md."*
The agent writes and tests the script; you paste its path in step 2. (Agents can't choose which script runs, on
purpose: that's always your decision.) The agent can then press Check Now for you with `hm check connection=scriptfeed`.

## What the script prints

```json
{
  "events": [
    {
      "kind": "section.snapshot",
      "app": "My backend",
      "occurredAt": 1794600000000,
      "dedupeKey": "signups-2026-11-14",
      "payload": {
        "id": "signups",
        "title": "Sign-ups",
        "page": "growth",
        "symbol": "person.badge.plus",
        "outcome": "42 people signed up this week, up from 30",
        "figures": [ { "label": "Today", "value": 7 }, { "label": "Last 7 days", "value": 42 } ],
        "bars":    [ { "label": "iPhone", "value": 30 }, { "label": "Mac", "value": 12 } ],
        "series":  [ { "label": "Sign-ups a day", "days": ["2026-11-13", "2026-11-14"], "values": [5, 7] } ]
      }
    }
  ]
}
```

- **`events`** must be there, even if empty (`{"events": []}`). Anything else is reported as a problem.
- **`occurredAt`** is milliseconds since 1970 (in Python: `int(time.time() * 1000)`). Seconds are refused.
- **`dedupeKey`** makes the same event count once. Use something that changes when the numbers do, such as the
  date.
- **`kind`** `section.snapshot` draws a card. The newest one for each `id` is shown.

## The card (`section.snapshot` payload)

| Field | What it does |
|---|---|
| `id` | A short name for the card; a new snapshot with the same id replaces the old one. |
| `title` | The card's heading. |
| `page` | Where it appears: `overview` (Today), `revenue` (Money), `growth` (Reach), `health` (Health) or `inbox` (Log). |
| `outcome` | One plain sentence at the top: what the numbers mean. |
| `figures` | Big numbers, each `{ "label", "value" }`; optional `format` (`number`, `usd`, `inr` or `percent`), `change` (0.38 = up 38%) and `better` (`up` or `down`, which direction is good). |
| `bars` | A bar chart, each `{ "label", "value" }`. |
| `series` | A line over days: `days` (YYYY-MM-DD) and `values` of the same length. |
| `barsFormat` | `percent` when each bar is already a rate; default `number`. |
| `items` | Lines on the card, each `{ "title", "outcome", "action", "severity", "figure" }` (all optional but `title`); `action` is a plain sentence saying what to do, so the line reads as a to-do. `severity` is `critical`, `high`, `medium` or `low` (critical and high show red, medium amber). |
| `symbol` | Optional SF Symbol name for the card's icon. |
| `order` | Optional number to sort cards on a page (smaller first). |

Leave out what you don't need; a card with only `title`, `page` and `figures` is fine.

## Good to know

- The script runs as you, outside the connection's sandbox, so it can read your files and call your own services.
  It has 2 minutes, must exit with 0, and should only read, never change things.
- If the script fails or prints something else, the Script feed connection turns red and says why; fix the script
  and press **Check Now**.
- For something that should *run* on a schedule (send a message, tidy files), use a routine instead:
  **Automations → Your routines → Run my script** (see [ROUTINES.md](ROUTINES.md)).

## Post ideas and to-dos

Any script you run can send drafts and plans in, so your creative work is tracked in one place: a YouTube Shorts
plan or stats, an Instagram Reel or carousel, a Reddit or Discord post idea, an X post, an article outline. Hmunmawi
has no built-in Instagram, Reddit, Discord or Shorts connection: your script (or an AI job you run) does the
thinking and prints a card whose `items` carry an `action` (a plain sentence saying what to do), so each idea
shows as a to-do line on its card. Hmunmawi tracks, queues and reminds; it never posts to any platform for you.
For example, a card with today's two to-dos:

```json
{ "kind": "section.snapshot", "app": "Social", "occurredAt": 1794600000000, "dedupeKey": "social-2026-11-14",
  "payload": { "id": "social-today", "title": "Social today", "page": "growth",
    "outcome": "2 things to post today",
    "items": [
      { "title": "Short: setting up widgets", "action": "Record and post the Short at 18:00" },
      { "title": "Carousel: 5 tips", "action": "Post the carousel from out/carousels/tips/" } ] } }
```

If you run these as Mac jobs, the Automations map groups jobs whose names mention a post, caption, Instagram or
short under **Social posts**, with a dot for what happened today. Remind-me routines and the Hmunmawi calendar put the
due ones on your phone.

## Startup programs card

A script can also fill the **Startup programs** card on the Money page (credits from accelerator and cloud
programs) with one event of kind `growth.programs`:

```json
{ "kind": "growth.programs", "app": "Programs", "occurredAt": 1794600000000, "dedupeKey": "programs-2026-11-14",
  "payload": {
    "approved": 2, "in_review": 1,
    "items": [
      { "name": "Example Cloud for Startups", "status": "approved", "value_label": "$5,000 credits", "expires": "2027-06-30" },
      { "name": "Example AI Startup Program", "status": "review" },
      { "name": "Example Accelerator", "status": "next" }
    ] } }
```

`status` is `approved`, `review` (in review), `next` (apply next) or `later`. Click the card for every program,
grouped by status.

## Events that start a fix script

The script feed accepts any event kind. Four kinds can start a **fix script** you picked in Settings → General:
`disk.low` (disk space runs low), `site.down`, `job.failed` and `crash.spike`. Hmunmawi itself has no disk check, so
`disk.low` comes from your own script, for example one that prints this when free space drops below your limit:

```json
{ "events": [ { "kind": "disk.low", "app": "This Mac", "occurredAt": 1794600000000, "dedupeKey": "disk-2026-11-14",
  "payload": { "title": "Only 18 GB free" } } ] }
```

More recipes (search health, publishing, social planning, AI jobs): [Your private workspace](PRIVATE-WORKSPACE.md#workflows-you-can-build).
