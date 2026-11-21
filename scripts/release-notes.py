#!/usr/bin/env python3
"""Release notes for the update window, from Resources/WhatsNew.json (the same notes as the Today card).

  scripts/release-notes.py html <version>        HTML fragment (no DOCTYPE/body, so generate_appcast embeds it)
                                                  for <version> and up to 4 versions before it, newest first.
  scripts/release-notes.py check <appcast.xml> <version>
                                                  exit 1 unless that version's appcast item has non-empty notes.
Exit 2 when <version> has no notes in WhatsNew.json: every release adds its own entry."""
import html, json, os, re, sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAX_VERSIONS = 5


def key(v):
    return [int(p) if p.isdigit() else 0 for p in v.split(".")]


def notes_html(version):
    data = json.load(open(os.path.join(ROOT, "Resources", "WhatsNew.json"), encoding="utf-8"))
    versions = sorted((v for v in data["versions"] if key(v["version"]) <= key(version)), key=lambda v: key(v["version"]), reverse=True)
    if not versions or versions[0]["version"] != version or not versions[0]["items"]:
        sys.exit(f"release-notes: Resources/WhatsNew.json has no notes for {version}; add them first")
    out = []
    for v in versions[:MAX_VERSIONS]:
        out.append(f"<h3>{html.escape(v['version'])}</h3>\n<ul>")
        for it in v["items"]:
            out.append(f"<li><b>{html.escape(it['title'])}</b>. {html.escape(it['detail'])}</li>")
        out.append("</ul>")
    return "\n".join(out) + "\n"


def check(appcast, version):
    ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
    for item in ET.parse(appcast).getroot().iter("item"):
        if (item.findtext("sparkle:shortVersionString", namespaces=ns) or "") == version:
            text = re.sub(r"<[^>]+>", "", item.findtext("description") or "").strip()
            link = (item.findtext("sparkle:releaseNotesLink", namespaces=ns) or "").strip()
            if text or link:
                print(f"release-notes: appcast {version} has notes ({len(text)} characters)")
                return
            sys.exit(f"release-notes: appcast item {version} has no release notes")
    sys.exit(f"release-notes: no appcast item for {version}")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "html":
        try:
            sys.stdout.write(notes_html(sys.argv[2]))
        except SystemExit as e:
            print(e, file=sys.stderr); sys.exit(2)
    elif len(sys.argv) == 4 and sys.argv[1] == "check":
        check(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
