# The X file

Hmunmawi never calls X's paid API. **The easiest way:** let Hmunmawi read your own X page through your Safari login
(Settings → General → X numbers → *Read via your Safari login*); it writes this file for you. Full X setup: [X-SETUP.md](X-SETUP.md).

Otherwise: Its X row reads a small JSON file that Grok Bot, or **your own** script or scheduled job,
writes on your Mac (for example a read of your own signed-in X profile). No file set = X stays off; nothing breaks.

Set the file in **Settings → General → X** (or in the X connection's own setting). Hmunmawi checks it every 30 minutes
and calls it fresh for 8 hours after `generated`.

```json
{
  "generated": "2026-11-10T09:50:00Z",
  "account": { "username": "example", "followers": 1234 },
  "followers_delta_1d": 5,
  "posts": [
    { "type": "post", "text": "Shipped 1.0", "url": "https://x.com/example/status/1",
      "created_at": "2026-11-10T08:00:00Z", "impressions": 900,
      "likes": 12, "replies": 2, "reposts": 1, "quotes": 0, "bookmarks": 3 }
  ],
  "totals_7d": { "posts": 9, "impressions": 15000, "likes": 140, "replies": 20, "reposts": 11 },
  "plan": { "name": "Premium", "price": "$8 a month", "renews": "2026-12-01" },
  "glance": {
    "pinned": { "title": "How I price my apps", "kind": "article", "url": "https://x.com/example/status/2",
                "views": 600, "likes": 5, "replies": 3 },
    "latest_article": { "title": "How I price my apps", "url": "https://x.com/example/status/2", "views": 600 },
    "articles": [ { "title": "How I price my apps", "url": "https://x.com/example/status/2", "views": 600 } ],
    "taking_off": null,
    "taking_off_reason": "Nothing yet: your best post this week has 47 views; taking off means 73.",
    "top_replies": [ { "to": "@someone", "url": "https://x.com/example/status/3", "views": 1200 } ]
  }
}
```

**`glance`** (optional) is your X at a glance, shown on the X card and your portal: your pinned posts/articles (`pinned` / `pinned_items`), all your X Articles (`articles` and `latest_article`), a post that's taking off (one of this week's posts with at least 3× your average views, over at least 3
posts) or why none is, and your two most-viewed replies of the last 7 days. The Safari read fills it in for you;
Grok Bot may write it too, either inside this file or as its own file with the same fields (set it under Settings →
General → X numbers → *X glance file*, or `hm set key=x.glance_file`); when both exist, the newer `updated` wins. Only `https://x.com/<handle>/status/<id>` links are kept; anything else is dropped.

- Every field except `account.followers` is optional. A missing number is shown as "not in the file", never as 0.
- `type` is `post` or `reply`. Times are ISO 8601 (UTC or with an offset).
- The file must be under 5 MB. It is read only; Hmunmawi never writes to it.
- If the file sits at `<folder>/x/native.json`, a `<folder>/out/digest/morning_digest.json` with an `"x"` block is
  used as a fallback (for setups whose scripts write a daily digest; most people can ignore this).
