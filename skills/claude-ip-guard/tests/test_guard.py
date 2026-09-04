#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[3]
GUARD_DIR = ROOT / "skills" / "claude-ip-guard"
ENFORCER = GUARD_DIR / "scripts" / "claude-ip-enforce.sh"
HEAL = GUARD_DIR / "scripts" / "claude-ip-heal.sh"
CUTOVER = GUARD_DIR / "scripts" / "cutover.sh"
ROLLBACK = GUARD_DIR / "scripts" / "rollback.sh"
MERGE_EXAMPLE = ROOT / "merge-profile-example.yaml"
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def run_bash(body: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/bin/bash", "-c", body],
        cwd=ROOT,
        text=True,
        capture_output=True,
        env={**os.environ, "LC_ALL": "C"},
        check=False,
    )


class GuardBehaviorTests(unittest.TestCase):
    def source_enforcer(self, body: str) -> subprocess.CompletedProcess[str]:
        self.assertTrue(ENFORCER.is_file(), "tracked enforcer source is missing")
        return run_bash(f'source "{ENFORCER}"\n{body}')

    def test_direct_socks_success_does_not_mask_full_chain_failure(self) -> None:
        result = self.source_enforcer(
            """
runtime_claude_guard_ok() { return 0; }
anthropic_full_chain_ok() { ANTHROPIC_RESULT=failed; return 1; }
full_path_ip_status() { FULL_PATH_IP_RESULT=192.0.2.10; return 0; }
residential_socks_direct_ok() { RESIDENTIAL_DIRECT_RESULT=ok; return 0; }
if guard_fast_path_ok; then
  exit 90
fi
exit 0
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_fallback_accepts_second_qualified_chain_when_first_is_dead(self) -> None:
        result = self.source_enforcer(
            """
api_get_group() {
  case "$1" in
    Claude) printf '%s' '{"name":"Claude","type":"Selector","now":"Claude-VPS","all":["Claude-VPS","Claude-Residential","REJECT"]}' ;;
    Claude-Residential) printf '%s' '{"name":"Claude-Residential","type":"Fallback","now":"Claude-Residential-JP1","all":["Claude-Residential-JP3","Claude-Residential-JP1","Claude-Residential-SG5","Claude-Residential-SG4"]}' ;;
  esac
}
runtime_core_ok() { return 0; }
runtime_claude_rules_ok() { return 0; }
anthropic_full_chain_ok() { ANTHROPIC_RESULT=http-404; return 0; }
full_path_ip_status() { FULL_PATH_IP_RESULT=192.0.2.10; return 0; }
TARGET_IP=192.0.2.10
runtime_claude_guard_ok || exit 91
[[ "$CURRENT_CHAIN_CANDIDATE" == Claude-Residential-JP1 ]] || exit 92
guard_fast_path_ok || exit 93
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_clean_healthy_cycle_is_read_only(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            calls = Path(td) / "calls"
            result = self.source_enforcer(
                f"""
CALLS={shlex.quote(str(calls))}
guard_fast_path_ok() {{ return 0; }}
current_state() {{ printf OK; }}
current_fail_count() {{ printf 0; }}
set_state() {{ echo set-state >> "$CALLS"; }}
set_fail_count() {{ echo set-fail >> "$CALLS"; }}
write_guard_state() {{ echo state-json >> "$CALLS"; }}
append_guard_event() {{ echo event >> "$CALLS"; }}
run_heal() {{ echo heal >> "$CALLS"; }}
reload_core() {{ echo reload >> "$CALLS"; }}
set_group_choice() {{ echo switch >> "$CALLS"; }}
run_enforcer_cycle
[[ ! -e "$CALLS" ]]
"""
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_ip_mismatch_really_selects_reject(self) -> None:
        result = self.source_enforcer(
            """
choice=Claude-Residential
set_group_choice() { [[ "$1" == Claude ]] || exit 94; choice="$2"; }
current_group_choice() { printf '%s' "$choice"; }
reject_claude_now
[[ "$choice" == REJECT ]]
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_nonzero_claude_requests_block_maintenance_mutation(self) -> None:
        result = self.source_enforcer(
            """
claude_active_connection_count() { printf 1; }
MAINTENANCE_GATE_SECONDS=30
if maintenance_gate_clear; then
  exit 95
fi
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)


class TopologyTests(unittest.TestCase):
    def test_cutover_scripts_load_vps_endpoint_from_local_params(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            params = Path(td) / "reality_params.txt"
            params.write_text("server=198.51.100.20\nport=443\n")
            for script in (CUTOVER, ROLLBACK):
                with self.subTest(script=script.name):
                    result = run_bash(
                        f"""
source "{script}"
PARAMS_FILE={shlex.quote(str(params))}
VPS_IP=
VPS_PORT=
load_vps_endpoint
[[ "$VPS_IP" == 198.51.100.20 ]]
[[ "$VPS_PORT" == 443 ]]
"""
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_cutover_backup_preserves_executable_wrapper_mode(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            temp = Path(td)
            source = temp / "wrapper"
            backup = temp / "wrapper.backup"
            source.write_text("#!/bin/bash\nexit 0\n")
            source.chmod(0o755)
            result = run_bash(
                f"""
source "{CUTOVER}"
backup_file {shlex.quote(str(source))} {shlex.quote(str(backup))} 700
[[ -x {shlex.quote(str(backup))} ]]
"""
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_cutover_can_reload_the_backed_up_runtime_directly(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            temp = Path(td)
            base = temp / "base"
            base.mkdir()
            runtime = base / "clash-verge-guard-expanded.yaml"
            runtime.write_text("mode: rule\n")
            sock = temp / "mihomo.sock"
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(str(sock))
            listener.close()
            capture = temp / "curl.args"
            fake_curl = temp / "curl"
            fake_curl.write_text(
                "#!/bin/bash\nprintf '%s\\n' \"$@\" > \"$CAPTURE\"\n"
            )
            fake_curl.chmod(0o755)
            result = run_bash(
                f"""
source "{CUTOVER}"
BASE={shlex.quote(str(base))}
SOCK={shlex.quote(str(sock))}
CURL_BIN={shlex.quote(str(fake_curl))}
CAPTURE={shlex.quote(str(capture))}
export CAPTURE
reload_restored_runtime
grep -F {shlex.quote(str(runtime))} "$CAPTURE"
grep -F 'http://localhost/configs' "$CAPTURE"
"""
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_cutover_failure_restoration_activates_backed_up_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            temp = Path(td)
            base = temp / "base"
            backup = temp / "backup"
            base.mkdir()
            backup.mkdir()
            active_merge = temp / "active-merge.yaml"
            plist = temp / "enforcer.plist"
            wrapper = temp / "claude-ip-heal"
            marker = temp / "runtime-reloaded"
            for path in (
                backup / "clash-verge.yaml",
                backup / "active-merge.yaml",
                backup / "clash-verge-guard-expanded.yaml",
                backup / "com.zhangxinran.claude-ip-enforcer.plist",
                backup / "claude-ip-heal.wrapper",
            ):
                path.write_text("backup\n")
            result = run_bash(
                f"""
source "{CUTOVER}"
BASE={shlex.quote(str(base))}
BACKUP_DIR={shlex.quote(str(backup))}
ACTIVE_MERGE={shlex.quote(str(active_merge))}
PLIST={shlex.quote(str(plist))}
WRAPPER={shlex.quote(str(wrapper))}
LAUNCHCTL_BIN=/usr/bin/false
HEAL_BIN=/usr/bin/true
NOTIFY_BIN=/usr/bin/true
MUTATION_STARTED=1
ENFORCER_WAS_LOADED=0
reload_restored_runtime() {{ printf called > {shlex.quote(str(marker))}; }}
set +e
(restore_failed_cutover 42)
rc=$?
set -e
[[ "$rc" == 42 ]]
[[ -f {shlex.quote(str(marker))} ]]
"""
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_cutover_injects_vps_into_indentationless_merge(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            temp = Path(td)
            params = temp / "reality_params.txt"
            merge = temp / "merge.yaml"
            params.write_text(
                "\n".join(
                    [
                        "server=198.51.100.20",
                        "port=443",
                        "uuid=00000000-0000-4000-8000-000000000001",
                        "publicKey=fixture-public-key",
                        "shortId=fixture-short-id",
                        "sni=www.example.com",
                    ]
                )
                + "\n"
            )
            merge.write_text(
                """prepend-proxies:
- { name: 'Claude-Residential-JP3', type: socks5, server: 192.0.2.10, port: 443, username: fixture-user, password: fixture-password, udp: true, dialer-proxy: JP3-HY2 }
prepend-proxy-groups:
- name: Claude
  type: select
  proxies:
  - Claude-Residential
  - REJECT
"""
            )
            result = run_bash(
                f"""
source "{CUTOVER}"
PARAMS_FILE={shlex.quote(str(params))}
VPS_IP=198.51.100.20
VPS_PORT=443
inject_vps_node {shlex.quote(str(merge))}
"""
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            data = yaml.safe_load(merge.read_text()) or {}
            proxies = data.get("prepend-proxies") or []
            groups = data.get("prepend-proxy-groups") or []
            self.assertTrue(any(proxy.get("name") == "Claude-VPS" for proxy in proxies))
            claude = next(group for group in groups if group.get("name") == "Claude")
            self.assertEqual(
                claude.get("proxies"),
                ["Claude-VPS", "Claude-Residential", "REJECT"],
            )

    def test_merge_example_contains_only_qualified_full_chains(self) -> None:
        text = MERGE_EXAMPLE.read_text()
        self.assertIn("name: 'Claude-Residential-JP3'", text)
        self.assertIn("dialer-proxy: JP3-HY2", text)
        self.assertIn("name: 'Claude-Residential-JP1'", text)
        self.assertIn("dialer-proxy: JP1-HY2", text)
        self.assertIn("expected-status: 404", text)
        self.assertIn("- REJECT", text)
        self.assertNotIn("name: Claude-Tunnel", text)

    def test_heal_preserves_and_validates_full_chain_topology(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            (base / "profiles").mkdir()
            candidate = base / "profiles" / "merge.yaml"
            shutil.copyfile(FIXTURES / "full-chain.yaml", candidate)
            result = run_bash(
                f"""
source "{HEAL}"
BASE={shlex.quote(str(base))}
TARGET_IP=198.51.100.20
TARGET_PORT=443
RESIDENTIAL_IP=192.0.2.10
RESIDENTIAL_PORT=443
HEAL_CHANGED=0
patch_file "{candidate}"
harden_file "{candidate}"
validate_full_chain_topology "{candidate}"
! grep -q 'Claude-Tunnel' "{candidate}"
grep -q 'dialer-proxy: JP3-HY2' "{candidate}"
grep -q 'dialer-proxy: JP1-HY2' "{candidate}"
"""
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_heal_validates_rollback_target_without_rewriting_vps_endpoint(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            (base / "profiles").mkdir()
            candidate = base / "profiles" / "merge.yaml"
            shutil.copyfile(FIXTURES / "full-chain.yaml", candidate)
            result = run_bash(
                f"""
source "{HEAL}"
BASE={shlex.quote(str(base))}
TARGET_IP=192.0.2.10
TARGET_PORT=443
RESIDENTIAL_IP=192.0.2.10
RESIDENTIAL_PORT=443
HEAL_CHANGED=0
patch_file "{candidate}"
harden_file "{candidate}"
validate_full_chain_topology "{candidate}"
"""
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            data = yaml.safe_load(candidate.read_text()) or {}
            proxies = data.get("prepend-proxies") or data.get("proxies") or []
            vps = next(proxy for proxy in proxies if proxy.get("name") == "Claude-VPS")
            self.assertEqual(vps.get("server"), "198.51.100.20")
            self.assertEqual(vps.get("port"), 443)

    def test_heal_rejects_legacy_tunnel_topology(self) -> None:
        result = run_bash(
            f"""
source "{HEAL}"
if validate_full_chain_topology "{FIXTURES / 'legacy-tunnel.yaml'}"; then
  exit 96
fi
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_heal_waits_for_post_reload_warmup_without_reloading_again(self) -> None:
        result = run_bash(
            f"""
source "{HEAL}"
attempts=0
reloads=0
check_ip() {{ attempts=$((attempts + 1)); ((attempts >= 2)); }}
reload_core() {{ reloads=$((reloads + 1)); }}
sleep() {{ :; }}
check_ip_with_warmup
[[ "$attempts" == 2 ]]
[[ "$reloads" == 0 ]]
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
