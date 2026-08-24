from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = REPO_ROOT / "scripts" / "build-standalone.sh"
MANAGE_SCRIPT = REPO_ROOT / "integrations" / "server" / "manage.sh"


class ServerScriptTests(unittest.TestCase):
    def run_script(self, script: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(script), *args],
            cwd=REPO_ROOT,
            input="",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_build_script_help(self) -> None:
        result = self.run_script(BUILD_SCRIPT, "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("构建可独立运行", result.stdout)
        self.assertIn("build", result.stdout)
        self.assertIn("release", result.stdout)
        self.assertIn("verify", result.stdout)
        self.assertIn("clean", result.stdout)

    def test_manage_script_help_lists_operations(self) -> None:
        result = self.run_script(MANAGE_SCRIPT, "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("中文交互式运维工具", result.stdout)
        self.assertIn("自动更新程序和脚本", result.stdout)
        for operation in (
            "install",
            "update",
            "start",
            "stop",
            "restart",
            "status",
            "logs",
            "configure",
            "uninstall",
            "purge",
        ):
            self.assertIn(operation, result.stdout)

    def test_noninteractive_builder_requires_a_command(self) -> None:
        result = self.run_script(BUILD_SCRIPT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("没有交互终端", result.stderr)

    def test_clean_skips_an_unowned_build_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            build_root = Path(tmp) / "not-owned"
            build_root.mkdir()
            sentinel = build_root / "keep.txt"
            sentinel.write_text("keep", encoding="utf-8")
            result = subprocess.run(
                [str(BUILD_SCRIPT), "clean"],
                cwd=REPO_ROOT,
                env={
                    **os.environ,
                    "CODING_TOOLS_MCP_BUILD_ROOT": str(build_root),
                    "CODING_TOOLS_MCP_OUTPUT_DIR": str(Path(tmp) / "output"),
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(sentinel.is_file())
            self.assertIn("跳过不属于本脚本的构建目录", result.stderr)

    def test_server_release_workflow_and_domain_default_are_wired(self) -> None:
        workflow = REPO_ROOT / ".github" / "workflows" / "server-release.yml"
        workflow_text = workflow.read_text(encoding="utf-8")
        manage_text = MANAGE_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('tags: ["server-v*"]', workflow_text)
        self.assertIn("coding-tools-mcp-linux-x86_64.tar.gz", workflow_text)
        self.assertIn("https://cd.had.li", manage_text)
        self.assertIn("releases/latest/download", manage_text)

    def test_bundle_update_downloads_verifies_and_installs_release(self) -> None:
        if os.geteuid() != 0:
            self.skipTest("persistent installer integration requires root")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            release_dir = root / "release"
            release_dir.mkdir()
            payload = root / "payload" / "coding-tools-mcp-0.3.1-linux-x86_64"
            payload.mkdir(parents=True)
            shutil.copy2(MANAGE_SCRIPT, payload / "coding-tools-mcp-admin")
            shutil.copy2(REPO_ROOT / "scripts" / "install.sh", payload / "install.sh")
            released_binary = payload / "coding-tools-mcp"
            released_binary.write_text(
                "#!/usr/bin/env bash\n"
                "if [[ \"${1:-}\" == \"--version\" ]]; then echo 'coding-tools-mcp 0.3.1'; fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            released_binary.chmod(0o755)
            archive = release_dir / "coding-tools-mcp-linux-x86_64.tar.gz"
            with tarfile.open(archive, "w:gz") as bundle:
                bundle.add(payload, arcname=payload.name)
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            (release_dir / "SHA256SUMS").write_text(
                f"{digest}  {archive.name}\n",
                encoding="utf-8",
            )

            working_bundle = root / "working-bundle"
            working_bundle.mkdir()
            shutil.copy2(MANAGE_SCRIPT, working_bundle / "coding-tools-mcp-admin")
            shutil.copy2(REPO_ROOT / "scripts" / "install.sh", working_bundle / "install.sh")
            old_binary = working_bundle / "coding-tools-mcp"
            old_binary.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            old_binary.chmod(0o755)

            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            (fake_bin / "systemctl").write_text(
                "#!/usr/bin/env bash\n"
                "if [[ \"${1:-}\" == \"is-active\" ]]; then exit 1; fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            (fake_bin / "curl").write_text(
                "#!/usr/bin/env bash\n"
                "for arg in \"$@\"; do\n"
                "  if [[ \"$arg\" == file://* ]]; then exec /usr/bin/curl \"$@\"; fi\n"
                "done\n"
                "exit 0\n",
                encoding="utf-8",
            )
            (fake_bin / "systemctl").chmod(0o755)
            (fake_bin / "curl").chmod(0o755)

            config_dir = root / "etc" / "coding-tools-mcp"
            config_dir.mkdir(parents=True)
            env_file = config_dir / "coding-tools-mcp.env"
            state_dir = root / "state"
            workspace = root / "workspace"
            workspace.mkdir()
            env_file.write_text(
                'CODING_TOOLS_MCP_AUTH_MODE="oauth"\n'
                'CODING_TOOLS_MCP_PERMISSION_MODE="safe"\n'
                f'CODING_TOOLS_MCP_WORKSPACE="{workspace}"\n'
                'CODING_TOOLS_MCP_HOST="127.0.0.1"\n'
                'CODING_TOOLS_MCP_PORT="18765"\n'
                'CODING_TOOLS_MCP_SERVER_URL="https://cd.had.li"\n'
                f'CODING_TOOLS_MCP_STATE_DIR="{state_dir}"\n'
                'CODING_TOOLS_MCP_OAUTH_ACCESS_TOKEN_TTL="3600"\n'
                'CODING_TOOLS_MCP_OAUTH_REFRESH_TOKEN_TTL="7776000"\n'
                'CODING_TOOLS_MCP_OAUTH_PASSWORD="test-password"\n'
                f'CODING_TOOLS_MCP_OAUTH_TOKEN_SECRET="{bytes(range(32)).hex()}"\n'
                'CODING_TOOLS_MCP_AUTH_TOKEN=""\n',
                encoding="utf-8",
            )
            env_file.chmod(0o600)
            unit_file = root / "coding-tools-mcp.service"
            result = subprocess.run(
                [str(working_bundle / "coding-tools-mcp-admin"), "update"],
                cwd=working_bundle,
                env={
                    **os.environ,
                    "PATH": f"{fake_bin}:{os.environ.get('PATH', '')}",
                    "CODING_TOOLS_MCP_RELEASE_BASE_URL": release_dir.as_uri(),
                    "CODING_TOOLS_MCP_CONFIG_DIR": str(config_dir),
                    "CODING_TOOLS_MCP_ENV_FILE": str(env_file),
                    "CODING_TOOLS_MCP_UNIT_FILE": str(unit_file),
                    "CODING_TOOLS_MCP_PERSISTENT_ROOT": str(root / "opt"),
                    "PYTHON": os.path.realpath(sys.executable),
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("程序和运维脚本已更新到最新 Release", result.stdout)
            self.assertIn("coding-tools-mcp 0.3.1", old_binary.read_text(encoding="utf-8"))
            self.assertTrue((root / "opt" / "bin" / "coding-tools-mcp").is_file())


if __name__ == "__main__":
    unittest.main()
