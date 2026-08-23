import os
import re
import unittest
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]


class LinkParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            href = dict(attrs).get("href")
            if href:
                self.links.append(href)


def local_target(source: Path, raw: str):
    if raw.startswith(("http://", "https://", "mailto:", "#")):
        return None
    path = unquote(raw.split("#", 1)[0])
    return (source.parent / path).resolve()


class RepositoryLayoutTests(unittest.TestCase):
    def test_root_contains_no_loose_implementation_or_review_files(self):
        loose = sorted(
            path.name
            for path in ROOT.iterdir()
            if path.is_file() and path.suffix in {".sh", ".ps1", ".html"}
        )
        self.assertEqual(loose, [])

    def test_operational_documents_keep_their_caps_names(self):
        self.assertTrue((ROOT / "docs" / "HANDOFF.md").is_file())
        self.assertTrue((ROOT / "docs" / "VERIFICATION.md").is_file())
        self.assertFalse((ROOT / "HANDOFF.md").exists())
        self.assertFalse((ROOT / "VERIFICATIE.md").exists())

    def test_public_and_internal_shell_entrypoints_are_executable(self):
        paths = [ROOT / "bin" / "sandbox"]
        paths.extend((ROOT / "scripts" / "policy").glob("*.sh"))
        paths.extend((ROOT / "scripts" / "trial").glob("*.sh"))
        paths.extend((ROOT / "test-lab").rglob("*.sh"))
        not_executable = [
            str(path.relative_to(ROOT))
            for path in paths
            if not os.access(path, os.X_OK)
        ]
        self.assertEqual(not_executable, [])

    def test_local_markdown_and_html_links_exist(self):
        missing = []
        markdown_pattern = re.compile(r"(?<!!)\[[^]]+\]\(([^)]+)\)")
        for source in (ROOT / "README.md", *ROOT.rglob("*.md")):
            if "evidence/runs" in source.as_posix():
                continue
            for raw in markdown_pattern.findall(source.read_text()):
                target = local_target(source, raw.strip("<>"))
                if target is not None and not target.exists():
                    missing.append(f"{source.relative_to(ROOT)} -> {raw}")

        for source in (ROOT / "docs" / "reviews").glob("*.html"):
            parser = LinkParser()
            parser.feed(source.read_text())
            for raw in parser.links:
                target = local_target(source, raw)
                if target is not None and not target.exists():
                    missing.append(f"{source.relative_to(ROOT)} -> {raw}")

        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
