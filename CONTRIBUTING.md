# Contributing to Hmunmawi

Thanks for wanting to help. Hmunmawi is maintained by one person, in their own time, so please read this first. It saves us both a lot of back and forth.

## What's welcome

- **Bug reports** with steps to reproduce, your macOS version and what you expected.
- **Small fixes**: a crash, a wrong number, a typo, a layout that breaks at some window size.
- **New add-ons** for services Hmunmawi doesn't connect to yet. See [docs/ADD-ONS.md](docs/ADD-ONS.md). An add-on can also live in your own repository; you don't need it merged here to use it.

## Please ask first

Open an issue with the **Idea or question** form ([new issue](../../issues/new/choose)) before starting on:

- a new screen or a redesign of an existing one,
- a new dependency (Hmunmawi's only one outside Apple's frameworks is Sparkle, for updates; that's on purpose),
- anything that sends data somewhere new or reads files it didn't read before,
- large refactors.

A short conversation up front avoids a pull request that can't be merged.

## How decisions are made

The maintainer reviews and merges every change and decides what goes in and where the project is heading. A "no" or "not now" isn't a judgement on your work; it usually means the change doesn't fit the app's one job: a calm daily answer to "what now?".

Replies come when there is time. If something is urgent (a security problem), use [SECURITY.md](SECURITY.md).

## Making a change

1. Fork the repository and create a branch.
2. Build and test:
   ```sh
   swift test
   scripts/make-app.sh debug && open build/Hmunmawi.app
   ```
3. Keep the change focused: one fix or feature per pull request.
4. Add or update tests in `Tests/HmunmawiCoreTests` when you change logic in `HmunmawiCore`.
5. Check the app in both light and dark appearance (Settings → General → Appearance) and at a small and a large window size.
6. Open the pull request and describe what changed and how you checked it.

### Docs

Every docs, README, release-note or GitHub description update must check and keep the full capability list in sync (Apple apps, websites and search, social: YouTube Shorts, Instagram Reels and carousels, Reddit, Discord, X; publishing; crashes; money and offer codes; alerts; AI limits; autopilot with approval). Never under-sell or drop a capability; verify claims against the code. The single canonical list is [docs/CAPABILITIES.md](docs/CAPABILITIES.md); other docs point to it.

### Style

- Swift 6, strict concurrency. Slow work (files, network, databases) stays off the main thread.
- Plain words on screen: say what happened and what to do, no jargon or codes.
- Secrets never go into logs, files, UserDefaults, URLs or error messages.
- Comments explain *why*, not what the next line does.

### Useful launch options for development

```sh
open build/Hmunmawi.app --args -HMPage Apps           # open on a page: Today, Apps, Log, Automations
open build/Hmunmawi.app --args -HMAppearance dark     # light or dark for one launch
open build/Hmunmawi.app --args -HMScrollY 0.8         # start the Today page scrolled (for screenshots)
open build/Hmunmawi.app --args -HMStyleBoard YES      # developer design boards (never shown to users)
```

`scripts/uitest/ax.swift` lists and presses the app's buttons through the Accessibility API, and `scripts/uitest/allow-prompts.swift` answers Hmunmawi's own permission prompts after a rebuild. Both need Accessibility permission for your terminal.

## Sign your commits (DCO)

Every commit needs a `Signed-off-by` line, which says you wrote the change or otherwise have the right to submit it under the project's licence (the [Developer Certificate of Origin](https://developercert.org)):

```sh
git commit -s -m "Fix the refund count on the Today page"
```

Pull requests without it can't be merged. Edits made in GitHub's web editor can add it for you.

## What happens to your pull request

1. **Checks run by themselves** (GitHub Actions): the app is built and every Swift test runs on a macOS 26 Mac,
   the live-sales worker's tests run on Linux, every commit is checked for a sign-off (not needed for a Wall of Apps entry, or for Dependabot), and a change to the Wall of
   Apps is checked against the App Store. If you're new here, the checks start after the maintainer approves the run.
2. **A green pull request gets reviewed.** The maintainer may ask for changes; push them to the same branch and the
   checks run again.
3. **Merging** needs every check green and the maintainer's approval.
4. **Releases** are built, signed and notarized by the maintainer on their own Mac (the signing certificate never
   goes to GitHub), so a merged change reaches users in the next release.

Run the same checks before you push: `swift test`, and for the worker `cd Tests/Worker && npm ci && npm test`.

## Licence

By contributing you agree that your contribution is licensed under the [Apache License 2.0](LICENSE), like the rest of the project.

## Code of conduct

Be kind and assume good intent. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
