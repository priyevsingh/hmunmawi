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
| Sentry | Sessions and crashes each day (crash-free rate) |
| Cloudflare | Website visitors each day |
| Google Search Console, Bing Webmaster Tools | Search clicks, impressions, top searches and pages |
| YouTube | Subscribers, views and newest videos |
| X | Followers, views and engagement from your daily X file; no key needed |
| Script feed | Anything your own scripts print: numbers, plans and to-dos for Shorts, Reels, carousels, Reddit, Discord, X posts and articles ([how](SCRIPT-FEED.md#post-ideas-and-to-dos)) |
| Mac jobs | Your scheduled Mac jobs: runs, failures, Run now and Pause |
| iMessage, ntfy | Alerts to your phone |

Hmunmawi tracks, plans, queues and reminds. It never posts to YouTube, Instagram, Reddit, Discord or X for you, and anything that changes something waits for your OK.

The Search Console and Bing add-ons only read: submitting pages or sitemaps to search engines is left to your own scripts. A few things are fed without an add-on, through files your scripts write: the Search health card, job lists on the Automations map, AI usage and the X file. See [Hand-off files](PRIVATE-WORKSPACE.md#hand-off-files).

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

Publish your add-on in your own repository with build instructions. To propose it as a built-in add-on, open an issue with the **Idea or question** form first; see [CONTRIBUTING.md](../CONTRIBUTING.md).
