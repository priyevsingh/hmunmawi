<p align="center"><img src="images/icon.png" width="96" alt="Hmunmawi icon"></p>

<h1 align="center">The Hmunmawi guide</h1>

<p align="center"><b>Everything the app does for you, page by page.</b><br>
<sub>Pictures from a real developer's Mac running three live App Store apps. Money, counts, names and anything private are blurred.</sub></p>

<p align="center"><img src="images/real-today.png" width="860" alt="Hmunmawi's Today page on a real developer's Mac"></p>

<p align="center">
☀️ <a href="#today-">Today</a> &nbsp;·&nbsp; 📱 <a href="#apps-">Apps</a> &nbsp;·&nbsp; 📬 <a href="#log-">Log</a> &nbsp;·&nbsp; ⚙️ <a href="#automations-">Automations</a> &nbsp;·&nbsp; 🔔 <a href="#menu-bar-and-notifications-">Menu bar</a><br>
🎛️ <a href="#settings-">Settings</a> &nbsp;·&nbsp; 🌐 <a href="#your-own-portal-">Your own portal</a> &nbsp;·&nbsp; 🔌 <a href="#connections-">Connections</a> &nbsp;·&nbsp; 🤖 <a href="#agents-and-the-hm-command-">Agents</a>
</p>

> [!NOTE]
> Most actions come in two flavours: **Sort it for me** (Autopilot: Hmunmawi does it, after showing you the result) or
> **Show me how** (Hands-on: the steps, and you do it). Anything that changes App Store Connect or sends a message
> always waits for your OK.

> [!TIP]
> The short list of everything Hmunmawi does is in [CAPABILITIES.md](CAPABILITIES.md). To drive it with your own scripts, drafts and AI briefs, see [Your private workspace](PRIVATE-WORKSPACE.md).

---

<br>

## Today ☀️

> [!TIP]
> **What you get:** one look each morning tells you if your apps had a good day, what to worry about and what to do next, without opening App Store Connect or five dashboards.

One sentence on how things are going, the biggest win and worry, then the cards below. A **project switcher** in
the toolbar (All projects, or one project) narrows every page to that project's apps and websites.

#### ✨ Headline and moments
**Feel every sale as it happens.**

<details><summary>How it works</summary>

The latest sale, renewal, refund or review slides by at the top; a real sale also plays a short moment. Reduce Motion (System Settings) turns the animations off.

</details>

#### 📊 Money, Reach, Health
**Know in three numbers whether today is good.**

<details><summary>How it works</summary>

People paying now and 14-day earnings; how many times you were seen on Google, YouTube and Bing; crash-free sessions and anything that needs a look (developer membership, a version in review).

</details>

#### 🗂️ Your projects
**See each app or website on its own when you have several.**

<details><summary>How it works</summary>

Each project (a group of apps, or a website) with its visitors, enquiries and search numbers. Click one to see only its numbers. Set projects up in Settings → Projects.

</details>

#### 🧭 Your journey
**See where people drop off between finding you and paying you.**

<details><summary>How it works</summary>

The last 28 days from *Seen* (Google, YouTube, Bing) → *Visited* → *Saw an app* (product page) → *Downloaded* → *Paid* → *Earned*, with the share that made it to each step.

</details>

#### 👉 Next steps
**Get a concrete thing to do today, based on your own numbers.**

<details><summary>How it works</summary>

Worked out from your own numbers, no AI: search queries with no page, pages Google shows on its first page (position 10 or better, 100+ times in 28 days) that get under half your site's own click rate (rewrite the title and description), channels pulling this week, countries that look but don't download. Mark one Done and the number it should move is compared 14 days later, even after the step stops showing. Ads are suggested only above the cost per download you set in Settings → General.

</details>

#### 🔎 Search health
**See when Google, Bing or AI search stops seeing your website, and fix it from here.**

<details><summary>How it works</summary>

Each of your websites with its search health (all clear, worth a look, needs attention) and its top problems, from a `search_health.json` report your own monitor script writes. **Problems and fixes** lists every problem in plain words with the fixes your script offers: an API action or an AI code fix (run by your script; an AI fix should only open a pull request for your OK), or Safari steps you do yourself in one new tab that Hmunmawi opens on Bing Webmaster Tools or Search Console after you confirm, and closes when you are done. Hmunmawi itself submits nothing to search engines. A website project with no report shows **Choose file…**. Format and script: [Search health](PRIVATE-WORKSPACE.md#search-health).

</details>


![Your journey and Payday & profit](images/guide/today-money.png)

#### 💰 Payday & profit
**Know when Apple pays you, how much, and what's really left after your costs.**

<details><summary>How it works</summary>

Apple's next payment (from Apple's finance report; the date comes from Apple's payment calendar, so it's an estimate), this month's forecast, costs paid so far and what's really yours. *Sort it for me: Predict* asks the AI where the month will land. *Export for accountant* (the share button on the card): Apple's payouts by fiscal month, with a box for what reached your bank, saved as a CSV. Details: [AI credits, costs and profit](AI-AND-COSTS.md).

</details>

#### 🎁 Startup programs <sub>(Money page)</sub>
**See all your free credits from startup programs in one place.**

<details><summary>How it works</summary>

Credits from startup programs, approved and in review, if a script of yours sends them ([format](SCRIPT-FEED.md#startup-programs-card)). Plans and credits from a program can also be marked free, so they're listed but never counted as a cost.

</details>

#### 🧠 AI & subscriptions
**Never get surprised by an AI bill or a plan running out.**

<details><summary>How it works</summary>

Each AI plan and API credit, how much is used and when it resets, plus the App Store Connect API's hourly request budget.

</details>


![AI & subscriptions and Your week, in a story](images/guide/today-ai.png)

<sub>On the maintainer's Mac this card tracks their own Claude credits, including a monthly credit shared between a research job of their own and Hmunmawi's AI. Your card shows whatever you use: any provider, plan or credit.</sub>

#### 📖 Your week, in a story
**Share your week on X or with your team in one click.**

<details><summary>How it works</summary>

A ready-to-share summary of the week (sales, wins, worries, releases). *Polish* has the AI tidy it; *Copy* puts it on the clipboard. Share cards turn the same numbers into a picture, with money in your currency, in dollars, or both.

</details>


<br>

## Apps 📱

> [!TIP]
> **What you get:** everything about one app on one page: is the next version on its way, will it get rejected, are people staying and paying, and what they say about it.

One tab per app. At the top: reviews waiting for a reply, then **Coming soon**: every app that isn't on the App
Store yet gets its own launch track, Building → TestFlight → Submitted → In review → Live, read from App Store Connect,
so you see at a glance how close each one is to launch. An app with no new build or version for 30 days shows as one
quiet "Parked" line. (On the maintainer's Mac this strip shows unreleased apps, so it's left out of the pictures.)

![Next version, Rejection Shield and the app's numbers](images/guide/apps-release.png)

#### 🚀 Next version
**Always know exactly where your release is.**

<details><summary>How it works</summary>

Where the version in progress is: Building → TestFlight → Submitted → In review → Live, with its build and the live version.

</details>

#### 🛡️ Rejection Shield
**Catch what would get you rejected before Apple does, and fix it in a click.**

<details><summary>How it works</summary>

Before you submit, what could get the version rejected (a missing build, review contact, promotional text, What's New in a language). *Fix it for me* fixes the small things after showing you the change; *Draft it for me* writes text; **Submit for Review** only after your OK.

</details>

#### 🧹 TestFlight tidy-up
**Keep TestFlight clean without hunting through old builds.**

<details><summary>How it works</summary>

Expire old builds, or see how.

</details>

#### 🔢 The app's numbers
**See an app's health in one row.**

<details><summary>How it works</summary>

Downloads, active subscribers, crash-free rate, download-to-paid, new subscribers, monthly recurring revenue and installs. Star ratings come from a feed, or from the public App Store page (switch in General).

</details>

#### 📝 How vX did
**Find out whether your last release helped or hurt.**

<details><summary>How it works</summary>

A week after a release goes live, a report card comparing the 7 days after with the 7 before.

</details>


![Release timeline, Stability, Reviews and Offer codes](images/guide/apps-quality.png)

#### 🕒 Release timeline
**See which version changed what.**

<details><summary>How it works</summary>

Every version, when it started and went live, and what changed in the week after.

</details>

#### 🩺 Stability
**Spot a crash or freeze problem before the reviews do.**

<details><summary>How it works</summary>

Crash-free sessions per day, and freezes from Sentry (fatal hangs, and how many involve your own code rather than the system).

</details>

#### ⭐ Reviews
**Answer reviews in seconds, in your own words.**

<details><summary>How it works</summary>

The newest reviews. *Draft reply* writes a reply with AI for you to edit; sending always asks first.

</details>

#### 🎟️ Offer codes
**Hand out promo codes without a spreadsheet, and never run out by surprise.**

<details><summary>How it works</summary>

Import the offer-code CSVs App Store Connect exports (Import CSV, or *Find CSV files* in your Downloads), or *Import from a web page* for a tracker behind a login (read once through Safari, where you're already signed in). **Copy next code** copies an unused redeem link, notes who or where it went, and marks it shared, with Undo. Custom codes show their share count. The Expiry watchdog and the offer-code routine warn before codes run out or expire; a rule can text you when 20 or fewer are left.

</details>

![Offer codes: import, copy the next code, custom codes and subscription offers (codes and counts blurred)](images/guide/offer-codes.png)


![Featuring nominations, Product page tests and From website to money](images/guide/apps-growth.png)

#### 🏆 Featuring nominations
**Pitch Apple for a feature without starting from a blank page.**

<details><summary>How it works</summary>

Your App Store featuring nominations and their state. *Draft one* writes the pitch with AI; every send waits for your OK.

</details>

#### 🧪 Product page tests
**Know which store page works better.**

<details><summary>How it works</summary>

Running A/B tests and custom product pages.

</details>

#### 🔗 From website to money
**See whether your website actually brings downloads and money.**

<details><summary>How it works</summary>

The last 7 days from your website's product page → App Store taps → downloads from websites → downloads → earned.

</details>


![Still opening, Why people stop paying](images/guide/apps-paying.png)

#### 🙏 Ask for a review after a good moment
**Get more good ratings by asking at the right time.**

<details><summary>How it works</summary>

A reminder card when the numbers are going well.

</details>

#### 📈 Trends
**See the direction, not just today's number.**

<details><summary>How it works</summary>

Active subscribers, first downloads and rating over time.

</details>

#### 🔁 Still opening
**Know whether people keep using your app after day one.**

<details><summary>How it works</summary>

Day 1, 7 and 28 retention from Apple's own sample of people who share analytics.

</details>

#### 💔 Why people stop paying
**Understand why subscribers leave, so you can keep more of them.**

<details><summary>How it works</summary>

Trials, cancellations in the first week, failed payments (and how many Apple recovered), refunds, and how many are still paying by plan after 1, 3, 6 and 12 weeks.

</details>


![How people find the app, Rivals & prices](images/guide/apps-discovery.png)

#### 🔍 How people find the app
**Learn which countries and channels bring your downloads.**

<details><summary>How it works</summary>

Seen on the App Store → opened the page → downloaded, top countries, in-app events, and where first downloads came from (search, browse, app referrer, web referrer).

</details>

#### 🔭 Rivals & prices
**Keep an eye on competitors without checking their pages.**

<details><summary>How it works</summary>

Add a rival app; its rating, price and version are checked daily from Apple's public App Store data.

</details>


<br>

## Log 📬

> [!TIP]
> **What you get:** nothing slips through: every reply, follow-up and request waiting for you is in one place, and you can see exactly what happened and when.

Everything that came in, and what's waiting on you.

![Outreach, Mail replies, Planned steps, Out in the world](images/guide/log.png)

#### ✅ Needs your OK
**Approve or skip anything waiting, in one place.**

<details><summary>How it works</summary>

Every action waiting for approval (yours, a routine's or an agent's), with Approve or Skip.

</details>

#### 📣 Outreach follow-ups
**Never forget to follow up with a journalist or creator.**

<details><summary>How it works</summary>

People you pitched (press, creators, partners) whose follow-up is due. *Open outreach* shows the full list: who, for which app, when you wrote, notes, a do-not-contact mark, and replies matched from your mail. A routine can watch for replies and for coverage (new posts on their site's feed). In the outreach editor, paste the outlet's page and press **Check** before adding: Hmunmawi reads that one page and says whether it loads, whether there's an email or contact form, whether it reads paid-only ("sponsored post", "review fee"), its language, and whether the outlet is already on your list (same name, website or address; a shared mail provider like gmail.com never counts). Agents get the same with `hm outreach-check`.

</details>

#### ✉️ Mail replies
**See who answered your pitches without digging through your inbox.**

<details><summary>How it works</summary>

Replies to your outreach, from Apple Mail or any IMAP mailbox (Settings → Connections → Outreach replies). Only sender, subject and date are read, never the message.

</details>

#### 🗒️ Planned steps
**Try a change and find out if it worked.**

<details><summary>How it works</summary>

Changes you're trying (a price, a paywall line) with the date to check the result. The *judge my changes* routine compares before and after.

</details>

#### 🌍 Out in the world
**Know when Apple is down, what Apple announced, and who's talking about you.**

<details><summary>How it works</summary>

Apple's system status, Apple developer news, and mentions of your apps on Hacker News, Bluesky and your GitHub repo.

</details>

#### 🧾 Every step, newest first
**See exactly what happened and who did it.**

<details><summary>How it works</summary>

The signed activity log of everything Hmunmawi, its routines and agents did.

</details>


<br>

## Automations ⚙️

> [!TIP]
> **What you get:** the chores run themselves, and you can see at a glance that they all ran today, or which one needs you.

![Who runs what, and Your Mac's day](images/guide/auto-day.png)

#### 🗺️ Who runs what
**See every automation on one map, and which one failed.**

<details><summary>How it works</summary>

Every routine, Mac job and bot on one map: where its data comes from, who works on it (your Mac, your bot, the cloud, you) and where the result lands. A dot shows what happened today. Click one to open it: Run now, Pause, Show log. Each of these asks first unless you allowed it. Jobs Hmunmawi can't see by itself (a script's own scheduler, a cloud job) can join the map through a small job list file ([format](PRIVATE-WORKSPACE.md#job-list-format)).

</details>

#### 🕰️ Your Mac's day
**See at a glance that today's jobs ran.**

<details><summary>How it works</summary>

A 24-hour strip of every run today, and what runs next.

</details>


![This week, Expiry watchdog, Always on](images/guide/auto-week.png)

#### 📅 This week
**Plan the week's recurring work once and forget it.**

<details><summary>How it works</summary>

The weekly routines, day by day. **+** adds a routine. Kinds include reminders, website watch, offer-code expiry, AI briefs on your numbers, post drafts from your bank, outreach follow-ups and replies, keys that stop working, judging your changes, your own scripts and your Mac's jobs. A routine can also put its message in a calendar named "Hmunmawi", so it reaches your iPhone and Watch. Post drafts skip weak drafts and follow X's published algorithm by themselves ([how](ROUTINES.md#post-drafts-that-follow-xs-algorithm)). Full list: [Routines](ROUTINES.md).

</details>

#### 𝕏 Your X, on autopilot (you still post)
**Show up in the right conversations every day, with or without Grok Bot.**

<details><summary>How it works</summary>

*X reply ideas* and *X unfollow list* ask **who reads X**: Grok Bot (it reads and searches X for free), or Hmunmawi itself through your signed-in Safari, read-only. Without Grok Bot or an AI key, replies are drafted **free by Apple's on-device AI**: nothing leaves your Mac. You always post and reply yourself; unfollows are by hand from the list, or, if you add **X unfollows (automatic)**, a few a day done for you in your Safari (off by default, capped, stops at any sign of trouble). Set it up: [Set up X](X-SETUP.md).

<table><tr>
<td width="50%" align="center"><b>🤖 With Grok Bot</b><br><img src="images/guide/x-reply-ideas-grok.png" alt="X reply ideas with Grok Bot"></td>
<td width="50%" align="center"><b>🧭 Without Grok Bot</b><br><img src="images/guide/x-reply-ideas-ondevice.png" alt="X reply ideas via Safari with Apple's on-device AI"></td>
</tr></table>

Your X at a glance, on the X card (Today → Reach → X):

<p align="center"><img src="images/guide/x-glance.png" width="480" alt="X card glance, numbers blurred"></p>

When and how Apple's on-device AI is used: [Apple's on-device AI](AI-AND-COSTS.md#apples-on-device-ai).

</details>

#### ⏳ Expiry watchdog
**Never get caught by an expired certificate or domain.**

<details><summary>How it works</summary>

Certificates, provisioning profiles, keys with an end date and domains, with days left. Under the slider button, **Plans and trials**: type a service, the day its trial ends or its plan renews, and an optional note (for example "set pay-as-you-go to $0"); it's reminded like a certificate, by your expiry rules. Vendors rarely share these dates through an API, so you type them once (agents: `hm plan-add`).

</details>

#### 💚 Always on
**Know that the things that must keep running, are.**

<details><summary>How it works</summary>

Helpers that should never stop (a relay, a local server), with safety nets and what happens if one fails.

</details>


<br>

## Menu bar and notifications 🔔

> [!TIP]
> **What you get:** you hear about a sale, a bad review or a broken build the moment it matters, and nothing else.

- An **H** in the menu bar with a health dot (green, amber, red, grey), an optional number (sales, downloads,
  reviews, things waiting for you, or things to fix), and a panel with today's headline, connections, the latest
  moments, approvals and quick numbers.

#### 🔔 Notifications
**Hear about what matters, and only that.**

<details><summary>How it works</summary>

For new purchases and renewals, refunds, 1- and 2-star reviews, other reviews, build and review changes from Apple, a connection that stops working, and a rating that drops (by the amount you choose). Grouped per app, held during quiet hours, at most 6 an hour; a problem only if it's still there 7 minutes later. The whole path as a picture: [How an alert reaches you](CAPABILITIES.md#how-an-alert-reaches-you).

</details>

#### 🤫 Pause notifications
**Get quiet when you need to focus.**

<details><summary>How it works</summary>

For 1 hour, until tomorrow, or until you switch them on. *Send a test notification* checks the setup.

</details>


![Menu bar settings: notifications](images/guide/set-menubar-01.png)

<br>

## Settings 🎛️

> [!TIP]
> **What you get:** it works your way: your currency, your quiet hours, your AI (or none), your backups.

#### 🧩 General
**Make it behave exactly the way you like.**

<details><summary>How it works</summary>

**Keep this Mac awake for routines** (Off, While plugged in, Always; off by default): stops idle sleep while Hmunmawi runs, so routines and Mac jobs run on time; the screen still sleeps and closing a laptop's lid still sleeps the Mac. **Words I never use**: one word or phrase per line, then `|` and why (optional); `re:` starts a pattern. Post drafts and reply ideas that use one are skipped, the drafting AI is told to avoid them, and scripts and agents check any text with `hm lint-text`. Rating-drop alerts, star ratings from the public App Store page, a warning at 80% of a service's request limit, quiet hours, the weekly digest, the add-on sandbox, and fix scripts that run by themselves when a problem appears (they wait for a new OK if the file changes).

</details>

![General: alerts, quiet hours, digest, sandbox, fix scripts](images/guide/set-general-01.png)

<details><summary>More in General: appearance, currency, export, AI</summary>

Appearance, the currency money is shown in, the ad cost per download, **Export your data** (reviews, daily numbers or every event, as CSV or JSON, as far back as you choose), and **AI wording**: pick a provider (Claude, OpenAI, Gemini, OpenRouter, Groq, Mistral, Ollama or any OpenAI-compatible service), a model and your key. Everything works without AI. What AI writes, the monthly limit and Apple's free on-device model: [Use any AI model, or none](AI-AND-COSTS.md#use-any-ai-model-or-none).

</details>

![General: export and AI](images/guide/set-general-02.png)

#### 🔑 Connections
**Plug in every source once, safely.**

<details><summary>How it works</summary>

One section per source, keys saved in the Keychain, *Find my key*, Check Now and Disconnect. A key that was found from a file is re-imported from that file at launch, in the background after the window is up, so a protected folder never freezes the start; if macOS refuses the file, only that connection is marked as needing attention. A key saved by a differently signed copy of the app is re-saved in a fresh Keychain item, with no password box. Also **how fast sales arrive**: next morning (Apple's daily report), within minutes (Apple's notification history, with an In-App Purchase key) or within seconds (a free worker in your own Cloudflare account, see [the relay guide](ASC-WEBHOOK-RELAY.md)), and **Outreach replies** (Apple Mail, or IMAP with presets for Gmail, iCloud, Outlook and Fastmail).

</details>

![Connections](images/guide/set-connections-00.png)

#### 🗂️ Projects
**Look at each product on its own.**

<details><summary>How it works</summary>

Group apps into a project or add a website (visitors, enquiries, search); the toolbar switcher uses these.

</details>

#### 🎚️ Jobs
**Turn a job or a channel on or off with one tap, no code.**

<details><summary>How it works</summary>

The on/off switches your own scripts read, from a small JSON file in your workspace: each channel (Reddit, Discord, Instagram, YouTube Shorts, X), Instagram details (post suggestions, new carousels, warm-up sessions), "account warmed up" per platform (on = no warm-up steps, only real post ideas), and any other true/false your file has. Each switch has a one-line explanation. Hmunmawi changes only the value you flip, writes the file atomically and keeps every other key and note as it was; your scripts see the change on their next run. Every flip is written to the activity log. No file yet? The tab says how to add one, or press **Choose…**. To stop a whole scheduled Mac job instead, use **Pause** on its row in Automations. File format: [Job switches](PRIVATE-WORKSPACE.md#job-switches).

At the top, **Run by Hmunmawi** lists the jobs Hmunmawi itself runs for you: X unfollows (automatic), Watch my services, Mac-alive heartbeat (Sentry), Check links on my site and Check my workspace Python. Each shows "Not set up" until you add it in Automations → +, then an on/off switch with when it runs and its last result. Nothing there deploys, repairs or posts without your OK.

</details>

#### ⚡ Rules
**It reacts to events the way you would.**

<details><summary>How it works</summary>

"when this happens, do that", in plain sentences, each Hands-on, Try out or Autopilot. Ready-made rules by group: money moments (new subscriber, refund, billing problem), trends, reputation (low reviews), stability, AI & subscriptions, offer codes, releases (TestFlight feedback, an expiring certificate, a failed Xcode Cloud build), the weekly story, Mac jobs and your website going down.

</details>

![Rules: ready-made rules](images/guide/set-rules-01.png)

#### 🔐 Permissions
**Grant everything once, never mid-task.**

<details><summary>How it works</summary>

Every Mac permission Hmunmawi can use, why, and whether it's allowed, with *Check again*. Asked once at setup, never in the middle of a run. If the app is signed differently from the last launch (a development build, the release build or a new certificate), a banner here, and the activity log, name exactly which permissions to switch on again (Full Disk Access, Files & Folders, Calendars, Accessibility, Automation), because macOS ties each grant to the signature. *Got it* dismisses the banner.

</details>

![Permissions](images/guide/set-permissions-00.png)

#### 🌐 Publish
**Your numbers on the web, your way.**

<details><summary>How it works</summary>

See [Your own portal](#your-own-portal-) below.

</details>

#### 🛟 Backups
**Never lose your history.**

<details><summary>How it works</summary>

Daily copies on your Mac with Restore, *Back up now*, an encrypted iCloud Drive copy with its **recovery code** (save it in your password manager; without it the copy can't be opened on another Mac), *Bring back*, and *Fetch everything again* (re-reads up to 70 days from your sources; duplicates are skipped).

</details>

![Backups](images/guide/set-backups-01.png)

#### 💜 About
**Who made it, and the Wall of Apps.**

<details><summary>How it works</summary>

Version, the story, and the [Wall of Apps](WALL-OF-APPS.md).

</details>

<br>

## Your own portal 🌐

Hmunmawi lives on your Mac, but you don't. The portal is how your numbers come with you: Hmunmawi publishes
them as **one self-contained web page** that opens in any browser, so you can check how your apps are doing from
your iPhone on the train, your iPad on the sofa, or a friend's laptop, without the app.

**Why you'd use it**

- **Your numbers anywhere:** Host it once (Cloudflare Pages or Netlify are free) and bookmark it, or add it to your
  iPhone's Home Screen. It looks right on a phone and follows light or dark mode.
- **Share without sharing your Mac:** Give your co-founder, team or investors one link instead of App Store Connect
  access or screenshots. Put it behind a login (for example Cloudflare Access) so only they can open it.
- **Build in public:** Switch on *Safe to show anyone* and the same page becomes a public "open startup" page with
  downloads, ratings and growth, but no money.
- **Always current, no server of ours:** With *Publish again after each refresh*, the page on your Mac is rewritten
  every time Hmunmawi checks your sources, and your own upload command puts it online (at most every 2 hours when it
  runs by itself, or right away with *Publish now*). Your Mac does the work; nothing goes through us.

Good to know: the page is only as fresh as your Mac's last publish. If your Mac is asleep or off, the page shows the
last numbers it published, with the time at the top.

![A published portal (numbers blurred)](images/guide/portal.png)

It follows the viewer's light or dark setting (shown here in dark), in the same colours as the app: money in greens, reach in blues,
health in purples, people in oranges.

**One tap on the menu opens every section,** so on a phone you jump straight to what you want:

<p align="center"><img src="images/guide/portal-menu.png" width="820" alt="The published portal's menu, open, listing every section"></p>

| | | |
|---|---|---|
| ![Earnings, lifetime access, store](images/guide/portal-more-a.png) | ![Trends, X, YouTube](images/guide/portal-more-b.png) | ![Outreach, attention, startup programs, account](images/guide/portal-more-c.png) |
| Earnings by month, lifetime access, the App Store | Rating trends, X, YouTube | Outreach, attention, startup programs, developer account |

**Your X, the same way as in the app:** followers and their trend, the week's numbers, your X at a glance (pinned
post, latest article, taking off, top replies) and the last 24 hours of posts and replies, in the same colours and
type as the hub portal's X card. A public copy leaves out the post feed and the names of people you replied to.

<p align="center"><img src="images/guide/portal-x.png" width="760" alt="The published portal's X section, with example numbers"></p>
<p align="center"><sub>Example numbers.</sub></p>

**On a phone, like your hub portal:** the menu bar stays on top, and round **↓ / ↑** buttons at the bottom right
jump to the end or back to the top (each shows only when it would move you).

<table><tr>
<td width="50%" align="center"><img src="images/guide/portal-phone-top.png" width="300" alt="Published portal on a phone: menu bar and the jump-to-bottom button"></td>
<td width="50%" align="center"><img src="images/guide/portal-phone-x.png" width="300" alt="Published portal on a phone: X section and the back-to-top button"></td>
</tr></table>

#### 📄 What's on it
**One page with everything that matters, readable on any screen.**

<details><summary>How it works</summary>

At a glance (the week's biggest moves), today, money, every app's downloads, health, this week, from website to money, users, retention, website traffic and languages, **Google Search and Bing (times seen, clicks, position; the queries people typed stay out of a public copy), earnings by month since launch, lifetime access per app, the App Store (conversion, countries, install sources), subscribers and plans, rating trends, X, YouTube, outreach follow-ups, what needs attention, startup programs, your developer account** and the latest events. Each section appears only when its data exists. You tick each section in Settings → Publish; new sections from a new connection are added until you switch them off.

</details>

#### 🙈 Safe to show anyone
**Share your progress publicly without revealing your income.**

<details><summary>How it works</summary>

Leaves out every money amount, the sales list and the problem list, for a public page.

</details>

#### 📁 Where it goes
**Keep a fresh copy every day, with a week of history.**

<details><summary>How it works</summary>

A folder on your Mac (you choose it). *Publish now*, or *Publish again after each refresh* to keep it current. A dated copy is kept for the last 8 days, linked at the bottom as "Earlier copies". Sample numbers are never published.

</details>

#### ☁️ Hosting is yours
**Put it online where you like, in one step you approve.**

<details><summary>How it works</summary>

Add an upload command and Hmunmawi runs it in the portal folder after each publish. The Examples menu fills one in for **Cloudflare Pages** (`npx wrangler pages deploy`) or **Netlify** (`npx netlify deploy`); any copy command of your own works too (the folder's path is in `$HM_PORTAL_DIR`). The command runs only after you approve its exact text, gets none of Hmunmawi's keys (your tool uses its own login), stops after 2 minutes and runs at most every 2 hours on its own. Protect a hosted page with a login unless it's safe to show anyone.

</details>


![Settings → Publish](images/guide/set-publish-00.png)

### What a full portal can look like: the maintainer's setup

On the maintainer's Mac the same sources also feed a larger private portal, built with their own scripts on top of
Hmunmawi's data (it isn't part of the app; it shows how far the idea goes). Numbers and private names are blurred.

**The menu opens every section in one tap:** Today, Lifetime free, Apps, Subscribers, Users, X, YouTube, Outreach,
Earnings, This week, Money, Store, Retention, Trends, Website & search, Social warm-up (optional, for new accounts only; hidden once an account is warmed up), Attention, Startup programs,
Account and the Automation map.

<p align="center"><img src="images/guide/hub/menu.png" width="820" alt="The portal's menu, open, with every section"></p>

| | |
|---|---|
| ![Lifetime earnings, today, yesterday at a glance](images/guide/hub/p-00.png) | ![Apps](images/guide/hub/p-06.png) |
| Lifetime earnings, today (live) and yesterday at a glance | Each app's week |
| ![App Store funnel and install sources](images/guide/hub/p-08.png) | ![Startup programs](images/guide/hub/p-27.png) |
| App Store product page, install sources, countries | Startup programs and free credits |
| ![Six-week trends](images/guide/hub/p-14.png) | ![X](images/guide/hub/p-15.png) |
| Six-week trends: rating, users, crash-free, rivals | X: impressions, engagement, followers, last 24 hours |
| ![Website health](images/guide/hub/p-17.png) | ![AI assistants reading the site](images/guide/hub/p-18.png) |
| Website speed, devices and countries (Cloudflare) | AI assistants reading the site |
| ![Languages](images/guide/hub/p-20.png) | ![Monthly earnings](images/guide/hub/p-26.png) |
| Website languages and what's next | Monthly earnings since launch |

#### 𝕏 X, on the maintainer's own portal

How the X features in this guide look on the maintainer's device every day: the week's impressions, engagement and
followers against last week, the **Last 24 hours** feed of every post and reply (Grok Bot's free reads and the Safari
read), and **X at a glance**: pinned article, a post taking off, top replies. Hmunmawi's published portal mirrors this
card ([above](#your-own-portal-)). Numbers and post texts are blurred.

<p align="center"><img src="images/guide/hub/p-15.png" width="820" alt="The maintainer's hub portal X card: week's numbers, last 24 hours, pinned and top replies (blurred)"></p>

#### 📲 What reaches the maintainer's phone

**Every important moment arrives as an iMessage, without opening anything.**

On the maintainer's Mac, their own scripts send short iMessages through the Mac: a purchase or renewal the moment
Apple reports it, AI usage warnings (80% of a session, 90% of the week) and when AI jobs pause and resume, and a
daily digest of the numbers. These come from the maintainer's scripts, not from Hmunmawi itself. They show what you
can wire up with your own scripts next to the app.

| Purchases and AI limits | The daily digest |
|---|---|
| ![Purchase and renewal alerts, AI usage warnings, AI jobs paused and resumed (amounts blurred)](images/guide/hub/imessage-alerts.png) | ![The daily digest: downloads, search, AI assistants and languages over 7 days (numbers blurred)](images/guide/hub/imessage-digest.png) |

One of those scripts also sends a **Messages sent to you** card to Hmunmawi through the [script feed](SCRIPT-FEED.md),
so the Log page shows how many messages arrived each day, how many waited for quiet hours, and what kind they were:

![Messages sent to you, a card added by the maintainer's own script](images/guide/hub/messages-card.png)

<details><summary>What Hmunmawi itself can send</summary>

Out of the box, Hmunmawi alerts you through **Mac notifications**, **iMessage** (to your own number, when a rule
says so), **ntfy** (push notifications to any phone, Android included, through the free ntfy app) and a
**Hmunmawi calendar** that reaches your iPhone and Watch. Telegram, WhatsApp or Slack aren't built in; a connection
that can `notify` can add any of them ([Writing a connection](ADD-ONS.md)).

</details>

<br>

## Connections 🔌

> [!TIP]
> **What you get:** every number you care about, from App Store Connect to your website and X, in one app, with your keys never leaving your Keychain.

| Connection | What it brings | You need |
|---|---|---|
| App Store Connect | Sales, payouts, subscriptions, reviews, ratings, versions, TestFlight, Xcode Cloud builds, offer codes, nominations, product page tests, certificates and profiles | An API key (Admin role) and your vendor number |
| RevenueCat | Active subscriptions, trials, MRR and 28-day revenue | A read-only key |
| PostHog | People using your app each day | Project ID and a personal key |
| Sentry | Crash-free sessions and freezes; with the `event:read` scope, your open problems (crashes, Sentry Uptime, Sentry Crons) for Watch my services | Organization, auth token |
| Google Search Console | Google searches, clicks and pages | A service-account key |
| Bing Webmaster Tools | Bing searches, clicks and pages | An API key |
| YouTube | Views, subscribers and newest videos | An API key, or the Google sign-in file your own upload scripts already use (client id, client secret and refresh token) |
| X | Your X numbers, read through your Safari login or from a file Grok Bot writes (no paid X API). Full setup with drafts, reply ideas and unfollows (by hand or automatic): [Set up X](X-SETUP.md) | Nothing |
| Cloudflare | Website visitors and AI-bot reads | An API token |
| Vercel | Website visitors and page views (Web Analytics), which commit production runs, and whether your branch has a newer one that never got a deploy; Redeploy only after your OK | Project name or ID, an access token; optional Team ID, GitHub repository and a read-only GitHub token for a private repo |
| Mac jobs | Your Mac's scheduled jobs: runs, failures, Run now and Pause | Nothing |
| Script feed | Any numbers your own scripts print: [Your own numbers](SCRIPT-FEED.md) | Nothing |
| iMessage, ntfy | Alerts to your phone | Your number, or an ntfy topic |

Beyond these, the **Script feed** and **Mac jobs** connections are how everything else you run reaches Hmunmawi: a YouTube Shorts plan, Instagram Reels and carousels, Reddit and Discord post ideas, X posts, articles or a research job each appear as a card or a job on the Automations map, with a to-do when something needs you. Hmunmawi tracks, queues and reminds; anything that posts or changes something waits for your OK. See [Your own numbers](SCRIPT-FEED.md#post-ideas-and-to-dos).

Each runs as a separate sandboxed add-on that never sees your keys. Write your own: [Writing a connection](ADD-ONS.md). They check in on their own clock: Mac jobs every 5 minutes, the script feed every 10, X every 30, App Store Connect every hour, Vercel every 15 minutes (visitors every 3 hours), Sentry every 30 minutes, Cloudflare, PostHog and RevenueCat every 3 hours, Search Console, Bing and YouTube every 6 hours, and ntfy every 6 hours (only to see it answers).

<br>

## Agents and the `hm` command 🤖

> [!TIP]
> **What you get:** your AI coding agent can check your numbers and do the busywork for you, but nothing changes without your OK.

Claude Code, Cursor and other agents use Hmunmawi through the `hm` command or its MCP server, under the same
approval rules as you. Settings → Rules → Agents chooses what an agent may do without asking, and gives it a badge.
Every command: [hm commands](HM-COMMANDS.md). Notes for coding agents: [AGENTS.md](../AGENTS.md).

![Rules: agents](images/guide/set-rules-00.png)
