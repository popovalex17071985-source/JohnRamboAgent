#!/usr/bin/env python3
"""PreToolUse -> Bash. A `git commit` that changes code must carry a test (exit 2 = block).

Why: 09.10.2026 two plugin fixes shipped to every agent were written first and
checked afterwards in a scratch dir; no test landed in the repo. The owner asked
for TDD to hold wherever it always should. A rule line did not hold, so this is
a gate, and the kit ships it to every agent.

Passes when any of:
- the commit has no code files (docs, config, data);
- the commit itself adds/changes a test file;
- an earlier commit on the current branch (since it left main) touched a test;
- on the trunk itself: a test in a commit not yet pushed, from the last 6 hours;
- the message carries «Без теста: <reason>» -- one-off scripts, configs, hotfix
  of a non-code nature. The reason stays in history.
"""
from __future__ import annotations

import json
import re
import shlex
import subprocess
import sys
from pathlib import Path

CODE_EXT = (".py", ".ts", ".tsx", ".js", ".mjs", ".cjs", ".sh")
TEST_RX = re.compile(r"(^|/)(tests?|__tests__)/|(^|/)test_[^/]+$|_test\.\w+$|\.(test|spec)\.\w+$")
REASON_RX = re.compile(r"Без теста:[ \t]*\w")
MAIN_REFS = ("main", "origin/main", "fork/main", "master")
TRUNK_TEST_WINDOW = "6.hours.ago"


def git(repo: str, *args: str) -> str:
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def segments(command: str) -> list[list[str]]:
    """Shell command split into argv per simple command (&&, ||, ;, newline)."""
    out = []
    for part in re.split(r"&&|\|\||;|\n", command):
        try:
            argv = shlex.split(part)
        except ValueError:
            argv = part.split()
        if argv:
            out.append(argv)
    return out


def repo_of(argv: list[str], cwd: str) -> str:
    if "-C" in argv:
        i = argv.index("-C")
        if i + 1 < len(argv):
            p = Path(argv[i + 1])
            return str(p if p.is_absolute() else Path(cwd) / p)
    return cwd


def subcommand(argv: list[str]) -> str:
    """git's subcommand, skipping global options (-C <dir>, -c <k=v>, --flags)."""
    i = 1
    while i < len(argv):
        a = argv[i]
        if a in ("-C", "-c", "--git-dir", "--work-tree"):
            i += 2
        elif a.startswith("-"):
            i += 1
        else:
            return a
    return ""


def pending_adds(repo: str, argv: list[str]) -> set[str]:
    """Files a `git add` that has not run yet (PreToolUse) will stage."""
    specs = [a for a in argv[argv.index("add") + 1:] if not a.startswith("-")]
    if not specs or "-A" in argv or "--all" in argv:
        specs = ["."]
    return set(git(repo, "ls-files", "-m", "-o", "--exclude-standard", "--", *specs).split())


# `git commit` options that take the next argv word as their value.
COMMIT_VALUE_OPTS = {"-m", "-F", "-C", "-c", "-t", "--message", "--file", "--author", "--date",
                     "--template", "--reuse-message", "--reedit-message", "--fixup", "--squash",
                     "--cleanup", "--trailer", "--pathspec-from-file"}


def commit_pathspecs(after: list[str]) -> list[str]:
    """Paths given to `git commit <paths>` -- committed straight from the work tree."""
    out: list[str] = []
    i = 0
    while i < len(after):
        a = after[i]
        if a == "--":
            out += after[i + 1:]
            break
        if a in COMMIT_VALUE_OPTS:
            i += 2
            continue
        if not a.startswith("-"):
            out.append(a)
        i += 1
    return out


def changed_files(repo: str, argv: list[str], added: set[str]) -> list[str]:
    files = set(git(repo, "diff", "--cached", "--name-only").split()) | added
    after = argv[argv.index("commit") + 1:]
    paths = commit_pathspecs(after)
    if paths:
        files |= set(git(repo, "ls-files", "-m", "-o", "--exclude-standard", "--", *paths).split())
    if any(a == "--all" or (re.fullmatch(r"-[a-zA-Z]+", a) and "a" in a) for a in after):
        files |= set(git(repo, "diff", "--name-only").split())
    return sorted(files)


def unpushed_has_test(repo: str) -> bool:
    """On the trunk itself (personal repos commit straight to master): a test in a
    commit not yet pushed to the upstream counts, like a test earlier on a branch."""
    if not git(repo, "rev-parse", "--abbrev-ref", "@{u}").strip():
        return False
    # Only recent ones: a long-unpushed master would otherwise cover anything.
    names = git(repo, "log", f"--since={TRUNK_TEST_WINDOW}", "--name-only", "--format=",
                "@{u}..HEAD").split()
    return any(TEST_RX.search(n) for n in names)


def branch_has_test(repo: str) -> bool:
    for ref in MAIN_REFS:
        base = git(repo, "merge-base", "HEAD", ref).strip()
        if base:
            head = git(repo, "rev-parse", "HEAD").strip()
            if base == head:
                return unpushed_has_test(repo)
            names = git(repo, "diff", "--name-only", f"{base}..HEAD").split()
            return any(TEST_RX.search(n) for n in names)
    return False


def main() -> int:
    data = json.load(sys.stdin)
    command = (data.get("tool_input") or {}).get("command") or ""
    cwd = data.get("cwd") or "."
    added: dict[str, set[str]] = {}
    for argv in segments(command):
        if argv[0] == "cd" and len(argv) > 1:
            p = Path(argv[1]).expanduser()
            cwd = str(p if p.is_absolute() else Path(cwd) / p)
            continue
        if argv[0] != "git":
            continue
        repo = repo_of(argv, cwd)
        sub = subcommand(argv)
        if sub == "add":
            added.setdefault(repo, set()).update(pending_adds(repo, argv))
            continue
        if sub != "commit" or not git(repo, "rev-parse", "--git-dir"):
            continue
        files = changed_files(repo, argv, added.get(repo, set()))
        code = [f for f in files if f.endswith(CODE_EXT) and not TEST_RX.search(f)]
        if not code or any(TEST_RX.search(f) for f in files):
            continue
        if REASON_RX.search(command) or branch_has_test(repo):
            continue
        print(
            "TDD-гейт: в коммите меняется код (" + ", ".join(code[:5]) + "), а теста нет ни в нём, "
            "ни раньше в этой ветке. Сначала тест, который падает, потом код. Если тест здесь "
            "правда не нужен (разовый скрипт, конфиг) -- добавь в сообщение строку "
            "«Без теста: <причина>».",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
