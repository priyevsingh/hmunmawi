#!/usr/bin/env python3
"""Read-only E2E snapshot: compare hub state, SQLite snapshots, and AX-visible strings."""
from __future__ import annotations

import json
import re
import sqlite3
import subprocess
import sys
import os
from pathlib import Path

HOME = Path.home()
DB = HOME / "Library/Application Support/Hmunmawi/hmunmawi.sqlite"
STATE = HOME / "Library/Application Support/Hmunmawi/agent/state.json"
if not STATE.exists():
    STATE = HOME / "Library/Application Support/Hmunmawi/Agent/state.json"
DEFAULT_HUB = HOME / "Documents/repos/hmunmawi-workspace"
if not DEFAULT_HUB.exists():
    DEFAULT_HUB = HOME / "hub"
HUB = Path(os.environ.get("HM_HUB_DIR", str(DEFAULT_HUB))).expanduser()
ROOT = Path(__file__).resolve().parent.parent
AX = ROOT / "build/ax-menubar"
if not AX.exists():
    AX = ROOT / "build/ax"
APP = Path(os.environ.get("HM_APP", str(ROOT / "build/Hmunmawi.app")))


def jq(path: Path) -> dict | list | None:
    if not path.exists():
        return None
    return json.loads(path.read_text())


def latest_event(kind: str) -> dict | None:
    if not DB.exists():
        return None
    con = sqlite3.connect(DB)
    row = con.execute(
        "SELECT payload FROM events WHERE kind=? ORDER BY id DESC LIMIT 1", (kind,)
    ).fetchone()
    con.close()
    return json.loads(row[0]) if row else None


def ax_list() -> str:
    if not AX.exists():
        return ""
    return subprocess.run([str(AX), "list"], capture_output=True, text=True).stdout


def main() -> int:
    out: dict[str, object] = {"checks": []}

    def note(name: str, status: str, detail: str = ""):
        out["checks"].append({"component": name, "status": status, "detail": detail})

    acc_db = latest_event("account.snapshot")
    dev = jq(HUB / "out/state/dev_account.json")
    if acc_db and dev:
        certs = [c.get("expires") for c in dev.get("certificates", []) if isinstance(c, dict)]
        newest = max(certs) if certs else None
        db_cert = acc_db.get("next_certificate_expiry")
        ok = bool(db_cert) and db_cert == newest
        note(
            "ASC certificate expiry (hub vs DB)",
            "pass" if ok else "open",
            f"hub_max={newest} db={db_cert}",
        )
        renews = None
        mem = dev.get("membership")
        if isinstance(mem, dict):
            renews = mem.get("renews") or mem.get("expirationDate")
        if renews and acc_db.get("renews"):
            note(
                "Membership renews (hub vs DB)",
                "pass" if str(renews)[:10] == str(acc_db["renews"])[:10] else "open",
                f"hub={renews} db={acc_db['renews']}",
            )
        dev_n = len(dev.get("devices", []))
        note(
            "Device count (hub vs DB)",
            "pass" if dev_n == acc_db.get("devices") else "open",
            f"hub={dev_n} db={acc_db.get('devices')}",
        )

    st = jq(STATE)
    if st:
        note("state.json health headline", "pass" if st.get("health") else "open", str(st.get("health")))
        rc = next((a for a in st.get("add_ons", []) if a.get("id") == "revenuecat"), {})
        note(
            "RevenueCat blocked",
            "pass" if not rc.get("allowed") else "open",
            "expected not allowed until keys+OK",
        )

    ax = ax_list()
    for label, pattern in [
        ("UI Membership 12 Dec", r"12 Dec\b"),
        ("UI Certificate / Automations", r"Certificate|Developer membership|12 Dec"),
        ("No demo banner", r"Sample data|Connect your apps"),
        ("No 8-connection banner", r"8 connections were updated"),
    ]:
        hit = bool(re.search(pattern, ax, re.I))
        if label.startswith("No"):
            note(label, "pass" if not hit else "open")
        else:
            note(label, "pass" if hit else "open")

    md = jq(HUB / "out/digest/morning_digest.json")
    if md and isinstance(md.get("numbers"), dict):
        note("morning_digest.json present", "pass", f"keys={list(md['numbers'].keys())[:6]}")

    print(json.dumps(out, indent=2))
    fails = sum(1 for c in out["checks"] if c["status"] != "pass")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
