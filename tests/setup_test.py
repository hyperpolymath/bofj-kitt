# SPDX-License-Identifier: MPL-2.0
"""Exercise bootstrap integrity checks without downloading or installing tools.

Run with: python3 tests/setup_test.py
"""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


class BootstrapIntegrityTest(unittest.TestCase):
    def run_bootstrap(self, *, corrupt=False, fetch_fails=False, checksum="sha256sum", manager=None):
        source = (Path(__file__).resolve().parents[1] / "build/setup.sh").read_text()
        helper = source.split("install_just_from_script() (", 1)[1].split(
            "# ── Install just ──", 1
        )[0]
        helper = "install_just_from_script() (" + helper
        fixture = b"#!/bin/sh\n# Synthetic installer; must only reach the mocked bash.\n"
        # Substitute a fixture pin so this unit test never needs the network.
        fixture_sha = hashlib.sha256(fixture).hexdigest()
        helper, count = re.subn(
            r'JUST_BOOTSTRAP_SHA256="[a-f0-9]{64}"',
            f'JUST_BOOTSTRAP_SHA256="{fixture_sha}"', helper,
        )
        self.assertEqual(count, 1)
        if manager:
            helper += source.split("# ── Install just ──\n", 1)[1].split("# ── Main ──", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            bin_dir = base / "bin"
            bin_dir.mkdir()
            scratch = base / "scratch"
            scratch.mkdir()
            for name in ["mktemp", "rm", "cp", "chmod", "head"] + ([checksum] if checksum else []):
                tool = shutil.which(name)
                self.assertIsNotNone(tool, f"test prerequisite missing: {name}")
                (bin_dir / name).symlink_to(tool)
            payload = base / "payload"
            payload.write_bytes(fixture + (b"# tampered\n" if corrupt else b""))
            trace = base / "executed"
            mocks = {
                "curl": '''#!/bin/sh
[ "$BOOTSTRAP_FETCH_FAILS" = false ] || exit 22
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then cp "$BOOTSTRAP_PAYLOAD" "$2"; exit; fi
    shift
done
exit 2
''',
                "sudo": "#!/bin/sh\nexit 1\n",  # Simulate an apt repository without just.
                "bash": '''#!/bin/sh
printf '%s\\n' "$@" > "$BOOTSTRAP_TRACE"
printf '#!/bin/sh\\necho just 1.40.0\\n' > "$BOOTSTRAP_BIN/just"
chmod +x "$BOOTSTRAP_BIN/just"
''',
            }
            for name, content in mocks.items():
                path = bin_dir / name
                path.write_text(content)
                path.chmod(0o755)
            script = "set -eu\nfail() { printf '%s\\n' \"$1\"; }\n" + helper
            if manager:
                script += f'\nPKG_MGR={manager}\nok() {{ :; }}\ninfo() {{ :; }}\ninstall_just\n'
            else:
                script += "\ninstall_just_from_script\n"
            environment = {
                **os.environ, "PATH": str(bin_dir), "TMPDIR": str(scratch),
                "BOOTSTRAP_PAYLOAD": str(payload), "BOOTSTRAP_TRACE": str(trace),
                "BOOTSTRAP_BIN": str(bin_dir),
                "BOOTSTRAP_FETCH_FAILS": "true" if fetch_fails else "false",
            }
            result = subprocess.run(
                ["/bin/sh", "-c", script], env=environment,
                capture_output=True, text=True, check=False,
            )
            arguments = trace.read_text().splitlines() if trace.exists() else None
            self.assertEqual(list(scratch.iterdir()), [], "bootstrap left temporary code")
            return result, arguments

    def test_verified_payload_reaches_installer_with_pinned_version(self):
        for checksum in ["sha256sum", "shasum"]:
            with self.subTest(checksum=checksum):
                result, arguments = self.run_bootstrap(checksum=checksum)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(arguments[1:], ["--tag", "1.40.0", "--to", "/usr/local/bin"])

    def test_package_manager_fallbacks_use_verified_helper(self):
        for manager in ["apt", "unknown"]:
            with self.subTest(manager=manager):
                result, arguments = self.run_bootstrap(manager=manager)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(arguments[1:], ["--tag", "1.40.0", "--to", "/usr/local/bin"])

    def test_tampered_download_is_never_executed(self):
        for checksum in ["sha256sum", "shasum"]:
            with self.subTest(checksum=checksum):
                result, arguments = self.run_bootstrap(corrupt=True, checksum=checksum)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("checksum mismatch", result.stdout)
                self.assertIsNone(arguments)

    def test_failed_download_is_never_executed(self):
        result, arguments = self.run_bootstrap(fetch_fails=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(arguments)

    def test_missing_checksum_tool_prevents_execution(self):
        result, arguments = self.run_bootstrap(checksum=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 tool", result.stdout)
        self.assertIsNone(arguments)


if __name__ == "__main__":
    unittest.main()
