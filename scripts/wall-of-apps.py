#!/usr/bin/env python3
"""The Wall of Apps, built from docs/wall-of-apps.json.

  wall-of-apps.py --check   validate every entry against Apple's public App Store lookup (used on pull requests)
  wall-of-apps.py --build   save icons, draw docs/wall/mosaic.png, write docs/WALL-OF-APPS.md and the README block
  wall-of-apps.py --since YYYY-MM-DD   print thank-you lines for apps that joined since that day (release notes)
  --root DIR                work on another copy of the repo (tests)

--build needs Pillow (pip install pillow). Nothing here needs a key; the lookup is Apple's public iTunes API.
"""
import argparse, html, io, json, pathlib, re, sys, time, urllib.request

MAX_TILES = 48          # the mosaic shows the newest apps; past this, the last tile says "+N more"
COLUMNS = 12
TILE, GAP, RADIUS, SCALE = 64, 14, 15, 2      # points; drawn at 2x for sharp screens


def load(root):
    p = root / "docs/wall-of-apps.json"
    text = p.read_text() if p.exists() else "[]"
    return json.loads(text or "[]")


def app_id(e):
    if e.get("id"):
        return str(e["id"])
    m = re.search(r"id(\d{6,12})", e.get("link", ""))
    return m.group(1) if m else None


def lookup(ids):
    """Apple's public lookup for up to 150 ids at a time -> {id: result}."""
    out = {}
    for i in range(0, len(ids), 150):
        url = "https://itunes.apple.com/lookup?id=" + ",".join(ids[i:i + 150])
        for attempt in range(3):
            try:
                with urllib.request.urlopen(url, timeout=30) as r:
                    for res in json.load(r).get("results", []):
                        out[str(res.get("trackId"))] = res
                break
            except Exception:
                if attempt == 2:
                    raise
                time.sleep(3)
    return out


def check(root):
    apps, problems = load(root), []
    if not isinstance(apps, list):
        print("docs/wall-of-apps.json must be a list"); return 1
    seen = set()
    for n, e in enumerate(apps, 1):
        name = e.get("app", f"entry {n}")
        for f in ("app", "link", "icon"):
            if not isinstance(e.get(f), str) or not e[f].strip():
                problems.append(f"{name}: missing {f}")
        if not str(e.get("link", "")).startswith("https://apps.apple.com/"):
            problems.append(f"{name}: link must be an apps.apple.com address")
        if not re.match(r"^https://[a-z0-9-]+\.mzstatic\.com/", str(e.get("icon", ""))):
            problems.append(f"{name}: icon must be Apple's own App Store image address (https://…mzstatic.com/…)")
        if e.get("added") and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", e["added"]):
            problems.append(f"{name}: added must be YYYY-MM-DD")
        extra = set(e) - {"app", "link", "icon", "id", "developer", "added"}
        if extra:
            problems.append(f"{name}: unknown fields {sorted(extra)}")
        i = app_id(e)
        if not i:
            problems.append(f"{name}: no App Store id in its link"); continue
        if i in seen:
            problems.append(f"{name}: listed twice")
        seen.add(i)
    if not problems and seen:
        found = lookup(sorted(seen))
        for e in apps:
            i = app_id(e)
            if i not in found:
                problems.append(f"{e.get('app')}: not a live App Store app (id {i})")
    for p in problems:
        print("✗", p)
    print(f"{len(apps)} entries checked, {len(problems)} problem(s)")
    return 1 if problems else 0


def fetch_icon(root, e):
    """Saves the icon once as docs/wall/icons/<id>.png (128 px), so the mosaic never depends on Apple's URL later."""
    from PIL import Image
    i = app_id(e)
    dest = root / "docs/wall/icons" / f"{i}.png"
    if dest.exists():
        return dest
    url = re.sub(r"/\d+x\d+bb\.(jpg|png)$", "/256x256bb.png", e["icon"])
    with urllib.request.urlopen(url, timeout=30) as r:
        img = Image.open(io.BytesIO(r.read())).convert("RGBA").resize((TILE * SCALE, TILE * SCALE), Image.LANCZOS)
    dest.parent.mkdir(parents=True, exist_ok=True)
    img.save(dest, optimize=True)
    return dest


def mosaic(root, apps):
    from PIL import Image, ImageDraw, ImageFont
    shown = apps[:MAX_TILES]
    more = len(apps) - len(shown)
    if more > 0:
        shown = shown[:-1]          # the last tile becomes "+N more"
        more += 1
    tiles = len(shown) + (1 if more > 0 else 0)
    cols = min(COLUMNS, max(tiles, 1))
    rows = (tiles + cols - 1) // cols
    t, g, rad = TILE * SCALE, GAP * SCALE, RADIUS * SCALE
    w, h = cols * t + (cols - 1) * g, rows * t + (rows - 1) * g
    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))     # transparent: reads well in light and dark mode
    mask = Image.new("L", (t, t), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, t - 1, t - 1), rad, fill=255)
    for k, e in enumerate(shown):
        icon = Image.open(fetch_icon(root, e)).convert("RGBA").resize((t, t))
        x, y = (k % cols) * (t + g), (k // cols) * (t + g)
        canvas.paste(icon, (x, y), mask)
    if more > 0:
        k = len(shown)
        x, y = (k % cols) * (t + g), (k // cols) * (t + g)
        tile = Image.new("RGBA", (t, t), (0, 0, 0, 0))
        ImageDraw.Draw(tile).rounded_rectangle((0, 0, t - 1, t - 1), rad, fill=(120, 120, 128, 70))
        font = None
        for f in ("/System/Library/Fonts/SFNSRounded.ttf", "/System/Library/Fonts/SFNS.ttf",
                  "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"):
            try:
                font = ImageFont.truetype(f, t // 4); break
            except Exception:
                pass
        d = ImageDraw.Draw(tile)
        label = f"+{more}"
        box = d.textbbox((0, 0), label, font=font)
        d.text(((t - (box[2] - box[0])) / 2, (t - (box[3] - box[1])) / 2 - box[1]), label, font=font, fill=(110, 110, 120, 255))
        canvas.paste(tile, (x, y), tile)
    out = root / "docs/wall/mosaic.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(out, optimize=True)
    return out


def build(root):
    apps = sorted(load(root), key=lambda e: (e.get("added") or "", ), reverse=True)
    esc = html.escape
    n = len(apps)
    if apps:
        mosaic(root, apps)
        block = (f'<p align="center"><a href="docs/WALL-OF-APPS.md"><img src="docs/wall/mosaic.png" '
                 f'alt="Icons of {n} apps on the Wall of Apps" width="{min(COLUMNS, n) * (TILE + GAP)}"></a></p>\n\n'
                 f'<p align="center"><b>{n} app{"s" if n != 1 else ""}</b> shipped by developers who use Hmunmawi · '
                 f'<a href="docs/WALL-OF-APPS.md">See them all</a></p>')
    else:
        block = "_No apps yet. Be the first: Settings → About → Wall of Apps._"
    readme = root / "README.md"
    text = readme.read_text()
    text = re.sub(r"<!-- wall:start -->.*?<!-- wall:end -->", lambda m: f"<!-- wall:start -->\n{block}\n<!-- wall:end -->", text, flags=re.S)
    readme.write_text(text)
    rows = "\n".join(
        f'| <a href="{esc(e["link"])}"><img src="wall/icons/{app_id(e)}.png" width="40" height="40" alt=""></a> '
        f'| [{esc(e["app"])}]({esc(e["link"])}) | {esc(e.get("developer") or "")} | {esc(e.get("added") or "")} |'
        for e in apps)
    page = ("# Wall of Apps\n\nApps shipped by indie developers who use Hmunmawi, newest first. "
            "Add yours from the app: Settings → About → Wall of Apps, and share your launch story in "
            "[Wall of Apps / Show & Tell](https://github.com/priyevsingh/hmunmawi/discussions/categories/wall-of-apps-show-tell).\n\n"
            + (f"**{n} app{'s' if n != 1 else ''}**\n\n| | App | Developer | Joined |\n|---|---|---|---|\n{rows}\n" if apps
               else "_No apps yet. Be the first._\n"))
    (root / "docs/WALL-OF-APPS.md").write_text(page)
    print(f"{n} apps on the wall")
    return 0


def since(root, day):
    new = [e for e in load(root) if (e.get("added") or "") > day]
    for e in sorted(new, key=lambda e: e.get("added") or ""):
        dev = f" by {e['developer']}" if e.get("developer") else ""
        print(f"- Welcome to the Wall of Apps: [{e['app']}]({e['link']}){dev}")
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--since")
    ap.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parent.parent))
    a = ap.parse_args()
    root = pathlib.Path(a.root)
    if a.since:
        sys.exit(since(root, a.since))
    code = check(root) if a.check else 0
    if a.build and code == 0:
        code = build(root)
    if not (a.check or a.build):
        code = build(root)      # the old default: rebuild
    sys.exit(code)
