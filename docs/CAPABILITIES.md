# What Hmunmawi can do

This is the single canonical list of capabilities. The README, the guide, the add-on guide, release notes and the
GitHub description all point here. When a capability is added, changed or removed in the code, change it here first
and keep everything else in step (see [the docs rule](../AGENTS.md#docs-rule-keep-the-capability-list-in-sync)).

Hmunmawi tracks, plans, queues and reminds. It never posts to YouTube, Instagram, Reddit, Discord or X for you, and
anything that changes something waits for your OK. Every row can be fed by your own scripts, kept in a private
repo of yours: see [Your private workspace](PRIVATE-WORKSPACE.md).

| Area | What it does | More |
|---|---|---|
| **Apple apps** | Sales, subscriptions, reviews, ratings, releases and TestFlight; a Rejection Shield that catches what could get a version rejected; offer codes; featuring nominations; product page tests; review replies drafted for you to edit | [Guide](GUIDE.md), [Add-ons](ADD-ONS.md) |
| **Websites and search** | Visitors and AI-bot reads from Cloudflare; Google Search Console and Bing clicks, top searches and pages; a "website down" watch; next steps such as searches that have no page yet | [Add-ons](ADD-ONS.md) |
| **Social** | YouTube subscribers, views and newest videos, and Shorts plans; Instagram Reels and carousel to-dos; Reddit and Discord post ideas; X numbers, post drafts at your best hours, reply ideas and an unfollow list. Plans and drafts come from your own scripts or AI jobs | [Script feed](SCRIPT-FEED.md#post-ideas-and-to-dos), [Set up X](X-SETUP.md) |
| **Publishing** | Articles and posts you produce show up as to-dos and as jobs on the Automations map: what is due, what ran, what failed. Nothing goes out until you say so | [Routines](ROUTINES.md) |
| **Crashes and health** | Crash-free sessions from Sentry; failed Mac jobs retried; keys and certificates watched for expiry | [Add-ons](ADD-ONS.md) |
| **Money and offer codes** | Payday date, monthly forecast, profit after your costs, AI credits and plan limits, an export for your accountant; offer codes handed out one by one and watched for expiry | [AI and costs](AI-AND-COSTS.md) |
| **Alerts** | iMessage, ntfy push and an iPhone and Watch calendar, with quiet hours; told once, only if it is still true 7 minutes later | [Guide](GUIDE.md) |
| **AI limits** | Plan limits shown; the AI job pause stops your own AI scripts when you need them to wait | [AI and costs](AI-AND-COSTS.md) |
| **Autopilot with approval** | Routines on a schedule, your own scripts and Mac jobs, and agents such as Claude Code through `hm` and MCP; anything that changes something waits in Log → Waiting | [Routines](ROUTINES.md), [hm commands](HM-COMMANDS.md), [For AI agents](../AGENTS.md) |

## Built-in connections

App Store Connect, RevenueCat, PostHog, Sentry, Cloudflare, Google Search Console, Bing Webmaster Tools, YouTube, X,
Script feed, Mac jobs, iMessage and ntfy. One folder each in `AddOns/`; see [ADD-ONS.md](ADD-ONS.md).
