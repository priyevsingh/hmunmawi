"""Tests for the bundled AI pause policy (Sources/HmunmawiApp/Resources/ai_policy.py)."""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Sources" / "HmunmawiApp" / "Resources"))
import ai_policy as ap  # noqa: E402


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "ai_policy.json"
        self.env = mock.patch.dict(os.environ, {"AI_POLICY_FILE": str(self.path)}, clear=False)
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def test_workspace_api_credit_is_ignored(self):
        text = (
            "Workspace API usage limits; regain access on 2026-12-01 at 00:00 UTC "
            "(parsed from a Claude 400)."
        )
        self.assertEqual(ap.classify_limit_text(text), "api_credit")
        self.assertEqual(ap.classify_limit_text("API credits exhausted"), "api_credit")
        self.assertEqual(ap.classify_limit_text("Anthropic API usage limit reached"), "api_credit")
        self.assertEqual(ap.classify_limit_text("Weekly usage limit reached"), "weekly")
        self.assertEqual(ap.classify_limit_text("session limit"), "session")
        self.assertEqual(ap.classify_limit_text("5-hour limit reached"), "session")
        self.assertEqual(ap.classify_limit_text("five-hour session cap"), "session")

        dec1 = 1796083200  # 2026-12-01 00:00 UTC
        now = dec1 - 86400  # 30 Nov, still during the credit-limit date
        data = ap.record_detected(
            ap._empty(), "team", "unknown", dec1, confidence="high", detail=text
        )
        self.assertIn("api_credit", data["accounts"]["team"]["detected"])
        self.assertNotIn("unknown", data["accounts"]["team"]["detected"])
        until, reasons = ap.effective_until(data["accounts"]["team"], now)
        self.assertEqual(until, 0)
        self.assertFalse(any(r.get("kind") == "api_credit" for r in reasons))
        self.assertIsNone(ap.defer_for_job(data, now=now))

        weekly = now + 3600
        data = ap.record_detected(
            data, "team", "weekly", weekly, confidence="medium", detail="weekly cap"
        )
        until, reasons = ap.effective_until(data["accounts"]["team"], now)
        self.assertEqual(until, weekly)
        kinds = {r.get("kind") for r in reasons}
        self.assertIn("weekly", kinds)
        self.assertNotIn("api_credit", kinds)
        # A leftover unknown entry with the same credit detail also does not extend the pause.
        data["accounts"]["team"]["detected"]["unknown"] = {
            "until_epoch": dec1,
            "confidence": "high",
            "source": "runner",
            "detail": text,
        }
        until, reasons = ap.effective_until(data["accounts"]["team"], now)
        self.assertEqual(until, weekly)
        self.assertNotIn("unknown", {r.get("kind") for r in reasons})

    def test_far_future_detected_block_never_blocks(self):
        """An API-credit 'regain access' date re-recorded as 'unknown' must not pause jobs."""
        now = 1795083000
        acct = {
            "detected": {
                "unknown": {
                    "until_epoch": 1796083200,
                    "confidence": "medium",
                    "source": "runner",
                    "detail": "gave_up_waiting",
                    "updated_at": now,
                },
                "session": {
                    "until_epoch": now + 3600,
                    "confidence": "high",
                    "source": "runner",
                    "detail": "session",
                    "updated_at": now,
                },
            }
        }
        until, reasons = ap.effective_until(acct, now=now)
        self.assertEqual(until, now + 3600)
        self.assertEqual([r["kind"] for r in reasons], ["session"])
        acct["detected"].pop("session")
        self.assertEqual(ap.effective_until(acct, now=now)[0], 0)


if __name__ == "__main__":
    unittest.main()
