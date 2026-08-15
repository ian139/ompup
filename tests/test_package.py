from __future__ import annotations

import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PackageContractTests(unittest.TestCase):
    def test_publish_files_are_allowlisted(self) -> None:
        package = json.loads((ROOT / "package.json").read_text())
        self.assertEqual(
            package["files"],
            [
                "bin/ompup",
                "src/ompup/*.py",
                "extension/index.ts",
                "README.md",
                "LICENSE",
            ],
        )

    def test_python_caches_are_ignored(self) -> None:
        ignored = set((ROOT / ".gitignore").read_text().splitlines())
        self.assertIn("__pycache__/", ignored)
        self.assertIn("*.pyc", ignored)


if __name__ == "__main__":
    unittest.main()
