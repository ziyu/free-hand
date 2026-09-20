#!/usr/bin/env python3
"""Exercise install authorization with fake tools in temporary directories.

Never builds, signs, launches, resets permissions, or replaces the real app.
Run: python3 Scripts/test-build-guard.py
"""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().with_name("build.sh")


class BuildGuardTests(unittest.TestCase):
    def run_build(self, *args: str, same: bool = False, missing: bool = False):
        with tempfile.TemporaryDirectory(prefix="freehand-build-guard-") as directory:
            root = Path(directory)
            (root / "Scripts").mkdir()
            shutil.copyfile(SCRIPT, root / "Scripts/build.sh")
            for folder in ["bin", "build-bin", "Resources", "ThirdParty", "engine/free_hand_engine",
                           "Free Hand.app", ".build"]:
                (root / folder).mkdir(parents=True, exist_ok=True)
            for filename in ["build-bin/FreeHand", "Resources/Info.plist", "Resources/AppIcon.icns",
                             "engine/pyproject.toml", "engine/uv.lock", "engine/free_hand_engine/__init__.py",
                             "ThirdParty/fixture.LICENSE", "LICENSE", "NOTICE", "Scripts/setup-runtime.sh"]:
                (root / filename).write_text("fixture\n", encoding="utf-8")
            marker = root / "Free Hand.app/installed-marker"
            marker.write_text("existing installation", encoding="utf-8")
            (root / ".freehand-signing-identity").write_text("-\n", encoding="utf-8")
            tools = {
                "swift": 'if [[ "$*" == *--show-bin-path* ]]; then printf "%s/build-bin\\n" "$PWD"; fi',
                "codesign": r'''if [[ "$1" == -d ]]; then
  case "$*" in
    *"/.build/Free Hand.app"*) printf '# designated => cdhash H"new"\n' ;;
    *) if [[ "${FAKE_MISSING:-0}" != 1 ]]; then printf '# designated => cdhash H"%s"\n' "${FAKE_OLD:-old}"; fi ;;
  esac
fi''',
                # The sentinel proves the guard was crossed; never perform installation.
                "ditto": 'printf "staging reached\\n" > "$PWD/staging-reached"; exit 73',
                "ps": 'printf "ERROR: process inspection reached\\n" >&2; exit 74',
            }
            for name, body in tools.items():
                tool = root / "bin" / name
                tool.write_text("#!/bin/bash\nset -eu\n" + body + "\n", encoding="utf-8")
                tool.chmod(0o700)
            env = {"PATH": f"{root / 'bin'}:/usr/bin:/bin", "HOME": str(root),
                   "FAKE_OLD": "new" if same else "old", "FAKE_MISSING": "1" if missing else "0"}
            completed = subprocess.run(["/bin/bash", "Scripts/build.sh", *args], cwd=root,
                                       env=env, text=True, capture_output=True, timeout=15, check=False)
            self.assertEqual(marker.read_text(encoding="utf-8"), "existing installation")
            return completed.returncode, completed.stdout + completed.stderr, (root / "staging-reached").exists()

    def test_changed_identity_blocks_before_install(self):
        code, message, staged = self.run_build("--development", "--install")
        self.assertEqual(code, 1)
        self.assertIn("Installation blocked BEFORE", message)
        self.assertFalse(staged)

    def test_identical_identity_can_reinstall(self):
        code, _, staged = self.run_build("--development", "--install", same=True)
        self.assertEqual(code, 73)  # Controlled stop inside the fake copy tool.
        self.assertTrue(staged)

    def test_explicit_identity_change_can_reach_staging(self):
        code, _, staged = self.run_build("--development", "--install", "--allow-adhoc-identity-change")
        self.assertEqual(code, 73)
        self.assertTrue(staged)

    def test_build_only_does_not_replace_current_install(self):
        code, _, staged = self.run_build("--development")
        self.assertEqual(code, 0)
        self.assertFalse(staged)

    def test_unreadable_identity_fails_closed(self):
        code, message, staged = self.run_build("--development", "--install", missing=True)
        self.assertEqual(code, 1)
        self.assertIn("Could not read both signing requirements", message)
        self.assertFalse(staged)

    def test_override_requires_explicit_development_install(self):
        for args in [("--allow-adhoc-identity-change",), ("--development", "--allow-adhoc-identity-change")]:
            with self.subTest(args=args):
                code, message, staged = self.run_build(*args)
                self.assertEqual(code, 1)
                self.assertIn("requires both", message)
                self.assertFalse(staged)


if __name__ == "__main__":
    unittest.main(verbosity=2)
