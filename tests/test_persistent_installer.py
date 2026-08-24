from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALLER = REPO_ROOT / "scripts" / "install.sh"


class PersistentInstallerTests(unittest.TestCase):
    def test_reinstall_preserves_oauth_secrets_and_writes_private_config(self) -> None:
        if os.geteuid() != 0:
            self.skipTest("system-level installer test requires root")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            workspace.mkdir()
            fake_bin = root / "bin"
            fake_bin.mkdir()
            systemctl = fake_bin / "systemctl"
            systemctl.write_text(
                "#!/usr/bin/env bash\n"
                "if [[ \"${1:-}\" == \"is-active\" ]]; then exit 1; fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            systemctl.chmod(0o755)
            curl = fake_bin / "curl"
            curl.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            curl.chmod(0o755)

            config_dir = root / "etc" / "coding-tools-mcp"
            env_file = config_dir / "coding-tools-mcp.env"
            state_dir = root / "var" / "lib" / "coding-tools-mcp"
            persistent_root = root / "opt" / "coding-tools-mcp"
            unit_file = root / "etc" / "systemd" / "coding-tools-mcp.service"
            unit_file.parent.mkdir(parents=True)
            env = {
                **os.environ,
                "PATH": f"{fake_bin}:{os.environ.get('PATH', '')}",
                "CODING_TOOLS_MCP_CONFIG_DIR": str(config_dir),
                "CODING_TOOLS_MCP_ENV_FILE": str(env_file),
                "CODING_TOOLS_MCP_STATE_DIR": str(state_dir),
                "CODING_TOOLS_MCP_PERSISTENT_ROOT": str(persistent_root),
                "CODING_TOOLS_MCP_UNIT_FILE": str(unit_file),
                "CODING_TOOLS_MCP_AUTH_MODE": "oauth",
                "CODING_TOOLS_MCP_PERMISSION_MODE": "dangerous",
                "PYTHON": sys.executable,
            }
            command = [
                str(INSTALLER),
                "--persistent",
                "--server-bin",
                "/bin/true",
                "--workspace",
                str(workspace),
                "--public-url",
                "https://mcp.example.com/",
            ]
            first = subprocess.run(
                command,
                cwd=REPO_ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertIn("OAuth administrator password (shown once", first.stdout)
            first_config = env_file.read_text(encoding="utf-8")
            self.assertEqual(stat.S_IMODE(env_file.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(state_dir.stat().st_mode), 0o700)
            self.assertIn('CODING_TOOLS_MCP_SERVER_URL="https://mcp.example.com"', first_config)
            self.assertIn('CODING_TOOLS_MCP_HOST="127.0.0.1"', first_config)
            unit = unit_file.read_text(encoding="utf-8")
            self.assertIn("Restart=always", unit)
            self.assertIn(f"EnvironmentFile={env_file}", unit)
            self.assertIn(f"WorkingDirectory={workspace}", unit)
            self.assertNotIn(f'EnvironmentFile="{env_file}"', unit)
            installed_bin = persistent_root / "bin" / "coding-tools-mcp"
            self.assertTrue(installed_bin.is_file())
            self.assertTrue(os.access(installed_bin, os.X_OK))
            self.assertIn(f'ExecStart="{installed_bin}"', unit)

            second_env = {
                key: value
                for key, value in env.items()
                if key not in {"CODING_TOOLS_MCP_AUTH_MODE", "CODING_TOOLS_MCP_PERMISSION_MODE"}
            }
            second = subprocess.run(
                [str(INSTALLER), "--persistent", "--server-bin", "/bin/true"],
                cwd=root,
                env=second_env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertNotIn("shown once", second.stdout)
            self.assertEqual(env_file.read_text(encoding="utf-8"), first_config)


if __name__ == "__main__":
    unittest.main()
