"""Copy-safety of the owner guides (HTML + PDF).

The owner selects a command block in the PDF, copies it and pastes it into a
terminal. That only works if the PDF text layer carries the command exactly:
one line, plain ASCII spaces and quotes, no ligatures, no soft hyphens. On
02.10.2026 a long curl line from the PDF wrapped, pasted as two commands and
came back as 404 — so every command must survive a round trip through the
PDF text layer unchanged.

Checks per guide:
  * every <pre class="cmd"> holds one short command with no typographic
    characters (static check on the HTML);
  * the same string is an exact line of `pdftotext -raw` output, and of
    pdfminer / pypdf output when those libraries are importable.

Run: python3 tests/test_guides_copy_safe.py   (rebuild PDFs first:
node docs/build-guides.mjs).
"""

from __future__ import annotations

import shutil
import subprocess
import unittest
from html.parser import HTMLParser
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
GUIDES = (
    REPO_ROOT / "docs" / "install-guide" / "install-guide.html",
    REPO_ROOT / "docs" / "restore-guide" / "restore-guide.html",
)
MAX_COMMAND_LEN = 80  # fits one line at A4 width in the guide's mono font

# Characters that look right on paper but break a shell command when pasted.
BAD_CHARS = {
    " ": "no-break space",
    " ": "narrow no-break space",
    " ": "thin space",
    "​": "zero-width space",
    "‌": "zero-width non-joiner",
    "‍": "zero-width joiner",
    "⁠": "word joiner",
    "﻿": "byte order mark",
    "­": "soft hyphen",
    "‐": "hyphen",
    "‑": "non-breaking hyphen",
    "‒": "figure dash",
    "–": "en dash",
    "—": "em dash",
    "−": "minus sign",
    "‘": "left single quote",
    "’": "right single quote",
    "‚": "low single quote",
    "“": "left double quote",
    "”": "right double quote",
    "„": "low double quote",
    "«": "guillemet",
    "»": "guillemet",
    "…": "ellipsis",
    "\t": "tab",
}
LIGATURES = {chr(c) for c in range(0xFB00, 0xFB07)}


class _CmdParser(HTMLParser):
    """Collects the text of every <pre class="cmd"> (nested spans included)."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.commands: list[str] = []
        self._depth = 0
        self._buf: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        classes = (dict(attrs).get("class") or "").split()
        if tag == "pre" and "cmd" in classes:
            self._depth = 1
            self._buf = []
        elif self._depth:
            self._depth += 1

    def handle_endtag(self, tag: str) -> None:
        if not self._depth:
            return
        self._depth -= 1
        if self._depth == 0:
            self.commands.append("".join(self._buf))

    def handle_data(self, data: str) -> None:
        if self._depth:
            self._buf.append(data)


def commands_of(guide: Path) -> list[str]:
    parser = _CmdParser()
    parser.feed(guide.read_text(encoding="utf-8"))
    return parser.commands


def problems_in_command(cmd: str) -> list[str]:
    found = [f"{name} U+{ord(ch):04X}" for ch, name in BAD_CHARS.items() if ch in cmd]
    found += [f"ligature U+{ord(ch):04X}" for ch in LIGATURES if ch in cmd]
    if "\n" in cmd or "\r" in cmd:
        found.append("more than one line")
    if cmd != cmd.strip():
        found.append("leading/trailing whitespace")
    if cmd.startswith(("$ ", "# ", "> ")):
        found.append("prompt symbol at the start")
    if len(cmd) > MAX_COMMAND_LEN:
        found.append(f"too long ({len(cmd)} > {MAX_COMMAND_LEN})")
    if not cmd:
        found.append("empty")
    return found


def pdf_lines_pdftotext(pdf: Path) -> list[str]:
    out = subprocess.run(
        ["pdftotext", "-raw", "-enc", "UTF-8", str(pdf), "-"],
        check=True, capture_output=True, text=True,
    ).stdout
    return out.splitlines()


def pdf_lines_pdfminer(pdf: Path) -> list[str] | None:
    try:
        from pdfminer.high_level import extract_text  # type: ignore[import-not-found]
    except ImportError:
        return None
    return extract_text(str(pdf)).splitlines()


def pdf_lines_pypdf(pdf: Path) -> list[str] | None:
    try:
        from pypdf import PdfReader  # type: ignore[import-not-found]
    except ImportError:
        return None
    reader = PdfReader(str(pdf))
    return "\n".join(page.extract_text() or "" for page in reader.pages).splitlines()


EXTRACTORS = (
    ("pdftotext -raw", pdf_lines_pdftotext),
    ("pdfminer", pdf_lines_pdfminer),
    ("pypdf", pdf_lines_pypdf),
)


class GuidesCopySafe(unittest.TestCase):
    def test_html_commands_are_clean(self) -> None:
        for guide in GUIDES:
            cmds = commands_of(guide)
            self.assertGreater(len(cmds), 3, f"{guide.name}: no command blocks found")
            raw = guide.read_text(encoding="utf-8")
            self.assertNotIn("&nbsp;", raw, f"{guide.name}: &nbsp; in the page")
            for cmd in cmds:
                with self.subTest(guide=guide.name, cmd=cmd):
                    self.assertEqual(problems_in_command(cmd), [])

    @unittest.skipUnless(shutil.which("pdftotext"), "pdftotext (poppler-utils) not installed")
    def test_pdf_text_has_every_command_as_exact_line(self) -> None:
        for guide in GUIDES:
            pdf = guide.with_suffix(".pdf")
            self.assertTrue(pdf.exists(), f"{pdf} missing: node docs/build-guides.mjs")
            self.assertGreaterEqual(pdf.stat().st_mtime, guide.stat().st_mtime - 1,
                                    f"{pdf.name} is older than {guide.name}: rebuild it")
            for name, extract in EXTRACTORS:
                lines = extract(pdf)
                if lines is None:
                    continue
                stripped = {line.rstrip("\n") for line in lines}
                for cmd in commands_of(guide):
                    with self.subTest(guide=guide.name, extractor=name, cmd=cmd):
                        self.assertIn(cmd, stripped)


def main() -> int:
    """Human-readable report: one line per command and extractor."""
    total = bad = 0
    for guide in GUIDES:
        pdf = guide.with_suffix(".pdf")
        extracted = {name: fn(pdf) for name, fn in EXTRACTORS} if pdf.exists() else {}
        used = [name for name, lines in extracted.items() if lines is not None]
        print(f"== {guide.relative_to(REPO_ROOT)}  (extractors: {', '.join(used) or 'none'})")
        for cmd in commands_of(guide):
            total += 1
            issues = problems_in_command(cmd)
            for name in used:
                if cmd not in set(extracted[name]):
                    issues.append(f"not an exact line in {name}")
            bad += bool(issues)
            print(f"  {'OK  ' if not issues else 'FAIL'} {cmd}" + (f"  <- {'; '.join(issues)}" if issues else ""))
    print(f"{total} commands checked, {total - bad} OK, {bad} FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
