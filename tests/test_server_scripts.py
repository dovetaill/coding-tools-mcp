from __future__ import annotations

import os
import subprocess
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
        self.assertIn("verify", result.stdout)
        self.assertIn("clean", result.stdout)

    def test_manage_script_help_lists_operations(self) -> None:
        result = self.run_script(MANAGE_SCRIPT, "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("中文交互式运维工具", result.stdout)
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


if __name__ == "__main__":
    unittest.main()
