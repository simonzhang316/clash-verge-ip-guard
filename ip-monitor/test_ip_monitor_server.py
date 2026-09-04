#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


IP_MONITOR_DIR = Path(__file__).resolve().parent
SERVER = IP_MONITOR_DIR / "ip_monitor_server.py"


class IpMonitorOperationsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._tempdir = tempfile.TemporaryDirectory()
        token_file = Path(cls._tempdir.name) / "cockpit-token"
        old_token_file = os.environ.get("COCKPIT_TOKEN_FILE")
        os.environ["COCKPIT_TOKEN_FILE"] = str(token_file)
        try:
            spec = importlib.util.spec_from_file_location("ip_monitor_server", SERVER)
            cls.server = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.server)
        finally:
            if old_token_file is None:
                os.environ.pop("COCKPIT_TOKEN_FILE", None)
            else:
                os.environ["COCKPIT_TOKEN_FILE"] = old_token_file

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tempdir.cleanup()

    def test_delay_test_protects_both_claude_exit_groups(self) -> None:
        for exit_group in ("Claude-VPS", "Claude-Residential"):
            with self.subTest(exit_group=exit_group), mock.patch.object(
                self.server,
                "mihomo_get",
                return_value=(
                    200,
                    {"type": "Selector", "all": [exit_group, "Other-Node"]},
                ),
            ), mock.patch.object(self.server, "mihomo_request") as request:
                request.return_value = (200, {})
                status, result = self.server.op_delay_test({"group": "主代理"})

            self.assertEqual(status, 403)
            self.assertEqual(result["error"], "claude_exit_protected")
            request.assert_not_called()

    def test_dashboard_uses_neutral_claude_exit_wording(self) -> None:
        html = (IP_MONITOR_DIR / "index.html").read_text(encoding="utf-8")

        self.assertIn("不探测 Claude 出口", html)
        self.assertIn('["Claude-VPS", "Claude-Residential"].some', html)
        self.assertNotIn("不探测家宽出口", html)


if __name__ == "__main__":
    unittest.main()
