"""Every Python file that runs on an agent box must parse on Python 3.10.

10.10.2026: agents on Ubuntu 22.04 run Python 3.10. agent-kit/bin/job-fail-watch.py
used a backslash inside an f-string expression (legal only from 3.12), so on four
agents the failed-job watchdog died with SyntaxError on every cron run since install
-- failed jobs were never reported to the owners.
"""
import ast
import io
import shutil
import subprocess
import sys
import tokenize
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AGENT_SIDE_GLOBS = ("agent-kit/**/*.py", "scripts/*.py")
PY310 = shutil.which("python3.10")


def agent_side_files() -> list[Path]:
    out: set[Path] = set()
    for pattern in AGENT_SIDE_GLOBS:
        out.update(p for p in ROOT.glob(pattern) if "__pycache__" not in p.parts)
    return sorted(out)


def fstring_backslash_lines(src: str) -> list[int]:
    """Lines with a backslash inside an f-string expression (a 3.12-only form)."""
    bad, depth = [], 0
    for tok in tokenize.generate_tokens(io.StringIO(src).readline):
        name = tokenize.tok_name[tok.type]
        if name == "FSTRING_START":
            depth += 1
        elif name == "FSTRING_END":
            depth -= 1
        elif depth and name != "FSTRING_MIDDLE" and "\\" in tok.string:
            bad.append(tok.start[0])
    return bad


class AgentSidePython310(unittest.TestCase):
    def test_files_found(self) -> None:
        self.assertTrue(any(p.name == "job-fail-watch.py" for p in agent_side_files()))

    def test_no_fstring_backslash(self) -> None:
        bad = {}
        for p in agent_side_files():
            lines = fstring_backslash_lines(p.read_text(encoding="utf-8"))
            if lines:
                bad[str(p.relative_to(ROOT))] = lines
        self.assertEqual(bad, {})

    @unittest.skipUnless(PY310, "python3.10 not installed")
    def test_parses_on_python310(self) -> None:
        failed = []
        for p in agent_side_files():
            r = subprocess.run([PY310, "-c", "import ast,sys; ast.parse(open(sys.argv[1]).read())",
                                str(p)], capture_output=True, text=True)
            if r.returncode != 0:
                failed.append(str(p.relative_to(ROOT)))
        self.assertEqual(failed, [])

    # Before 3.12 an f-string is one STRING token, so the detector cannot see inside it;
    # on those boxes test_parses_on_python310 is the real check (Smith, 19.10.2026).
    @unittest.skipIf(sys.version_info < (3, 12), "f-string tokens exist only from 3.12")
    def test_detector_catches_the_10_10_form(self) -> None:
        src = "x = f\"{a}|{re.sub(r'\\\\d+', 'N', b)}\"\n"
        self.assertEqual(fstring_backslash_lines(src), [1])
        ast.parse(src)  # still valid on the dev box (3.12) -- that is why it slipped


if __name__ == "__main__":
    unittest.main()
