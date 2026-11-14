#!/usr/bin/env python3
"""Shared AI limit / pause policy (one JSON file, flock, atomic replace).

Hmunmawi writes manual pauses through this module (or hm ai-pause); the hub runner
records detected limits. Callers ask defer_for_job() before spawning Claude work.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
LIMIT_KINDS = frozenset({"session", "daily", "weekly", "rate", "auth", "network", "spend", "unknown"})
CONFIDENCE = frozenset({"high", "medium", "low"})


def _hm_path() -> Path:
    return Path.home() / "Library/Application Support/Hmunmawi/ai_policy.json"


def policy_path() -> Path:
    if p := os.environ.get("AI_POLICY_FILE"):
        return Path(p).expanduser()
    return _hm_path()


def _state_dir() -> Path:
    return policy_path().parent


def _backup_path(path: Path) -> Path:
    return path.with_suffix(path.suffix + f".bak.{int(time.time())}")


def _empty() -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "updated_at": 0,
        "episode": None,
        "accounts": {},
        "deferrals": {},
        "settings": {
            "allow_cursor_fallback": False,
            "allow_account_relay": False,
            "recheck_cooldown_sec": 900,
        },
    }


def _lock_path(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    return path.with_suffix(path.suffix + ".lock")


class PolicyLock:
    def __init__(self, path: Path):
        self.path = path
        self.lockf: Any = None
        self.fd: int | None = None

    def __enter__(self):
        lp = _lock_path(self.path)
        self.fd = os.open(lp, os.O_CREAT | os.O_RDWR, 0o600)
        self.lockf = os.fdopen(self.fd, "r+")
        fcntl.flock(self.lockf.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        if self.lockf:
            fcntl.flock(self.lockf.fileno(), fcntl.LOCK_UN)
            self.lockf.close()


def load_unlocked(path: Path) -> dict[str, Any]:
    if not path.exists():
        return _empty()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return _empty()
    if not isinstance(data, dict):
        return _empty()
    data.setdefault("schema_version", SCHEMA_VERSION)
    data.setdefault("accounts", {})
    data.setdefault("deferrals", {})
    data.setdefault("settings", _empty()["settings"])
    return data


def save_atomic(path: Path, data: dict[str, Any]) -> None:
    data["schema_version"] = SCHEMA_VERSION
    data["updated_at"] = int(time.time())
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        sync_legacy_ai_state(data)
    finally:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def task_key(title: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", (title or "brief").strip().lower()).strip("-")
    return slug[:80] or "brief"


def sync_legacy_ai_state(data: dict[str, Any]) -> None:
    """Keep ai_state.json claude_blocked_until_epoch aligned with policy (readers that predate policy)."""
    leg = _state_dir() / "ai_state.json"
    aid = _default_claude_account_id()
    acct = data.get("accounts", {}).get(aid) or {}
    until = 0
    if acct:
        u, _ = effective_until(acct)
        if u < 2**62 - 1:
            until = u
    st: dict[str, Any] = {}
    if leg.exists():
        try:
            st = json.loads(leg.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            st = {}
    st["claude_blocked_until_epoch"] = int(until)
    leg.parent.mkdir(parents=True, exist_ok=True)
    leg.write_text(
        json.dumps(
            {
                "claude_blocked_until_epoch": st["claude_blocked_until_epoch"],
                "last_engine": st.get("last_engine") or "claude",
                "last_switch_reason": st.get("last_switch_reason") or "policy_sync",
                "last_account": st.get("last_account") or aid,
            }
        )
        + "\n",
        encoding="utf-8",
    )


def migrate_from_ai_state(path: Path, data: dict[str, Any]) -> dict[str, Any]:
    if data.get("accounts"):
        return data
    legacy = _state_dir() / "ai_state.json"
    if not legacy.exists():
        return data
    try:
        st = json.loads(legacy.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return data
    until = int(st.get("claude_blocked_until_epoch") or 0)
    if until > int(time.time()):
        acct = _default_claude_account_id()
        data["accounts"].setdefault(acct, {"provider": "claude", "label": acct, "manual": {}, "detected": {}})
        data["accounts"][acct]["detected"]["weekly"] = {
            "until_epoch": until,
            "confidence": "medium",
            "source": "migrated_ai_state",
            "updated_at": int(time.time()),
        }
    return data


def _default_claude_account_id() -> str:
    relay = Path.home() / ".claude/relay/accounts.py"
    if relay.exists():
        try:
            import subprocess

            r = subprocess.run(
                ["python3", str(relay), "team"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if r.returncode == 0 and r.stdout.strip():
                login = r.stdout.split()[0].strip()
                if login and "@" not in login:
                    return login
                if login:
                    return login.split("@")[0]
        except (OSError, subprocess.TimeoutExpired):
            pass
    return "team"


def _now() -> int:
    return int(time.time())


def _account(data: dict[str, Any], account_id: str) -> dict[str, Any]:
    data.setdefault("accounts", {})
    if account_id not in data["accounts"]:
        data["accounts"][account_id] = {
            "provider": "claude",
            "label": account_id,
            "manual": {},
            "detected": {},
        }
    return data["accounts"][account_id]


def effective_until(account: dict[str, Any], now: int | None = None) -> tuple[int, list[dict[str, Any]]]:
    """Return (max_until, reasons[]) for claude jobs on this account."""
    now = now or _now()
    reasons: list[dict[str, Any]] = []
    best = 0
    manual = account.get("manual") or {}
    if manual.get("pause_indefinite"):
        reasons.append(
            {
                "kind": "manual",
                "until_epoch": None,
                "confidence": "high",
                "source": manual.get("source") or "user",
                "detail": manual.get("reason") or "Paused until you clear it",
            }
        )
        return 2**62 - 1, reasons
    pause_until = int(manual.get("pause_until_epoch") or 0)
    if pause_until > now:
        best = max(best, pause_until)
        reasons.append(
            {
                "kind": "manual",
                "until_epoch": pause_until,
                "confidence": "high",
                "source": manual.get("source") or "user",
                "detail": manual.get("reason") or "Manual pause",
            }
        )
    known = int(manual.get("known_reset_epoch") or 0)
    detected = account.get("detected") or {}
    for lk, block in detected.items():
        if lk not in LIMIT_KINDS:
            continue
        until = int(block.get("until_epoch") or 0)
        conf = block.get("confidence") or "low"
        if until <= now:
            continue
        if conf == "low" and not pause_until and not manual.get("pause_indefinite"):
            # low-confidence alone does not hard-block; only informs scheduling
            continue
        best = max(best, until)
        reasons.append(
            {
                "kind": lk,
                "until_epoch": until,
                "confidence": conf,
                "source": block.get("source") or "runner",
                "detail": block.get("detail") or lk,
            }
        )
    if known > now and best < known:
        # known reset used as schedule hint when detected blocks are medium/high
        for r in reasons:
            if r["confidence"] in ("high", "medium"):
                best = max(best, known)
                break
    return best, reasons


def defer_for_job(
    data: dict[str, Any],
    *,
    provider: str = "claude",
    account_id: str | None = None,
    scope: str = "claude_cli",
    now: int | None = None,
) -> dict[str, Any] | None:
    """None = allow; else {until_epoch, reasons, scope}."""
    now = now or _now()
    settings = data.get("settings") or {}
    if provider != "claude" and scope == "claude_cli":
        return None
    if account_id is None:
        account_id = _default_claude_account_id()
    acct = data.get("accounts", {}).get(account_id)
    if not acct:
        return None
    until, reasons = effective_until(acct, now)
    if until <= now:
        return None
    return {"account_id": account_id, "until_epoch": until, "reasons": reasons, "scope": scope}


def record_detected(
    data: dict[str, Any],
    account_id: str,
    kind: str,
    until_epoch: int,
    *,
    confidence: str = "medium",
    source: str = "runner",
    detail: str = "",
) -> dict[str, Any]:
    kind = kind if kind in LIMIT_KINDS else "unknown"
    if confidence not in CONFIDENCE:
        confidence = "medium"
    acct = _account(data, account_id)
    acct["detected"][kind] = {
        "until_epoch": int(until_epoch),
        "confidence": confidence,
        "source": source,
        "detail": detail[:240],
        "updated_at": _now(),
    }
    return data


def clear_detected_if_past(data: dict[str, Any], account_id: str, now: int | None = None) -> dict[str, Any]:
    now = now or _now()
    acct = data.get("accounts", {}).get(account_id)
    if not acct:
        return data
    det = acct.get("detected") or {}
    acct["detected"] = {k: v for k, v in det.items() if int(v.get("until_epoch") or 0) > now}
    return data


def set_manual_pause(
    data: dict[str, Any],
    account_id: str,
    *,
    pause_until_epoch: int | None = None,
    pause_indefinite: bool = False,
    known_reset_epoch: int | None = None,
    reason: str = "",
    source: str = "user",
    timezone_name: str | None = None,
) -> dict[str, Any]:
    acct = _account(data, account_id)
    manual = acct.setdefault("manual", {})
    manual["source"] = source
    manual["reason"] = reason[:500]
    if timezone_name:
        manual["timezone"] = timezone_name
    if pause_indefinite:
        manual["pause_indefinite"] = True
        manual.pop("pause_until_epoch", None)
    elif pause_until_epoch is not None:
        manual["pause_indefinite"] = False
        manual["pause_until_epoch"] = int(pause_until_epoch)
    if known_reset_epoch is not None:
        manual["known_reset_epoch"] = int(known_reset_epoch)
    manual["updated_at"] = _now()
    return data


def clear_manual_pause(data: dict[str, Any], account_id: str, *, clear_known_reset: bool = False) -> dict[str, Any]:
    acct = data.get("accounts", {}).get(account_id)
    if not acct:
        return data
    manual = acct.get("manual") or {}
    manual.pop("pause_indefinite", None)
    manual.pop("pause_until_epoch", None)
    if clear_known_reset:
        manual.pop("known_reset_epoch", None)
    manual["updated_at"] = _now()
    acct["manual"] = manual
    return data


def classify_limit_text(text: str) -> str:
    t = text.lower()
    if re.search(r"auth|login|sign.?in|credential|unauthorized|401|403", t):
        return "auth"
    if re.search(r"network|timeout|connect|dns|unreachable|503|502", t):
        return "network"
    if re.search(r"session", t):
        return "session"
    if re.search(r"daily", t):
        return "daily"
    if re.search(r"weekly", t):
        return "weekly"
    if re.search(r"rate", t):
        return "rate"
    if re.search(r"spend|billing|balance|payment", t):
        return "spend"
    return "unknown"


def episode_key(reasons: list[dict[str, Any]], account_id: str) -> str:
    kinds = sorted({r.get("kind") or "unknown" for r in reasons}) or ["unknown"]
    return f"claude|{account_id}|" + "+".join(kinds)


def touch_episode(data: dict[str, Any], account_id: str, reasons: list[dict[str, Any]], *, notify: bool = False) -> dict[str, Any]:
    ep = data.get("episode") or {}
    key = episode_key(reasons, account_id)
    now = _now()
    if ep.get("key") != key:
        ep = {"key": key, "started_at": now, "last_notify_at": 0, "suppressed_jobs": 0, "account_id": account_id}
    if notify:
        ep["last_notify_at"] = now
        ep["suppressed_jobs"] = 0
    else:
        ep["suppressed_jobs"] = int(ep.get("suppressed_jobs") or 0) + 1
    data["episode"] = ep
    return data


def should_send_limit_notice(data: dict[str, Any], *, min_interval_sec: int = 6 * 3600) -> bool:
    ep = data.get("episode") or {}
    if not ep:
        return True
    last = int(ep.get("last_notify_at") or 0)
    return _now() - last >= min_interval_sec


def record_deferral(data: dict[str, Any], task_key: str, until_epoch: int, *, title: str = "") -> dict[str, Any]:
    data.setdefault("deferrals", {})
    data["deferrals"][task_key] = {
        "until_epoch": int(until_epoch),
        "title": title[:120],
        "updated_at": _now(),
    }
    return data


def prune_deferrals(data: dict[str, Any], now: int | None = None) -> dict[str, Any]:
    now = now or _now()
    defs = data.get("deferrals") or {}
    data["deferrals"] = {k: v for k, v in defs.items() if int(v.get("until_epoch") or 0) > now - 86400}
    return data


def cursor_fallback_allowed(data: dict[str, Any]) -> bool:
    return bool((data.get("settings") or {}).get("allow_cursor_fallback"))


def account_relay_allowed(data: dict[str, Any]) -> bool:
    return bool((data.get("settings") or {}).get("allow_account_relay"))


def parse_iso_epoch(s: str) -> int | None:
    s = s.strip()
    if not s:
        return None
    try:
        if s.endswith("Z"):
            dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        else:
            dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    except ValueError:
        return None


def with_policy(mutator=None, *, path: Path | None = None, read_only: bool = False):
    path = path or policy_path()
    with PolicyLock(path):
        data = load_unlocked(path)
        if mutator and not read_only:
            data = mutator(data) or data
            data = prune_deferrals(data)
            save_atomic(path, data)
        return data


def cmd_status(args: argparse.Namespace) -> int:
    path = policy_path()
    data = with_policy(read_only=True)
    acct_id = args.account or _default_claude_account_id()
    acct = data.get("accounts", {}).get(acct_id, {})
    until, reasons = effective_until(acct, _now()) if acct else (0, [])
    out = {
        "path": str(path),
        "account_id": acct_id,
        "blocked": until > _now(),
        "until_epoch": until if until < 2**62 - 1 else None,
        "reasons": reasons,
        "episode": data.get("episode"),
        "deferrals_count": len(data.get("deferrals") or {}),
        "cursor_fallback": cursor_fallback_allowed(data),
        "account_relay": account_relay_allowed(data),
    }
    print(json.dumps(out, indent=2))
    return 0


def cmd_should_defer(args: argparse.Namespace) -> int:
    data = with_policy(read_only=True)
    d = defer_for_job(data, account_id=args.account, scope=args.scope)
    if d:
        print(json.dumps({"defer": True, **d}, indent=2))
        return 0
    print(json.dumps({"defer": False}, indent=2))
    return 0


def cmd_set_pause(args: argparse.Namespace) -> int:
    def mut(data):
        aid = args.account or _default_claude_account_id()
        if args.clear:
            return clear_manual_pause(data, aid, clear_known_reset=args.clear_known_reset)
        until = None
        if args.until:
            until = parse_iso_epoch(args.until)
            if until is None:
                raise SystemExit(f"Bad --until: {args.until}")
        known = parse_iso_epoch(args.known_reset) if args.known_reset else None
        return set_manual_pause(
            data,
            aid,
            pause_until_epoch=until,
            pause_indefinite=args.indefinite,
            known_reset_epoch=known,
            reason=args.reason or "",
            source=args.source or "user",
            timezone_name=args.timezone,
        )

    with_policy(mut)
    return 0


def cmd_record_detected(args: argparse.Namespace) -> int:
    def mut(data):
        return record_detected(
            data,
            args.account or _default_claude_account_id(),
            args.kind,
            int(args.until_epoch),
            confidence=args.confidence,
            source=args.source,
            detail=args.detail or "",
        )

    with_policy(mut)
    return 0


def cmd_episode_notify(args: argparse.Namespace) -> int:
    def mut(data):
        return touch_episode(data, args.account or _default_claude_account_id(), [{"kind": args.kind}], notify=True)

    with_policy(mut)
    return 0


def cmd_episode_suppress(args: argparse.Namespace) -> int:
    reasons = json.loads(args.reasons_json) if args.reasons_json else [{"kind": "unknown"}]

    def mut(data):
        return touch_episode(data, args.account or _default_claude_account_id(), reasons, notify=False)

    with_policy(mut)
    return 0


def blocked_until_for_account(data: dict[str, Any], account_id: str | None = None) -> int:
    account_id = account_id or _default_claude_account_id()
    acct = data.get("accounts", {}).get(account_id)
    if not acct:
        return 0
    until, _ = effective_until(acct, _now())
    if until >= 2**62 - 1:
        return until
    return until if until > _now() else 0


def clear_episode(data: dict[str, Any]) -> dict[str, Any]:
    data["episode"] = None
    return data


def cmd_blocked_until(args: argparse.Namespace) -> int:
    data = with_policy(read_only=True)
    print(blocked_until_for_account(data, args.account or _default_claude_account_id()))
    return 0


def cmd_limit_notify_allowed(args: argparse.Namespace) -> int:
    data = with_policy(read_only=True)
    ok = should_send_limit_notice(data, min_interval_sec=args.min_interval)
    print("yes" if ok else "no")
    return 0 if ok else 1


def cmd_record_submit_defer(args: argparse.Namespace) -> int:
    def mut(data):
        key = task_key(args.title or "")
        return record_deferral(data, key, int(args.until_epoch), title=args.title or "")

    with_policy(mut)
    return 0


def cmd_clear_episode(args: argparse.Namespace) -> int:
    had = False

    def mut(data):
        nonlocal had
        ep = data.get("episode") or {}
        had = bool(ep.get("last_notify_at"))
        return clear_episode(data)

    with_policy(mut)
    if (
        getattr(args, "notify_recovery", False)
        and had
        and os.environ.get("AI_JOB_NOTIFY", "1") == "1"
    ):
        try:
            from ai_job_notify import send

            send("✅ Claude AI jobs are running again after the usage pause.")
        except Exception:
            pass
    return 0


def cmd_touch_legacy(args: argparse.Namespace) -> int:
    """Rewrite ai_state.json from current policy (no other changes)."""

    def mut(data):
        return data

    with_policy(mut)
    return 0


def cmd_migrate(args: argparse.Namespace) -> int:
    path = policy_path()
    if path.exists() and not args.force:
        print("already exists", file=sys.stderr)
        return 0
    if path.exists():
        save_atomic(_backup_path(path), load_unlocked(path))

    def mut(data):
        return migrate_from_ai_state(path, data)

    with_policy(mut)
    print(str(path))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    st = sub.add_parser("status")
    st.add_argument("--account")
    st.set_defaults(func=cmd_status)

    sd = sub.add_parser("should-defer")
    sd.add_argument("--account")
    sd.add_argument("--scope", default="claude_cli")
    sd.set_defaults(func=cmd_should_defer)

    sp = sub.add_parser("set-pause")
    sp.add_argument("--account")
    sp.add_argument("--until", help="ISO8601 pause end")
    sp.add_argument("--known-reset", dest="known_reset", help="ISO8601 known provider reset")
    sp.add_argument("--indefinite", action="store_true")
    sp.add_argument("--clear", action="store_true")
    sp.add_argument("--clear-known-reset", action="store_true")
    sp.add_argument("--reason", default="")
    sp.add_argument("--source", default="user")
    sp.add_argument("--timezone", default="")
    sp.set_defaults(func=cmd_set_pause)

    rd = sub.add_parser("record-detected")
    rd.add_argument("--account")
    rd.add_argument("--kind", required=True)
    rd.add_argument("--until-epoch", type=int, required=True)
    rd.add_argument("--confidence", default="medium")
    rd.add_argument("--source", default="runner")
    rd.add_argument("--detail", default="")
    rd.set_defaults(func=cmd_record_detected)

    en = sub.add_parser("episode-notify")
    en.add_argument("--account")
    en.add_argument("--kind", default="weekly")
    en.set_defaults(func=cmd_episode_notify)

    es = sub.add_parser("episode-suppress")
    es.add_argument("--account")
    es.add_argument("--reasons-json", default="")
    es.set_defaults(func=cmd_episode_suppress)

    mg = sub.add_parser("migrate")
    mg.add_argument("--force", action="store_true")
    mg.set_defaults(func=cmd_migrate)

    bu = sub.add_parser("blocked-until")
    bu.add_argument("--account")
    bu.set_defaults(func=cmd_blocked_until)

    ln = sub.add_parser("limit-notify-allowed")
    ln.add_argument("--min-interval", type=int, default=6 * 3600)
    ln.set_defaults(func=cmd_limit_notify_allowed)

    ce = sub.add_parser("clear-episode")
    ce.add_argument("--notify-recovery", action="store_true")
    ce.set_defaults(func=cmd_clear_episode)

    rd2 = sub.add_parser("record-submit-defer")
    rd2.add_argument("--title", required=True)
    rd2.add_argument("--until-epoch", type=int, required=True)
    rd2.set_defaults(func=cmd_record_submit_defer)

    tl = sub.add_parser("touch-legacy")
    tl.set_defaults(func=cmd_touch_legacy)

    args = ap.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
