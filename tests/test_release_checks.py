from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from scripts.check_release_versions import validate_release


class ReleaseMetadataTests(unittest.TestCase):
    def _write_release_tree(
        self,
        root: Path,
        *,
        project_version: str = "0.2.0",
        module_version: str = "0.2.0",
        npm_version: str = "0.1.0",
        changelog: str = "# Changelog\n\n## 0.2.0 - 2026-07-24\n",
    ) -> None:
        (root / "coding_tools_mcp").mkdir(parents=True)
        (root / "packages" / "npm-launcher").mkdir(parents=True)
        (root / "pyproject.toml").write_text(
            f'[project]\nversion = "{project_version}"\n', encoding="utf-8"
        )
        (root / "coding_tools_mcp" / "__init__.py").write_text(
            f'__version__ = "{module_version}"\n', encoding="utf-8"
        )
        (root / "packages" / "npm-launcher" / "package.json").write_text(
            json.dumps({"version": npm_version}), encoding="utf-8"
        )
        (root / "CHANGELOG.md").write_text(changelog, encoding="utf-8")

    def test_release_metadata_accepts_matching_stable_versions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_release_tree(root)
            self.assertEqual(validate_release(root, "v0.2.0"), ("0.2.0", "0.1.0"))

    def test_release_metadata_rejects_unreleased_section(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_release_tree(
                root,
                changelog="# Changelog\n\n## Unreleased\n\n## 0.2.0 - 2026-07-24\n",
            )
            with self.assertRaisesRegex(SystemExit, "Unreleased"):
                validate_release(root, "v0.2.0")

    def test_release_metadata_rejects_prerelease_npm_version(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_release_tree(root, npm_version="0.1.0-beta.1")
            with self.assertRaisesRegex(SystemExit, "not stable"):
                validate_release(root, "v0.2.0")

    def test_release_metadata_rejects_a_stale_checked_in_uv_lock(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_release_tree(root)
            (root / "uv.lock").write_text(
                """version = 1

[[package]]
name = "coding-tools-mcp"
version = "0.1.0"
source = { editable = "." }
""",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(SystemExit, "uv.lock project version"):
                validate_release(root, "v0.2.0")

    def test_release_metadata_rejects_uv_lock_dev_dependency_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_release_tree(root)
            (root / "pyproject.toml").write_text(
                """[project]
version = "0.2.0"

[project.optional-dependencies]
dev = ["mcp>=2.0", "PyYAML>=6.0"]
""",
                encoding="utf-8",
            )
            (root / "uv.lock").write_text(
                """version = 1

[[package]]
name = "coding-tools-mcp"
version = "0.2.0"
source = { editable = "." }

[package.optional-dependencies]
dev = [{ name = "mcp" }]
""",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(SystemExit, "uv.lock dev dependencies"):
                validate_release(root, "v0.2.0")

    def test_release_metadata_normalizes_uv_lock_dev_dependency_names(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_release_tree(root)
            (root / "pyproject.toml").write_text(
                """[project]
version = "0.2.0"

[project.optional-dependencies]
dev = ["typing_extensions>=4.0", "PyYAML>=6.0"]
""",
                encoding="utf-8",
            )
            (root / "uv.lock").write_text(
                """version = 1

[[package]]
name = "coding-tools-mcp"
version = "0.2.0"
source = { editable = "." }

[package.optional-dependencies]
dev = [{ name = "typing-extensions" }, { name = "pyyaml" }]
""",
                encoding="utf-8",
            )
            self.assertEqual(validate_release(root, "v0.2.0"), ("0.2.0", "0.1.0"))


class RepositoryHygieneTests(unittest.TestCase):
    def test_cloudflare_local_secret_files_are_ignored_after_infra_move(self) -> None:
        root = Path(__file__).resolve().parents[1]
        paths = [
            "infra/cloudflare/sandbox-control/.dev.vars",
            "infra/cloudflare/sandbox-control/.dev.vars.local",
            "infra/cloudflare/sandbox-control/.env",
            "infra/cloudflare/sandbox-control/.env.local",
        ]
        for path in paths:
            with self.subTest(path=path):
                result = subprocess.run(
                    ["git", "check-ignore", "--quiet", "--no-index", path],
                    cwd=root,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, f"{path} must be ignored")

if __name__ == "__main__":
    unittest.main()
