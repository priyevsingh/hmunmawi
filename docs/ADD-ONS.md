# Writing an add-on

An add-on connects Hmunmawi to one service. It is a small program, in any language, that talks to the app with one line of JSON at a time over standard input and output. The app starts it, asks it to check for news on a schedule, and runs its actions when a rule or you ask.

Add-ons never see your keys and can't reach the internet on their own: they ask the app to make each web request, and the app only sends it to the hosts the add-on declared.

## What the built-in add-ons cover

The full list of what Hmunmawi does is in [CAPABILITIES.md](CAPABILITIES.md). Hmunmawi ships with these add-ons (every folder in `AddOns/`). Together they cover your Apple apps, your websites and search, YouTube and X, crashes, subscriptions, alerts and your own scripts and Mac jobs.

| Add-on | What it does for you |
|---|---|
| App Store Connect | Reviews, icons, version status, daily downloads and proceeds, hourly |
| RevenueCat | Active subscriptions, trials, MRR and 28-day revenue |
| PostHog | Daily active users |
| Sentry | Sessions and crashes each day (crash-free rate) and, with the `event:read` scope, your open problems, every 30 minutes |
| Cloudflare | Website visitors each day |
| Vercel | Website visitors and page views (Web Analytics), multi-project deploy health (comma-separated project IDs); Redeploy only after your OK |
| Google Search Console, Bing Webmaster Tools | Search clicks, impressions, top searches and pages (Search Console: 50 pages with their average position) |
| YouTube | Subscribers, views and newest videos. A Google sign-in file from an OAuth app still in "Testing" stops working after 7 days (Google expires its refresh token); the Key watch routine tells you when that happens |
| X | Followers, views and engagement from your daily X file; no key needed |
| Script feed | Anything your own scripts print: numbers, plans and to-dos for Shorts, Reels, carousels, Reddit, Discord, X posts and articles ([how](SCRIPT-FEED.md#post-ideas-and-to-dos)) |
| Mac jobs | Your scheduled Mac jobs: runs, failures, Run now and Pause |
| iMessage, ntfy | Alerts to your phone |

Hmunmawi tracks, plans, queues and reminds. It never posts to YouTube, Instagram, Reddit, Discord or X for you, and anything that changes something waits for your OK.

The Search Console and Bing add-ons only read: submitting pages or sitemaps to search engines is left to your own scripts. A few things are fed without an add-on, through files your scripts write: the Search health card, job lists on the Automations map, AI usage and the X file. See [Hand-off files](PRIVATE-WORKSPACE.md#hand-off-files).

## Notes on some built-in add-ons

**Vercel** (`AddOns/vercel`). Settings: project name or ID (or a comma-separated list of project names/IDs for multiple sites), Team ID (optional, `team_…`), the website name to show,
a GitHub repository (`owner/name`, optional; read from the project's Git link when empty), the production branch
(optional; Vercel's own when empty), an access token (Vercel → Account Settings → Tokens, scoped to the team that owns
the project) and an optional GitHub token (fine-grained, read-only Contents, only for a private repository; **Find my key** can pull this from `gh` CLI's Keychain entry or `.env`). In Settings → Connections → Vercel, **Detect from repo…** fills Project ID, GitHub repo, and production branch automatically from `.vercel/project.json` and `.git/config`.
Hosts: `api.vercel.com` and `api.github.com`; each token may only go to its own host (`secretHosts`).
- Every 15 minutes: for each project, the newest production deploy (`GET /v9/projects/{id}`, `GET /v7/deployments?target=production`),
  the branch's newest commit from GitHub (`GET /repos/{owner}/{repo}/commits/{branch}`, no token for a public repo)
  and any deploy for that commit (`GET /v7/deployments?sha=…`), as separate `deploy.snapshot` events.
- Every 3 hours: visitors and page views for 7 and 28 days and visitors per day per project, from Vercel Web Analytics
  (`GET /v1/query/web-analytics/visits/count` and `/visits/aggregate?by=day`), as cards on the Reach page (`vercel-visitors-<id>`). A plan or
  project without Web Analytics only skips this card.
- One action, `vercel.redeploy`: matches the target project and deploys the branch's newest commit to production (`POST /v13/deployments` with
  `gitSource`; refused if the branch moved since you approved), or rebuilds a given deployment (`deploymentId`). It
  runs only after the owner's OK in Log → Waiting (put there by Watch my services or `hm deploy-redeploy`).

**Sentry** (0.2.0). Every 30 minutes. Strictly **read-only**: besides sessions and crash-free rate, it reads your unresolved issues of the
last 14 days (`GET /api/0/organizations/{org}/issues/?query=is:unresolved`, up to 50) as one `issues.snapshot`
event. That needs the token's `event:read` scope; without it the issues part is skipped (noted in the add-on's log)
and the crash numbers still arrive. `hm services` ranks open issues by triage priority (non-hang crashes/uptime issues first, hangs next, and aggregate `mac-jobs-ok` rollups last) with `is_hang` and `is_aggregate` flags.

**Google Search Console.** Reads 50 top pages (by clicks) with their average position, so Next steps can name pages
that rank on Google's first page but get under half your site's own click rate.

## The folder

An add-on is a folder named `<id>.hmplugin` with two files:

```
my-service.hmplugin/
├── manifest.json
└── my-service-addon        # the program (any language; must be executable)
```

Put it in `~/Library/Application Support/Hmunmawi/Add-ons/`. Hmunmawi finds it at the next launch and shows it in Settings → Connections, waiting for your approval. Built-in add-ons live inside the app bundle and follow the same rules.

## manifest.json

```json
{
  "id": "my-service",
  "name": "My Service",
  "version": "0.1.0",
  "protocol": 1,
  "executable": "my-service-addon",
  "summary": "Reads daily signups from My Service.",
  "poll": { "everySeconds": 3600 },
  "emits": ["signups.daily"],
  "actions": ["notify"],
  "permissions": {
    "hosts": ["api.my-service.com"],
    "secrets": ["apiKey"],
    "mac": []
  },
  "settings": [
    { "key": "project", "label": "Project name", "type": "text", "required": true },
    { "key": "apiKey", "label": "API key", "type": "secret", "required": true }
  ]
}
```

| Field | Meaning |
|---|---|
| `id` | Lowercase letters, digits, dots or dashes; up to 64 characters. |
| `protocol` | Must be `1`. |
| `executable` | A file name inside the folder (no slashes). |
| `poll.everySeconds` | How often the app asks for news; at least 60. Leave `poll` out if the add-on only acts. |
| `emits` | The kinds of event it may send (exact names like `signups.daily`). Events of any other kind are dropped and noted in the activity log, so list every kind your `poll` returns. `"*"` (any kind) is allowed only for the bundled script feed. Shown to the user at approval. |
| `actions` | Names of things it can do, such as `notify`; rules can use them. |
| `permissions.hosts` | Exact host names it may call, https only. |
| `permissions.secrets` | Names of the keys it may use in requests (stored in the Keychain). |
| `permissions.mac` | Abilities only the signed app may use, such as `messages.send`. |
| `settings` | Fields shown in Settings → Connections. `type` is `text`, `number`, `toggle` or `secret`. Secret fields go to the Keychain; the others are sent to the add-on. |

Everything under `permissions`, and the `emits` list, is shown to the user before they approve the add-on. If any file in the add-on's folder changes later, the add-on waits for approval again. It runs from a read-only copy the app keeps, inside a sandbox: it can read its own folder, write only its own state folder, and has no network of its own. A link inside the folder that points outside it is refused.

## The conversation

Each message is one line of JSON. A request has an `id` and a `method`, and is answered by a message with the same `id` and either a `result` or an `error` (`{"code": "...", "message": "..."}`).

**From the app to your add-on:**

| Method | Params | Answer with |
|---|---|---|
| `initialize` | `{"settings": {...}}` (plain settings, never secrets) | `{"protocol": 1}` |
| `ping` | | `"pong"` |
| `poll` | | `{"events": [ ... ]}` (see below) |
| `act` | `{"action": "notify", "params": {...}}` | any JSON result |

**From your add-on to the app:**

| Method | Params | You get back |
|---|---|---|
| `http` | `{"method": "GET", "url": "https://api.my-service.com/...", "headers": {"Authorization": "Bearer {{secret:apiKey}}"}, "body": "..."}` | `{"status": 200, "headers": {...}, "body": "..."}` (`bodyBase64` for binary responses) |
| `mac` | `{"ability": "messages.send", "params": {...}}` | the ability's result |

Write `{{secret:NAME}}` in a header or the body wherever a key belongs; the app fills it in. The add-on never receives the value. Anything the add-on writes to standard error goes to its log file.

### Events

`poll` returns a list of events, the facts your add-on found:

```json
{
  "kind": "signups.daily",
  "app": "My App",
  "payload": { "day": "2026-11-02", "signups": 42 },
  "occurredAt": 1793577599999,
  "dedupeKey": "signups-my-app-2026-11-02"
}
```

- `kind`: what happened, as `area.what` (look at the built-in add-ons for kinds the app already understands, such as `revenue.purchase`, `review.new` or `crash.daily`).
- `app`: which of the user's apps it is about, if any.
- `occurredAt`: Unix time in milliseconds.
- `dedupeKey`: the same fact always gets the same key, so sending it twice stores it once.

## Swift: the easy way

Swift add-ons can use `HmunmawiPluginKit`, which handles the conversation:

```swift
import HmunmawiPluginKit

struct MyService: HmunmawiPlugin {
    func poll(core: Core) async throws -> [PluginEvent] {
        let r = try await core.http(HTTPRequestSpec(
            url: "https://api.my-service.com/signups",
            headers: ["Authorization": "Bearer {{secret:apiKey}}"]))
        // … read r.body and turn it into events
        return []
    }
}

await PluginRuntime.run(MyService())
```

`Tests/TestPlugin/main.swift` is a complete small example, and every folder in `AddOns/` is a real one.

## Sharing it

Publish your add-on in your own repository with build instructions. To propose it as a built-in add-on or share what you built, start a thread in [Add-ons, Scripts & MCP](https://github.com/priyevsingh/hmunmawi/discussions/categories/add-ons-scripts-mcp) first; see [CONTRIBUTING.md](../CONTRIBUTING.md).
