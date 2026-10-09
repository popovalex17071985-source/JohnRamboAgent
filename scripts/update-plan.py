#!/usr/bin/env python3
"""update-plan.py -- what /update would change, in plain words, and a choice.

Runs as the agent's service user (no root). The plugin runs the FETCH_HEAD copy
of this file (`git show FETCH_HEAD:scripts/update-plan.py | python3 - ...`), so
the update logic ships with the update itself.

Units:
  * KIT unit    -- one kit file (agent-kit/hooks/*, bin/*, agents/*,
                   core/constitution.md) at the path install-kit.sh renders it to.
                   Installed or skipped one by one.
  * BRIDGE unit -- every other change of the repo. All or nothing: moving HEAD.

Subcommands (JSON on stdout unless noted):
  plan                      numbered plan, saved to $WORKSPACE/state/update-plan.json
  auto                      bare /update: install a fresh saved plan (apply keep),
                            else show the plan
  apply all|keep|N [M ...]  install (keep = all except items with the owner's tweaks)
  skip N [M ...]            do not install and never offer again (until it changes)
  skipped                   what was skipped
  unskip all                forget every skip
  notify [--sent]           plain text for the daily advisor, only when changed
  scan                      read-only JSON report of what the agent carries of its own
                            (see --help); writes nothing, fetches nothing

Local commits (the owner's own commits on top of the installed version) are
carried over: «своё не трогать» and the no-questions path replay them on top of
the update. Only a commit that does not replay cleanly is the owner's thing to
ask about; if the replay fails at install time, the repo stays as it was and
$WORKSPACE/state/update-blocked.json tells the developer.

Notes shown to the owner per commit, by priority: a `Хозяину:` trailer line in
the commit message; update-notes.json (sha prefix -> text) in FETCH_HEAD; the
commit subject. The text "-" hides the commit.
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Tuple

DEFAULT_REF = "FETCH_HEAD"
CONSTITUTION = "agent-kit/core/constitution.md"
KIT_TREE_ARGS = ("agent-kit/hooks/", "agent-kit/bin/", "agent-kit/agents/", CONSTITUTION)
KIT_LOG_PATHS = ("agent-kit/hooks", "agent-kit/bin", "agent-kit/agents", CONSTITUTION)
IGNORED_REPO_PATHS = frozenset({"plugin/bun.lock"})
NOTES_FILE = "update-notes.json"
TRAILER = "Хозяину:"
HIDE = "-"
GENERIC_NOTE = "Мелкие исправления в работе агента"
HISTORY_DEPTH = 300
MAX_TWEAK_LINES = 3
MAX_TWEAK_LINE_CHARS = 80
TEXT_BUDGET = 3800
SHA_KEY = re.compile(r"[0-9a-f]{7,40}")


# ─────────────────────────────────────────────────────────────────────────────
# git
# ─────────────────────────────────────────────────────────────────────────────


class GitError(RuntimeError):
    pass


class Git:
    """Thin git wrapper with one long-lived `cat-file --batch` for blobs."""

    def __init__(self, repo: Path) -> None:
        self.repo = repo
        self._batch: subprocess.Popen[bytes] | None = None

    def run(self, *args: str, env: dict[str, str] | None = None) -> str:
        res = subprocess.run(["git", "-C", str(self.repo), *args],
                             capture_output=True, text=True, env=env)
        if res.returncode != 0:
            raise GitError(f"git {' '.join(args)}: {res.stderr.strip()}")
        return res.stdout

    def ok(self, *args: str) -> bool:
        return subprocess.run(["git", "-C", str(self.repo), *args],
                              capture_output=True).returncode == 0

    def rev(self, ref: str) -> str | None:
        res = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "-q", "--verify",
                              f"{ref}^{{commit}}"], capture_output=True, text=True)
        return res.stdout.strip() if res.returncode == 0 else None

    def blob(self, sha: str) -> bytes:
        if self._batch is None:
            self._batch = subprocess.Popen(
                ["git", "-C", str(self.repo), "cat-file", "--batch"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        assert self._batch.stdin is not None and self._batch.stdout is not None
        self._batch.stdin.write(sha.encode() + b"\n")
        self._batch.stdin.flush()
        header = self._batch.stdout.readline().split()
        if len(header) < 3 or header[1] == b"missing":
            raise GitError(f"blob {sha} missing")
        data = self._batch.stdout.read(int(header[2]))
        self._batch.stdout.read(1)
        return data

    def tree_blobs(self, ref: str, *paths: str) -> dict[str, str]:
        """path -> blob sha for blobs directly listed under `paths` at `ref`."""
        out: dict[str, str] = {}
        try:
            raw = self.run("ls-tree", "-z", ref, "--", *paths)
        except GitError:
            return out
        for entry in raw.split("\0"):
            if not entry:
                continue
            meta, _, path = entry.partition("\t")
            parts = meta.split()
            if len(parts) == 3 and parts[1] == "blob":
                out[path] = parts[2]
        return out

    def file_blob(self, ref: str, path: str) -> str | None:
        return self.tree_blobs(ref, path).get(path)

    def entry(self, ref: str, path: str) -> tuple[str, str] | None:
        """(mode, sha) of one path at ref, any object type."""
        try:
            raw = self.run("ls-tree", "-z", ref, "--", path)
        except GitError:
            return None
        for item in raw.split("\0"):
            meta, _, name = item.partition("\t")
            parts = meta.split()
            if name == path and len(parts) == 3:
                return parts[0], parts[2]
        return None

    def close(self) -> None:
        if self._batch is not None:
            if self._batch.stdin:
                self._batch.stdin.close()
            self._batch.wait()
            self._batch = None


# ─────────────────────────────────────────────────────────────────────────────
# context, state
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class Ctx:
    repo: Path
    claude_dir: Path
    workspace: Path
    agent: str
    chat_id: str
    tz: str
    settings: Path
    ref: str
    git: Git
    branch: str = ""
    expect: str = ""   # a button press: the fetch_head prefix of the plan it was shown with

    @property
    def state_dir(self) -> Path:
        return self.workspace / "state"

    def state_file(self, name: str) -> Path:
        return self.state_dir / name

    def load(self, name: str, default: Any) -> Any:
        try:
            return json.loads(self.state_file(name).read_text())
        except (OSError, ValueError):
            return default

    def save(self, name: str, data: Any) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        path = self.state_file(name)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n")
        os.replace(tmp, path)

    def render(self, data: bytes) -> bytes:
        """Same substitution as install-kit.sh render() (sed, in this order)."""
        for key, val in (("__CLAUDE_DIR__", str(self.claude_dir)),
                         ("__WORKSPACE__", str(self.workspace)),
                         ("__CHAT_ID__", self.chat_id),
                         ("__AGENT__", self.agent)):
            data = data.replace(key.encode(), val.encode())
        return data

    def kit_target(self, path: str) -> Path | None:
        if path == CONSTITUTION:
            return self.claude_dir / "core" / "constitution.md"
        folder, _, name = path.rpartition("/")
        if folder == "agent-kit/hooks":
            return self.claude_dir / "hooks" / name
        if folder == "agent-kit/bin":
            return self.workspace / "bin" / name
        if folder == "agent-kit/agents":
            return self.claude_dir / "agents" / name
        return None

    def shown(self, target: Path) -> str:
        """Target path as the owner sees it: relative to the workspace."""
        try:
            return str(target.relative_to(self.workspace))
        except ValueError:
            return str(target)


def esc(text: str) -> str:
    return html.escape(text, quote=False)


def read_bytes(path: Path) -> bytes | None:
    try:
        return path.read_bytes() if path.is_file() else None
    except OSError:
        return None


# ─────────────────────────────────────────────────────────────────────────────
# commits and notes
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class Commit:
    sha: str
    merge: bool
    body: str
    paths: list[str] = field(default_factory=list)


def pending_commits(ctx: Ctx) -> list[Commit]:
    """Commits in HEAD..ref, oldest first."""
    rng = f"HEAD..{ctx.ref}"
    commits: dict[str, Commit] = {}
    order: list[str] = []
    for line in ctx.git.run("log", "--format=%H %P", rng).splitlines():
        parts = line.split()
        if parts:
            commits[parts[0]] = Commit(parts[0], len(parts) > 2, "")
            order.append(parts[0])
    for chunk in ctx.git.run("log", "--format=%H%x1f%B%x1e", rng).split("\x1e"):
        sha, sep, body = chunk.strip("\n").partition("\x1f")
        if sep and sha in commits:
            commits[sha].body = body.strip()
    current: Commit | None = None
    for line in ctx.git.run("log", "--format=%x01%H", "--name-only", "--no-renames",
                            rng).splitlines():
        if line.startswith("\x01"):
            current = commits.get(line[1:])
        elif line and current is not None:
            current.paths.append(line)
    return [commits[sha] for sha in reversed(order)]


def load_notes(ctx: Ctx) -> dict[str, str]:
    try:
        raw = json.loads(ctx.git.run("show", f"{ctx.ref}:{NOTES_FILE}"))
    except (GitError, ValueError):
        return {}
    if not isinstance(raw, dict):
        return {}
    return {k.lower(): str(v) for k, v in raw.items()
            if isinstance(k, str) and SHA_KEY.fullmatch(k.lower())}


def note_for(commit: Commit, notes: dict[str, str]) -> str | None:
    """Plain note for the owner; None = hidden."""
    for line in commit.body.splitlines():
        line = line.strip()
        if line.startswith(TRAILER):
            text = line[len(TRAILER):].strip()
            return None if text == HIDE else text
    for key, text in notes.items():
        if commit.sha.startswith(key):
            text = text.strip()
            return None if text == HIDE else text
    # Not annotated: the subject, never silence. Only an explicit "-" hides.
    subject = commit.body.splitlines()[0].strip() if commit.body else ""
    return subject or GENERIC_NOTE


def is_kit_path(path: str) -> bool:
    if path == CONSTITUTION:
        return True
    folder = path.rpartition("/")[0]
    return folder in ("agent-kit/hooks", "agent-kit/bin", "agent-kit/agents")


def is_bridge_commit(commit: Commit) -> bool:
    """Merges and commits that touch only kit files or only Codex files are not."""
    if commit.merge:
        return False
    return any(not is_kit_path(p) and "codex" not in p.lower() for p in commit.paths)


def kit_history(ctx: Ctx, ref: str | None = None) -> dict[str, list[tuple[str, str, str]]]:
    """path -> [(commit, old blob, new blob)], newest first, along ref's history."""
    hist: dict[str, list[tuple[str, str, str]]] = {}
    try:
        raw = ctx.git.run("log", "--format=%x01%H", "--raw", "--no-abbrev", "--no-renames",
                          "-n", str(HISTORY_DEPTH), ref or ctx.ref, "--", *KIT_LOG_PATHS)
    except GitError:
        return hist
    commit = ""
    for line in raw.splitlines():
        if line.startswith("\x01"):
            commit = line[1:]
        elif line.startswith(":"):
            meta, _, path = line.partition("\t")
            parts = meta.split()
            if len(parts) >= 4:
                hist.setdefault(path, []).append((commit, parts[2], parts[3]))
    return hist


# ─────────────────────────────────────────────────────────────────────────────
# diff summary
# ─────────────────────────────────────────────────────────────────────────────


def summarize(old: bytes | None, new: bytes | None) -> dict[str, Any]:
    a = old.decode("utf-8", "replace").splitlines() if old else []
    b = new.decode("utf-8", "replace").splitlines() if new else []
    added = removed = 0
    lines: list[str] = []
    for line in difflib.unified_diff(a, b, lineterm="", n=0):
        if line.startswith(("+++", "---", "@@")):
            continue
        if line.startswith("+"):
            added += 1
        elif line.startswith("-"):
            removed += 1
        else:
            continue
        body = line[1:].strip()
        if body and len(lines) < MAX_TWEAK_LINES:
            if len(body) > MAX_TWEAK_LINE_CHARS:
                body = body[:MAX_TWEAK_LINE_CHARS - 1] + "…"
            lines.append(f"{line[0]} {body}")
    return {"added": added, "removed": removed, "deleted": new is None, "lines": lines}


# ─────────────────────────────────────────────────────────────────────────────
# plan
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class Plan:
    fetch_head: str
    head: str
    items: list[dict[str, Any]]
    tweaks: list[dict[str, Any]]
    keep_always: list[str]          # kit targets never rendered by a bridge apply
    baselines: dict[str, str]       # kit path -> blob currently installed (if known)
    own_only: int                   # owner tweaks that the update does not touch
    skipped_count: int

    def unit_key(self) -> str:
        ident = [(i["kind"], i.get("path", ""), i.get("blob", ""), i.get("commits", []))
                 for i in self.items]
        return hashlib.sha256(json.dumps(ident).encode()).hexdigest()[:16]


KIT_TITLES = {
    "hooks": "Правило-сторож",
    "bin": "Фоновый скрипт",
    "agents": "Помощник",
}


def kit_title(path: str) -> str:
    if path == CONSTITUTION:
        return "Свод правил агента"
    folder, _, name = path.rpartition("/")
    return f"{KIT_TITLES.get(folder.rpartition('/')[2], 'Файл')} {name}"


FETCH_HEAD_BRANCH = re.compile(r"\tbranch '([^']+)' of ")


def fetch_head_branch(ctx: Ctx) -> str:
    """Branch named in .git/FETCH_HEAD by the last `git fetch origin <branch>`."""
    try:
        rel = ctx.git.run("rev-parse", "--git-path", "FETCH_HEAD").strip()
        first = (ctx.repo / rel).read_text().splitlines()[0]
    except (GitError, OSError, IndexError):
        return ""
    m = FETCH_HEAD_BRANCH.search(first)
    return m.group(1) if m else ""


def ensure_history(ctx: Ctx) -> None:
    """Deepen a shallow fetch that does not reach HEAD.

    The plugin and dashi-ctl fetch with --depth. An agent further behind than
    that has HEAD outside the fetched history: HEAD..FETCH_HEAD is cut at the
    shallow boundary and the plan would be short and wrong.
    """
    if ctx.ref != DEFAULT_REF or ctx.git.ok("merge-base", "--is-ancestor", "HEAD", ctx.ref):
        return
    if ctx.git.run("rev-parse", "--is-shallow-repository").strip() != "true":
        return  # full history and still not an ancestor: local commits, nothing to fetch
    branch = ctx.branch or fetch_head_branch(ctx) or "main"
    ctx.git.close()
    try:
        ctx.git.run("fetch", "-q", "--unshallow", "origin", branch)
    except GitError as err:
        print(f"update-plan: could not deepen history: {err}", file=sys.stderr)


def build_plan(ctx: Ctx) -> Plan:
    ensure_history(ctx)
    fetch_head = ctx.git.rev(ctx.ref)
    head = ctx.git.rev("HEAD")
    if fetch_head is None or head is None:
        raise GitError(f"нет {ctx.ref} или HEAD")
    skipped = ctx.load("update-skipped.json", {})
    skipped_kit: dict[str, str] = skipped.get("kit", {})
    skipped_bridge = set(skipped.get("bridge", []))
    applied: dict[str, str] = ctx.load("update-applied.json", {})
    notes = load_notes(ctx)

    commits = pending_commits(ctx)
    pending = {c.sha for c in commits}
    by_sha = {c.sha: c for c in commits}
    items: list[dict[str, Any]] = []
    tweaks: list[dict[str, Any]] = []
    skipped_count = 0

    # Bridge: every qualifying commit; notes only for the ones not skipped before.
    bridge_all = [c for c in commits if is_bridge_commit(c)]
    bridge_new = [c for c in bridge_all if c.sha not in skipped_bridge]
    if bridge_all and not bridge_new:
        skipped_count += 1
    if bridge_new:
        shown: list[str] = []
        hidden = 0
        for c in bridge_new:
            note = note_for(c, notes)
            if note is None:
                hidden += 1
            elif note not in shown:
                shown.append(note)
        repo_tweaks = repo_tweak_list(ctx)
        local = list(reversed(local_commits(ctx)))           # oldest first
        replays = replay_check(ctx, fetch_head, [sha for sha, _ in local])
        # A local commit that goes onto the update cleanly is carried over, not
        # overwritten: not the owner's concern. Only the rest is asked about.
        stuck = [(sha, s) for (sha, s), ok in zip(local, replays) if ok is not True]
        item = {"n": 1, "kind": "bridge", "title": "Основное обновление агента",
                "notes": shown, "hidden": hidden,
                "earlier_skipped": len(bridge_all) - len(bridge_new),
                "commits": [c.sha for c in bridge_all],
                "local": len(local), "local_subjects": [s for _, s in stuck[:MAX_LOCAL_SHOWN]],
                "local_clean": not stuck, "repo_tweak": bool(repo_tweaks),
                "tweak": bool(repo_tweaks or stuck)}
        items.append(item)
        for sha, subject in stuck[:MAX_LOCAL_SHOWN]:
            tweaks.append({"n": 1, "kind": "local", "target": sha[:7], "subject": subject,
                           "added": 0, "removed": 0, "deleted": False, "lines": []})
        for path, summary in repo_tweaks:
            tweaks.append({"n": 1, "target": path, **summary})

    # Kit units.
    fetch_blobs = ctx.git.tree_blobs(ctx.ref, *KIT_TREE_ARGS)
    head_blobs = ctx.git.tree_blobs("HEAD", *KIT_TREE_ARGS)
    history = kit_history(ctx)
    keep_always: list[str] = []
    baselines: dict[str, str] = {}
    own_only = 0
    for path in sorted(fetch_blobs, key=kit_sort_key):
        target = ctx.kit_target(path)
        if target is None:
            continue
        blob = fetch_blobs[path]
        installed = read_bytes(target)
        new = ctx.render(ctx.git.blob(blob))
        baseline = applied.get(path) or head_blobs.get(path)
        if baseline:
            baselines[path] = baseline
        if installed == new:
            continue
        known = {baseline, head_blobs.get(path)}
        known.update(b for _, old, nb in history.get(path, []) for b in (old, nb))
        known.discard(None)
        known = {b for b in known if b and set(b) != {"0"}}
        tweak = installed is not None and not any(
            ctx.render(safe_blob(ctx, b)) == installed for b in known)
        if tweak and blob == baseline:
            # The owner's own change, and upstream did not touch this file:
            # nothing to offer, and a bridge apply must not clobber it.
            own_only += 1
            keep_always.append(str(target))
            continue
        if skipped_kit.get(path) == blob:
            skipped_count += 1
            keep_always.append(str(target))
            continue
        item = {"n": len(items) + 1, "kind": "kit", "path": path, "target": str(target),
                "blob": blob, "baseline": baseline, "title": kit_title(path),
                "notes": kit_notes(path, baseline, history, pending, by_sha, notes),
                "new_file": installed is None, "tweak": tweak}
        items.append(item)
        if tweak:
            old = ctx.render(safe_blob(ctx, baseline)) if baseline else None
            tweaks.append({"n": item["n"], "target": ctx.shown(target),
                           **summarize(old, installed)})

    return Plan(fetch_head, head, items, tweaks, keep_always, baselines, own_only,
                skipped_count)


def safe_blob(ctx: Ctx, sha: str) -> bytes:
    try:
        return ctx.git.blob(sha)
    except GitError:
        return b"\0missing\0"


def kit_sort_key(path: str) -> tuple[int, str]:
    order = {"agent-kit/core": 0, "agent-kit/hooks": 1, "agent-kit/bin": 2, "agent-kit/agents": 3}
    return order.get(path.rpartition("/")[0], 9), path


def kit_notes(path: str, baseline: str | None, history: dict[str, list[tuple[str, str, str]]],
              pending: set[str], by_sha: dict[str, Commit], notes: dict[str, str]) -> list[str]:
    """Notes of the commits that changed this file since what is installed."""
    out: list[str] = []
    for commit, _old, new in history.get(path, []):
        if new == baseline or commit not in pending:
            break
        c = by_sha.get(commit)
        if c is None or c.merge:
            continue
        note = note_for(c, notes)
        if note is not None and note not in out:
            out.append(note)
    out.reverse()
    return out


MAX_LOCAL_SHOWN = 5


def local_commits(ctx: Ctx, base: str | None = None) -> list[tuple[str, str]]:
    """Commits on HEAD that the shared version does not have: local work a reset
    to the update would drop (Albert 09.10.2026, a local feature branch)."""
    try:
        raw = ctx.git.run("log", "--no-merges", "--format=%H%x1f%s", f"{base or ctx.ref}..HEAD")
    except GitError:
        return []
    out = []
    for line in raw.splitlines():
        sha, _, subject = line.partition("\x1f")
        if sha:
            out.append((sha, subject.strip() or sha[:7]))
    return out


def save_local_commits(ctx: Ctx, fetch_head: str) -> tuple[bool, str]:
    """Before a reset: a backup ref and a patch file of the local commits."""
    if not local_commits(ctx, fetch_head):
        return True, ""
    stamp = time.strftime("%Y%m%d-%H%M%S")
    ref = f"refs/dashi-backup/{stamp}"
    patch = ctx.workspace / ".kit-backup" / stamp / "local-commits.patch"
    try:
        ctx.git.run("update-ref", ref, "HEAD")
        patch.parent.mkdir(parents=True, exist_ok=True)
        patch.write_text(ctx.git.run("format-patch", "--stdout", f"{fetch_head}..HEAD"))
    except (GitError, OSError) as err:
        log_update(ctx, f"could not save local commits: {err}")
        return False, ""
    # Paths go to the log (for whoever repairs), not to the owner.
    log_update(ctx, f"local commits saved: {patch} and {ref}")
    return True, "saved"


# ─────────────────────────────────────────────────────────────────────────────
# carrying local commits over (replay on top of the update)
# ─────────────────────────────────────────────────────────────────────────────

Entry = Tuple[str, bytes]           # (git mode, content); a gitlink keeps its sha as content
NULL_SHA = re.compile(r"0+")
BLOCKED_FILE = "update-blocked.json"
REPLAY_COMMITTER = ("dashi-update", "dashi-update@localhost")


def _entry_data(ctx: Ctx, mode: str, sha: str) -> bytes:
    return sha.encode() if mode == "160000" else ctx.git.blob(sha)


def _merge3(base: Entry | None, ours: Entry | None, theirs: Entry | None) -> tuple[Entry | None, bool]:
    """One path of a cherry-pick: ours = the update (+ earlier replays), theirs =
    the local commit, base = its parent. (result, clean)."""
    if ours == theirs:
        return ours, True
    if ours == base:
        return theirs, True
    if theirs == base:
        return ours, True
    if ours is None or theirs is None:
        return None, False                        # changed on one side, deleted on the other
    bmode, bdata = base if base else ("", b"")
    if ours[0] == theirs[0] or theirs[0] == bmode:
        mode = ours[0]
    elif ours[0] == bmode:
        mode = theirs[0]
    else:
        return None, False
    if ours[1] == theirs[1] or theirs[1] == bdata:
        return (mode, ours[1]), True
    if ours[1] == bdata:
        return (mode, theirs[1]), True
    if not mode.startswith("100"):
        return None, False                        # symlink / submodule edited on both sides
    with tempfile.TemporaryDirectory(prefix="dashi-merge-") as tmp:
        files = []
        for name, data in (("ours", ours[1]), ("base", bdata), ("theirs", theirs[1])):
            path = Path(tmp) / name
            path.write_bytes(data)
            files.append(str(path))
        res = subprocess.run(["git", "merge-file", "-p", *files], capture_output=True)
    if res.returncode != 0:
        return None, False                        # conflicts (>0) or binary/error (<0)
    return (mode, res.stdout), True


def replay_check(ctx: Ctx, base: str, shas: list[str]) -> list[bool | None]:
    """Would these commits (oldest first) cherry-pick cleanly onto `base`?

    Read-only: blobs are read, the three-way merge of a file runs on temp copies
    outside the repo. No renames are followed, so a False can be pessimistic;
    the install itself does the real cherry-pick. After the first conflict the
    rest is unknown (None).
    """
    overlay: dict[str, Entry | None] = {}
    out: list[bool | None] = []
    for sha in shas:
        if out and out[-1] is not True:
            out.append(None)
            continue
        parent = ctx.git.rev(f"{sha}^")
        if parent is None:
            out.append(None)
            continue
        try:
            raw = ctx.git.run("diff-tree", "-r", "-z", "--no-renames", "--no-commit-id", parent, sha)
            fields = raw.split("\0")
            clean = True
            for meta, path in zip(fields[0::2], fields[1::2]):
                parts = meta.lstrip(":").split()
                if len(parts) < 5:
                    continue
                omode, nmode, osha, nsha = parts[:4]
                old = None if NULL_SHA.fullmatch(osha) else (omode, _entry_data(ctx, omode, osha))
                new = None if NULL_SHA.fullmatch(nsha) else (nmode, _entry_data(ctx, nmode, nsha))
                if path in overlay:
                    cur = overlay[path]
                else:
                    ent = ctx.git.entry(base, path)
                    cur = (ent[0], _entry_data(ctx, *ent)) if ent else None
                merged, ok = _merge3(old, cur, new)
                if not ok:
                    clean = False
                    break
                overlay[path] = merged
            out.append(clean)
        except GitError:
            out.append(None)
    return out


def commit_files(ctx: Ctx, sha: str) -> list[str]:
    try:
        raw = ctx.git.run("diff-tree", "-r", "-z", "--no-renames", "--no-commit-id",
                          "--name-only", f"{sha}^", sha)
    except GitError:
        return []
    return [p for p in raw.split("\0") if p]


def replay_env(ctx: Ctx) -> dict[str, str]:
    """cherry-pick needs a committer; a server without git identity gets ours."""
    env = dict(os.environ)
    for key, conf, fallback in (("GIT_COMMITTER_NAME", "user.name", REPLAY_COMMITTER[0]),
                                ("GIT_COMMITTER_EMAIL", "user.email", REPLAY_COMMITTER[1])):
        if not env.get(key) and not ctx.git.ok("config", conf):
            env[key] = fallback
    return env


def replay_local(ctx: Ctx, fetch_head: str) -> tuple[str, dict[str, Any] | None]:
    """Cherry-pick the local commits onto fetch_head in a throwaway worktree.

    (target, None): the commit to reset the repo to -- fetch_head with the local
    commits on top (those already in the update are dropped). (fetch_head,
    stuck): the commit that does not go on; the repo itself was never touched.
    """
    own = {sha for sha, _ in local_commits(ctx, fetch_head)}
    try:
        raw = ctx.git.run("cherry", fetch_head, "HEAD")
        picks = [ln[2:].strip() for ln in raw.splitlines() if ln.startswith("+ ")]
    except GitError:
        picks = [sha for sha, _ in reversed(local_commits(ctx, fetch_head))]
    picks = [sha for sha in picks if sha in own]
    if not picks:
        return fetch_head, None
    tmp = Path(tempfile.mkdtemp(prefix="dashi-replay-"))
    wt = tmp / "wt"
    env = replay_env(ctx)
    stuck: str | None = None
    target = fetch_head
    try:
        ctx.git.run("worktree", "add", "-q", "--detach", str(wt), fetch_head)
        side = Git(wt)
        for sha in picks:
            try:
                side.run("-c", "core.hooksPath=/dev/null", "cherry-pick",
                         "--keep-redundant-commits", sha, env=env)
            except GitError as err:
                log_update(ctx, f"local commit {sha[:12]} does not go onto {fetch_head[:12]}: {err}")
                stuck = sha
                break
        if stuck is None:
            target = side.run("rev-parse", "HEAD").strip()
    except GitError as err:
        log_update(ctx, f"replay worktree failed: {err}")
        stuck = picks[0]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        ctx.git.ok("worktree", "prune")
    if stuck is None:
        log_update(ctx, f"local commits carried onto {fetch_head[:12]}: {target[:12]}")
        return target, None
    subject = ctx.git.run("log", "-1", "--format=%s", stuck).strip() or stuck[:7]
    return fetch_head, {"sha": stuck, "subject": subject, "files": commit_files(ctx, stuck)}


def write_blocked(ctx: Ctx, fetch_head: str, stuck: dict[str, Any]) -> None:
    ctx.save(BLOCKED_FILE, {"fetch_head": fetch_head, "local_commits": [stuck],
                            "ts": int(time.time())})


def clear_blocked(ctx: Ctx) -> None:
    try:
        ctx.state_file(BLOCKED_FILE).unlink()
    except FileNotFoundError:
        pass


def log_update(ctx: Ctx, line: str) -> None:
    log = ctx.workspace / "logs" / "update.log"
    try:
        log.parent.mkdir(parents=True, exist_ok=True)
        with log.open("a") as fh:
            fh.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {line}\n")
    except OSError:
        pass


def repo_tweak_list(ctx: Ctx) -> list[tuple[str, dict[str, Any]]]:
    """Repo files the owner changed that a reset to ref would overwrite."""
    changed = set(ctx.git.run("diff", "--name-only", "-z", "--no-renames", "HEAD").split("\0"))
    for path in ctx.git.run("ls-files", "--others", "--exclude-standard", "-z").split("\0"):
        if path and ctx.git.file_blob(ctx.ref, path):
            changed.add(path)
    out: list[tuple[str, dict[str, Any]]] = []
    for path in sorted(p for p in changed if p and p not in IGNORED_REPO_PATHS):
        work = read_bytes(ctx.repo / path)
        upstream_sha = ctx.git.file_blob(ctx.ref, path)
        upstream = ctx.git.blob(upstream_sha) if upstream_sha else None
        if work == upstream:
            continue  # already what the update brings: nothing of the owner's is lost
        head_sha = ctx.git.file_blob("HEAD", path)
        base = ctx.git.blob(head_sha) if head_sha else None
        out.append((path, summarize(base, work)))
    return out


# ─────────────────────────────────────────────────────────────────────────────
# texts (Telegram HTML)
# ─────────────────────────────────────────────────────────────────────────────


def plural(n: int, one: str, few: str, many: str) -> str:
    if n % 10 == 1 and n % 100 != 11:
        return one
    if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        return few
    return many


# What a shop owner reads. No file names, no diffs, no typed commands: the
# owner answers with buttons; power users can still type /update всё etc.

KIT_NAMES = {
    "health-check.sh": "утренняя самопроверка",
    "health-daily.sh": "ежедневная сводка о работе агента",
    "self-audit-morning.sh": "утренняя самопроверка",
    "self-audit.py": "утренняя самопроверка",
    "update-notify.sh": "сообщения об обновлениях",
    "stack-updates-check.py": "сообщения об обновлениях",
    "auth-alive-watch.sh": "сторож входа",
    "api-fail-watch.py": "сторож внешних сервисов",
    "job-fail-watch.py": "сторож фоновых задач",
    "job-watch.py": "сторож фоновых задач",
    "job-report.py": "отчёты о фоновых задачах",
    "run-and-report.sh": "отчёты о фоновых задачах",
    "bg.sh": "отчёты о фоновых задачах",
    "dead-letter-digest.py": "сводка недоставленных сообщений",
    "fallback-reply-sweeper.sh": "досылка потерянных ответов",
    "promise-sweeper.py": "напоминания об обещаниях",
    "remind-at.sh": "напоминания",
    "open-threads-digest.py": "сводка открытых дел",
    "memory-index-trim.py": "память агента",
    "memory-key-ask.py": "память агента",
    "multichat-nudge.sh": "работа в группах",
    "tg-send.py": "отправка сообщений в Телеграм",
    "claude-link-guard.sh": "сторож входа",
    "timing.py": "замер времени задач",
}
KIT_FOLDER_NAMES = {"hooks": "правила поведения агента", "agents": "помощники агента"}
FALLBACK_NAME = "служебная часть"
BRIDGE_NAME = "основная часть обновления"
MAX_RESULT_NOTES = 4
MAX_NOTIFY_NOTES = 3
MAX_PLAN_NOTES = 8
STALE_BUTTON_TEXT = "Обновление уже поменялось, нажмите /update ещё раз."
RESTART_LINE = "Перезапускаюсь — связь моргнёт секунд на 10."

BUTTON_KEEP = ("keep", "Обновить, своё не трогать")
BUTTON_ALL = ("all", "Обновить всё, даже своё (копию сохраню)")
BUTTON_NO = ("no", "Не сейчас")
BLOCKED_TEXT = ("Основную часть обновления поставить не смог: ваша доработка «{}» и обновление "
                "меняют одно и то же место. Ничего не сломал, работаю на прежней версии. "
                "Разработчику уже ушёл сигнал — он перенесёт доработку в общую версию.")


def plain_name(path: str) -> str:
    """Human name of a kit file. Never the path itself."""
    if path == CONSTITUTION:
        return "основные правила агента"
    folder, _, name = path.rpartition("/")
    if name in KIT_NAMES:
        return KIT_NAMES[name]
    return KIT_FOLDER_NAMES.get(folder.rpartition("/")[2], FALLBACK_NAME)


def item_name(item: dict[str, Any]) -> str:
    return BRIDGE_NAME if item["kind"] == "bridge" else plain_name(item["path"])


def cap(text: str) -> str:
    return text[:1].upper() + text[1:]


def lower_first(text: str) -> str:
    """«Утренняя самопроверка смотрит» -> «утренняя …» after a colon; keeps «OpenAI»."""
    return text[:1].lower() + text[1:] if text[1:2].islower() else text


def joined(names: list[str]) -> str:
    uniq = list(dict.fromkeys(names))
    return uniq[0] if len(uniq) == 1 else ", ".join(uniq[:-1]) + " и " + uniq[-1]


def plain_notes(items: list[dict[str, Any]]) -> list[str]:
    """Every note of these items, deduplicated, in order."""
    out: list[str] = []
    for item in items:
        notes = item.get("notes") or [f"Обновлено: {item_name(item)}"]
        for note in notes:
            if note not in out:
                out.append(note)
    return out


def bullet_lines(notes: list[str], limit: int) -> list[str]:
    lines = [f"• {esc(n)}" for n in notes[:limit]]
    extra = len(notes) - limit
    if extra > 0:
        lines.append(f"и ещё {extra} {plural(extra, 'мелочь', 'мелочи', 'мелочей')}")
    return lines


def changes(n: int) -> str:
    return f"{n} {plural(n, 'изменение', 'изменения', 'изменений')}"


def local_subjects(plan: Plan, n: int) -> list[str]:
    return [t["subject"] for t in plan.tweaks if t.get("kind") == "local" and t["n"] == n]


def tweak_explanation(plan: Plan, item: dict[str, Any]) -> str:
    """One owner-facing paragraph: what is his, what the update does to it."""
    notes = item.get("notes", [])
    if item["kind"] == "bridge":
        subjects = local_subjects(plan, item["n"])
        brings = f"Основная часть обновления ({changes(len(notes))})" if notes \
            else "Основная часть обновления"
        if subjects:
            what = ", ".join(f"«{esc(s)}»" for s in subjects)
            word = "своя доработка" if len(subjects) == 1 else "свои доработки"
            return (f"• У вас стоит {word} {what} — в общей версии её нет, и она меняет "
                    "то же место, что и обновление. "
                    f"{brings} ставится только вместо неё: доработка уберётся "
                    "(копию сохраню). Если своё не трогать — основную часть пока не ставлю.")
        return ("• В самом агенте у вас что-то поправлено руками (вами или самим агентом). "
                f"{brings} вернёт это к общей версии (копию сохраню). "
                "Если своё не трогать — основную часть пока не ставлю.")
    name = plain_name(item["path"])
    deleted = any(t["n"] == item["n"] and t.get("deleted") for t in plan.tweaks)
    mine = (f"• {cap(name)}: у вас она убрана." if deleted else
            f"• {cap(name)}: у вас она изменена по-своему (вами или самим агентом).")
    news = "; ".join(esc(lower_first(n.rstrip("."))) for n in notes[:2])
    gets = f" Что в новой версии: {news}." if news else " Вышла новая версия."
    return (mine + gets + " Если обновить всё — ваш вариант заменится новым (копию сохраню); "
            "если своё не трогать — останется ваш.")


def plan_buttons(plan: Plan) -> list[tuple[str, str]]:
    """Inline buttons under the plan. None when nothing of the owner's is touched:
    then /update just installs everything."""
    if not any(i.get("tweak") for i in plan.items):
        return []
    has_rest = any(keepable(i) for i in plan.items)
    return ([BUTTON_KEEP] if has_rest else []) + [BUTTON_ALL, BUTTON_NO]


def keepable(item: dict[str, Any]) -> bool:
    """Goes in on «своё не трогать». The bridge with only local commits in the
    way does too: they are carried over, or the update is blocked with a signal."""
    if not item.get("tweak"):
        return True
    return item["kind"] == "bridge" and not item.get("repo_tweak", True)


def plan_text(plan: Plan) -> str:
    tweaked = [i for i in plan.items if i.get("tweak")]
    rest = [i for i in plan.items if not i.get("tweak")]
    if not tweaked:
        lines = ["Вышло обновление. Что изменится:"]
        lines += bullet_lines(plain_notes(rest), MAX_PLAN_NOTES)
        lines += ["", "Нажмите /update — поставлю."]
        return "\n".join(lines)
    head = "Вышло обновление. Оно заденет то, что у вас настроено по-своему:"
    parts = [head, "\n\n".join(tweak_explanation(plan, i) for i in tweaked)]
    if rest:
        n = len(plain_notes(rest))
        parts.append(f"Остальное (ещё {changes(n)}) встанет при любой кнопке «Обновить».")
    parts.append("Как поступить?")
    text = "\n\n".join(parts)
    return text if len(text) <= TEXT_BUDGET else text[:TEXT_BUDGET - 1] + "…"


def left_lines(left: list[dict[str, Any]], local: list[str], blocked: str = "") -> list[str]:
    lines: list[str] = []
    for item in left:
        if item["kind"] == "bridge" and blocked:
            lines.append(BLOCKED_TEXT.format(esc(blocked)))
        elif item["kind"] == "bridge" and item.get("tweak"):
            if local:
                what = ", ".join(f"«{esc(s)}»" for s in local)
                lines.append(f"Основную часть пока не ставил: у вас стоит своя доработка {what}, "
                             "её сначала надо перенести в общую версию.")
            else:
                lines.append("Основную часть пока не ставил: в ней у вас свои правки.")
    kept = [plain_name(i["path"]) for i in left if i["kind"] == "kit" and i.get("tweak")]
    if kept:
        lines.append(f"Не тронул ваше: {joined(kept)}.")
    other = [item_name(i) for i in left if not i.get("tweak")
             and not (blocked and i["kind"] == "bridge")]
    if other:
        lines.append(f"Пока не ставил: {joined(other)}.")
    return lines


def result_text(chosen: list[dict[str, Any]], left: list[dict[str, Any]], *, restart: bool,
                local: list[str] | None = None, overwrote: bool = False,
                local_saved: bool = False, warn: str = "", blocked: str = "") -> str:
    """After an install: what came in, what was left alone, plain words only."""
    lines = ["Обновил. Что нового:"] + bullet_lines(plain_notes(chosen), MAX_RESULT_NOTES)
    tail = left_lines(left, local or [], blocked)
    if overwrote:
        tail.append("Ваш прежний вариант сохранил копией — если что, вернём.")
    if local_saved:
        tail.append("Вашу доработку сохранил копией — её можно будет вернуть.")
    if warn:
        tail.append(warn)
    tail.append(RESTART_LINE if restart else "Заработает со следующего сообщения.")
    return "\n".join(lines + [""] + tail)


# ─────────────────────────────────────────────────────────────────────────────
# subcommands
# ─────────────────────────────────────────────────────────────────────────────


def public_items(plan: Plan) -> list[dict[str, Any]]:
    keys = ("n", "kind", "title", "notes", "hidden", "tweak", "target", "path", "new_file")
    return [{k: i[k] for k in keys if k in i} for i in plan.items]


def cmd_plan(ctx: Ctx) -> dict[str, Any]:
    plan = build_plan(ctx)
    ctx.save("update-plan.json", {
        "fetch_head": plan.fetch_head, "head": plan.head, "created": int(time.time()),
        "items": {str(i["n"]): i for i in plan.items},
        "keep_always": plan.keep_always, "baselines": plan.baselines,
    })
    if not plan.items:
        return {"status": "UPTODATE", "text_html": "Уже стоит последняя версия, обновлять нечего.",
                "items": [], "tweaks": [], "buttons": [], "fetch_head": plan.fetch_head}
    return {"status": "PLAN", "text_html": plan_text(plan), "items": public_items(plan),
            "tweaks": plan.tweaks, "buttons": [list(b) for b in plan_buttons(plan)],
            "fetch_head": plan.fetch_head}


# ─────────────────────────────────────────────────────────────────────────────
# apply
# ─────────────────────────────────────────────────────────────────────────────

STALE_TEXT = STALE_BUTTON_TEXT
NOPLAN_TEXT = "Сначала нажмите /update — покажу, что вышло."


def saved_plan(ctx: Ctx) -> tuple[dict[str, Any] | None, str | None]:
    """(plan, refusal text). Refuse when the update moved since the owner saw it."""
    saved = ctx.load("update-plan.json", None)
    if not isinstance(saved, dict) or "items" not in saved:
        # A button under an old message: the plan it showed is gone.
        return None, STALE_BUTTON_TEXT if ctx.expect else NOPLAN_TEXT
    if saved.get("fetch_head") != ctx.git.rev(ctx.ref) or saved.get("head") != ctx.git.rev("HEAD"):
        return None, STALE_TEXT
    if ctx.expect and not str(saved.get("fetch_head", "")).startswith(ctx.expect):
        return None, STALE_BUTTON_TEXT
    return saved, None


def pick(items: dict[str, dict[str, Any]], rest: list[str]) -> tuple[list[int], str | None]:
    words = [w for arg in rest for w in re.split(r"[\s,;]+", arg) if w]
    if words == ["all"]:
        return sorted(int(n) for n in items), None
    if words == ["keep"]:
        return sorted(int(n) for n, i in items.items() if keepable(i)), None
    nums: list[int] = []
    for w in words:
        if not w.isdigit() or w not in items:
            have = ", ".join(sorted(items, key=int)) or "нет"
            return [], f"<b>update</b> — нет пункта «{esc(w)}». Пункты в плане: {have}."
        if int(w) not in nums:
            nums.append(int(w))
    return sorted(nums), None


def bun_path() -> str:
    return os.environ.get("DASHI_BUN") or str(Path.home() / ".bun" / "bin" / "bun")


def apply_bridge(ctx: Ctx, target: str, keep: list[str]) -> tuple[bool, str]:
    """Backup -> reset to target (the update, local commits on top if carried)
    -> bun install -> install-kit --keep. (ok, kit warning)."""
    bak = ctx.repo.with_name(ctx.repo.name + ".bak")
    try:
        if bak.exists():
            shutil.rmtree(bak)
        subprocess.run(["cp", "-a", str(ctx.repo), str(bak)], check=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError) as err:
        # No copy = no way back: refuse before touching the repo.
        log_update(ctx, f"backup copy failed: {err}")
        return False, "не смог сделать резервную копию, поэтому ничего не трогал"
    ctx.git.close()
    try:
        ctx.git.run("reset", "-q", "--hard", target)
        res = subprocess.run([bun_path(), "install", "--silent"], cwd=ctx.repo / "plugin",
                             capture_output=True, timeout=600)
        ok = res.returncode == 0
    except (GitError, OSError, subprocess.SubprocessError):
        ok = False
    if not ok:
        # The copy taken a moment ago becomes the repo again. Order matters: two
        # renames first (a kill between them leaves both copies on disk), the
        # broken tree is deleted only once the repo is back.
        aside = ctx.repo.with_name(f"{ctx.repo.name}.failed-{time.strftime('%Y%m%d-%H%M%S')}")
        os.rename(ctx.repo, aside)
        os.rename(bak, ctx.repo)
        shutil.rmtree(aside, ignore_errors=True)
        if aside.exists():
            print(f"update-plan: broken copy left at {aside}", file=sys.stderr)
        return False, "откатил всё как было"
    return True, run_install_kit(ctx, keep)


def run_install_kit(ctx: Ctx, keep: list[str]) -> str:
    kit = ctx.repo / "agent-kit" / "install-kit.sh"
    if not kit.is_file():
        return ""
    cmd = ["bash", str(kit), "--claude-dir", str(ctx.claude_dir), "--chat-id", ctx.chat_id,
           "--agent", ctx.agent, "--settings", str(ctx.settings)]
    if ctx.tz:
        cmd += ["--tz", ctx.tz]
    if keep:
        cmd += ["--keep", ",".join(keep)]
    log = ctx.workspace / "logs" / "update-kit.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("a") as fh:
        fh.write(f"--- {time.strftime('%Y-%m-%d %H:%M:%S')} {' '.join(cmd)}\n")
        fh.flush()
        res = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT)
    if res.returncode != 0:
        return ("Часть служебных файлов встала с ошибкой — перешлите это сообщение "
                "тому, кто ставил агента.")
    return ""


def cmd_apply(ctx: Ctx, rest: list[str]) -> dict[str, Any]:
    saved, refusal = saved_plan(ctx)
    if saved is None:
        return {"status": "STALE", "restart": False, "text_html": refusal}
    items: dict[str, dict[str, Any]] = saved["items"]
    nums, error = pick(items, rest)
    if error:
        return {"status": "NOTHING", "restart": False, "text_html": error}
    if not nums:
        return {"status": "NOTHING", "restart": False,
                "text_html": "Без вашего ставить нечего: всё, что вышло, задевает то, "
                             "что у вас настроено по-своему."}
    chosen = [items[str(n)] for n in nums]
    left = [i for n, i in sorted(items.items(), key=lambda kv: int(kv[0])) if int(n) not in nums]
    local = [s for i in left if i["kind"] == "bridge" for s in i.get("local_subjects", [])]
    bridge = next((i for i in chosen if i["kind"] == "bridge"), None)
    overwrote = any(i.get("tweak") for i in chosen if i["kind"] == "kit") or bool(
        bridge and bridge.get("repo_tweak", bridge.get("tweak") and not bridge.get("local_subjects")))
    if bridge is None:
        return apply_kit_items(ctx, chosen, left, local=local, overwrote=overwrote)
    # Local commits are carried over onto the update, unless the owner chose to
    # overwrite the ones that do not go on (`all` or the item number).
    keep_words = [w for arg in rest for w in re.split(r"[\s,;]+", arg) if w] == ["keep"]
    carry = keep_words or bool(bridge.get("local_clean", not bridge.get("tweak")))
    keep = list(saved.get("keep_always", [])) + [i["target"] for i in left if i["kind"] == "kit"]
    saved_ok, saved_note = save_local_commits(ctx, saved["fetch_head"])
    if not saved_ok:
        return {"status": "ROLLBACK", "restart": False,
                "text_html": "Не смог сохранить копию вашей доработки, поэтому ничего "
                             "не трогал. Перешлите это сообщение тому, кто ставил агента."}
    target = saved["fetch_head"]
    if carry:
        target, stuck = replay_local(ctx, saved["fetch_head"])
        if stuck is not None:
            # The repo was not touched. The developer gets the signal; the kit
            # files the owner chose still go in.
            write_blocked(ctx, saved["fetch_head"], stuck)
            kit = [i for i in chosen if i["kind"] == "kit"]
            if not kit:
                drop_saved_plan(ctx)
                return {"status": "BLOCKED", "restart": False,
                        "text_html": BLOCKED_TEXT.format(esc(stuck["subject"]))}
            left = sorted([bridge, *left], key=lambda i: int(i["n"]))
            return apply_kit_items(ctx, kit, left, local=[], overwrote=overwrote,
                                   blocked=stuck["subject"])
    ok, warn = apply_bridge(ctx, target, keep)
    drop_saved_plan(ctx)
    if not ok:
        return {"status": "ROLLBACK", "restart": False,
                "text_html": f"Обновление не встало: {warn}. Агент работает по-старому."}
    clear_blocked(ctx)
    # HEAD is the new baseline for everything install-kit rendered; files it
    # was told to keep stay on the blob they were on.
    baselines: dict[str, str] = saved.get("baselines", {})
    ctx.save("update-applied.json", {
        path: blob for path, blob in baselines.items()
        if str(ctx.kit_target(path)) in keep})
    return {"status": "UPDATED", "restart": True,
            "text_html": result_text(chosen, left, restart=True, local=local,
                                     overwrote=overwrote,
                                     local_saved=bool(saved_note) and not carry, warn=warn)}


def apply_kit_items(ctx: Ctx, chosen: list[dict[str, Any]], left: list[dict[str, Any]], *,
                    local: list[str], overwrote: bool, blocked: str = "") -> dict[str, Any]:
    """Kit files only: HEAD stays, each chosen file is rendered from its new blob."""
    applied: dict[str, str] = ctx.load("update-applied.json", {})
    stamp = time.strftime("%Y%m%d-%H%M")
    for item in chosen:
        render_to(ctx, Path(item["target"]), ctx.render(ctx.git.blob(item["blob"])), stamp)
        applied[item["path"]] = item["blob"]
    ctx.save("update-applied.json", applied)
    drop_saved_plan(ctx)
    if overwrote:
        log_update(ctx, f"owner files backed up to {ctx.workspace / '.kit-backup' / stamp}")
    return {"status": "UPDATED", "restart": False,
            "text_html": result_text(chosen, left, restart=False, local=local,
                                     overwrote=overwrote, blocked=blocked)}


def drop_saved_plan(ctx: Ctx) -> None:
    """A plan is installed once: the next bare /update shows a fresh one."""
    try:
        ctx.state_file("update-plan.json").unlink()
    except FileNotFoundError:
        pass


def cmd_auto(ctx: Ctx, rest: list[str]) -> dict[str, Any]:
    """Bare /update. Nothing of the owner's is touched -> install everything right
    away, no questions. Otherwise explain just that part and ask with buttons
    (the answer comes back as `--expect <fetch_head> apply keep|all`)."""
    out = cmd_plan(ctx)
    if out["status"] == "PLAN" and not out["buttons"]:
        return cmd_apply(ctx, ["all"])
    return out


def render_to(ctx: Ctx, target: Path, data: bytes, stamp: str) -> None:
    """install-kit.sh render(): back up a differing target, then overwrite it."""
    current = read_bytes(target)
    if current is not None and current != data:
        try:
            rel = target.relative_to(ctx.workspace)
        except ValueError:
            rel = Path(target.name)
        backup = ctx.workspace / ".kit-backup" / stamp / rel
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(target, backup)
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("wb") as fh:
        fh.write(data)
    if target.parent.name in ("hooks", "bin"):
        target.chmod(target.stat().st_mode | 0o111)


# ─────────────────────────────────────────────────────────────────────────────
# skip / skipped / unskip
# ─────────────────────────────────────────────────────────────────────────────


def cmd_skip(ctx: Ctx, rest: list[str]) -> dict[str, Any]:
    saved, refusal = saved_plan(ctx)
    if saved is None:
        return {"status": "STALE", "text_html": refusal}
    items: dict[str, dict[str, Any]] = saved["items"]
    nums, error = pick(items, rest)
    if error or not nums or rest in (["all"], ["keep"]):
        return {"status": "NOTHING", "text_html": error or
                "Какой пункт пропустить? Например: /update пропусти 2"}
    skipped = ctx.load("update-skipped.json", {})
    kit: dict[str, str] = skipped.setdefault("kit", {})
    bridge: list[str] = skipped.setdefault("bridge", [])
    chosen = [items.pop(str(n)) for n in nums]
    for item in chosen:
        if item["kind"] == "bridge":
            bridge.extend(c for c in item["commits"] if c not in bridge)
        else:
            kit[item["path"]] = item["blob"]
            saved.setdefault("keep_always", []).append(item["target"])
    ctx.save("update-skipped.json", skipped)
    # The owner keeps his numbering: skipped items just leave the saved plan.
    ctx.save("update-plan.json", saved)
    return {"status": "SKIPPED", "text_html":
            f"Пропустил: {joined([item_name(i) for i in chosen])}. "
            "Больше не предложу, пока там не выйдет что-то новое. Вернуть: /update верни"}


def cmd_skipped(ctx: Ctx, rest: list[str]) -> dict[str, Any]:
    skipped = ctx.load("update-skipped.json", {})
    kit: dict[str, str] = skipped.get("kit", {})
    bridge: list[str] = skipped.get("bridge", [])
    if not kit and not bridge:
        return {"status": "NONE", "text_html": "Пропущенного нет."}
    lines = ["Пропущено:"]
    if bridge:
        lines.append(f"• {BRIDGE_NAME}")
    for name in dict.fromkeys(plain_name(p) for p in sorted(kit, key=kit_sort_key)):
        lines.append(f"• {name}")
    lines.append("Вернуть: /update верни")
    return {"status": "LIST", "text_html": "\n".join(lines)}


def cmd_unskip(ctx: Ctx, rest: list[str]) -> dict[str, Any]:
    skipped = ctx.load("update-skipped.json", {})
    count = len(skipped.get("kit", {})) + (1 if skipped.get("bridge") else 0)
    for name in ("update-skipped.json", "update-plan.json"):
        try:
            ctx.state_file(name).unlink()
        except FileNotFoundError:
            pass
    return {"status": "UNSKIPPED", "text_html":
            f"Вернул пропущенное ({count}). Нажмите /update — покажу заново."}


# ─────────────────────────────────────────────────────────────────────────────
# notify (daily advisor, update-notify.sh)
# ─────────────────────────────────────────────────────────────────────────────

NOTIFY_HASH = "update-notify.hash"
def notify_text(plan: Plan) -> str:
    """Morning heads-up: short, plain, one call to action."""
    lines = ["Вышло обновление:"] + bullet_lines(plain_notes(plan.items), MAX_NOTIFY_NOTES)
    lines.append("")
    if any(i.get("tweak") for i in plan.items):
        lines.append("Есть место, где у вас своё — при /update объясню.")
    lines.append("Нажмите /update, чтобы обновить.")
    return "\n".join(lines)


def cmd_notify(ctx: Ctx, rest: list[str], sent: bool) -> str:
    """Text for the owner, only when the plan changed since the last sent one.

    `--sent` records the current plan as delivered (call it after tg-send ok).
    """
    plan = build_plan(ctx)
    key = plan.unit_key()
    if sent:
        ctx.state_dir.mkdir(parents=True, exist_ok=True)
        ctx.state_file(NOTIFY_HASH).write_text(key + "\n")
        return ""
    visible = [i for i in plan.items if i["kind"] == "kit" or i.get("notes")]
    if not visible:
        return ""
    try:
        if ctx.state_file(NOTIFY_HASH).read_text().strip() == key:
            return ""
    except OSError:
        pass
    return notify_text(plan) + "\n"


# ─────────────────────────────────────────────────────────────────────────────
# scan (central scanner, read-only)
# ─────────────────────────────────────────────────────────────────────────────

SCAN_DIFF_CHARS = 4000
PLACEHOLDERS = ("__CLAUDE_DIR__", "__WORKSPACE__", "__CHAT_ID__", "__AGENT__")
PLACEHOLDER_BYTES = tuple(k.encode() for k in PLACEHOLDERS)
SCAN_HELP = """\
scan (read-only, for a central scanner):
  ssh HOST 'python3 - --repo REPO --claude-dir CLAUDE_DIR [--workspace WS]
            [--agent NAME] [--chat-id ID] scan' < scripts/update-plan.py
  REPO        the agent's checkout (…/.claude/dashi-plugin-claude-code)
  CLAUDE_DIR  the agent's .claude folder (hooks/, agents/, core/)
  WS          the agent's workspace (bin/, state/); default: CLAUDE_DIR/..
  --agent / --chat-id are what install-kit rendered into the kit files; when
  not given they are read back from the installed files. --ref picks the base
  (default FETCH_HEAD, origin/main when there is none). Prints one JSON object;
  writes nothing, fetches nothing, so a newer copy of this script can be piped
  in over ssh stdin.
"""


def infer_placeholders(ctx: Ctx, blobs: dict[str, str]) -> None:
    """Fill in an unknown chat id / agent name from what install-kit rendered:
    a template line with the placeholder against the installed lines (line by
    line, so an owner's edit elsewhere in the file does not get in the way)."""
    names = {"__CHAT_ID__": "chat_id", "__AGENT__": "agent"}
    unknown = [k for k, attr in names.items() if not getattr(ctx, attr)]
    split = re.compile(b"(" + b"|".join(PLACEHOLDER_BYTES) + b")")
    for path, sha in sorted(blobs.items()):
        if not unknown:
            return
        target = ctx.kit_target(path)
        installed = read_bytes(target) if target else None
        tpl = safe_blob(ctx, sha)
        if installed is None or not any(k.encode() in tpl for k in unknown):
            continue
        lines = installed.splitlines()
        for line in tpl.splitlines():
            if not any(k.encode() in line for k in unknown):
                continue
            known = {"__CLAUDE_DIR__": str(ctx.claude_dir), "__WORKSPACE__": str(ctx.workspace),
                     "__CHAT_ID__": ctx.chat_id, "__AGENT__": ctx.agent}
            pattern, order = b"", []
            for piece in split.split(line):
                key = piece.decode() if piece in PLACEHOLDER_BYTES else ""
                if key in unknown:
                    pattern += rb"(.*?)"
                    order.append(key)
                else:
                    pattern += re.escape(known[key].encode() if key else piece)
            m = next((m for m in map(re.compile(pattern).fullmatch, lines) if m), None)
            if m is None:
                continue
            for key, val in zip(order, m.groups()):
                if key in unknown:
                    setattr(ctx, names[key], val.decode("utf-8", "replace"))
                    unknown.remove(key)


def scan_kit_tweaks(ctx: Ctx, base: str | None) -> list[dict[str, Any]]:
    """Kit files whose installed copy is neither what was installed nor any other
    known version of that file: the owner's (or the agent's) own edits."""
    head_blobs = ctx.git.tree_blobs("HEAD", *KIT_TREE_ARGS)
    base_blobs = ctx.git.tree_blobs(base, *KIT_TREE_ARGS) if base else {}
    applied: dict[str, str] = ctx.load("update-applied.json", {})
    history = kit_history(ctx, base) if base else {}
    infer_placeholders(ctx, {**base_blobs, **head_blobs})
    out: list[dict[str, Any]] = []
    for path in sorted(set(head_blobs) | set(base_blobs), key=kit_sort_key):
        target = ctx.kit_target(path)
        if target is None:
            continue
        baseline = applied.get(path) or head_blobs.get(path)
        installed = read_bytes(target)
        old = ctx.render(safe_blob(ctx, baseline)) if baseline else None
        if installed == old:
            continue
        known = {baseline, head_blobs.get(path), base_blobs.get(path)}
        known.update(b for _, ob, nb in history.get(path, []) for b in (ob, nb))
        known = {b for b in known if b and not NULL_SHA.fullmatch(b)}
        if installed is not None and any(ctx.render(safe_blob(ctx, b)) == installed for b in known):
            continue                       # an older or newer kit version, not an edit
        if installed is None and old is None:
            continue
        shown = ctx.shown(target)
        a = old.decode("utf-8", "replace").splitlines(keepends=True) if old else []
        b = installed.decode("utf-8", "replace").splitlines(keepends=True) if installed else []
        diff = "".join(difflib.unified_diff(a, b, f"a/{shown}", f"b/{shown}"))
        if len(diff) > SCAN_DIFF_CHARS:
            diff = diff[:SCAN_DIFF_CHARS - 1] + "…"
        summary = summarize(old, installed)
        out.append({"path": path, "target": shown, "added": summary["added"],
                    "removed": summary["removed"], "new_file": old is None,
                    "deleted": installed is None, "diff": diff})
    return out


def scan_extra_files(ctx: Ctx, base: str | None) -> list[str]:
    """Files in the agent's bin/ and hooks/ that no kit version ships."""
    kit: set[str] = set()
    for ref in ("HEAD", base):
        if ref:
            kit.update(ctx.git.tree_blobs(ref, "agent-kit/hooks/", "agent-kit/bin/"))
    out: list[str] = []
    for folder, root in (("hooks", ctx.claude_dir / "hooks"), ("bin", ctx.workspace / "bin")):
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*")):
            rel = path.relative_to(root)
            if path.is_dir() or "__pycache__" in rel.parts or path.suffix == ".pyc":
                continue
            if len(rel.parts) == 1 and f"agent-kit/{folder}/{rel}" in kit:
                continue
            out.append(ctx.shown(path))
    return out


def scan_uncommitted(ctx: Ctx) -> list[str]:
    raw = ctx.git.run("status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames")
    return [entry[3:] for entry in raw.split("\0") if len(entry) > 3]


def cmd_scan(ctx: Ctx, agent: str | None) -> dict[str, Any]:
    """One JSON object; nothing on disk changes (no state, no fetch, no index refresh)."""
    os.environ["GIT_OPTIONAL_LOCKS"] = "0"
    head = ctx.git.rev("HEAD")
    if head is None:
        raise GitError("нет HEAD")
    base = ctx.git.rev(ctx.ref) or ctx.git.rev("origin/main")
    local = list(reversed(local_commits(ctx, base))) if base else []
    replays = replay_check(ctx, base, [sha for sha, _ in local]) if base else []
    commits = []
    for (sha, subject), ok in zip(local, replays):
        try:
            stat = ctx.git.run("show", "--stat", "--format=", "--no-renames", sha).strip()
        except GitError:
            stat = ""
        commits.append({"sha": sha, "subject": subject, "files": commit_files(ctx, sha),
                        "diffstat": stat, "replays_clean": ok})
    return {"agent": agent, "head": head, "base": base, "local_commits": commits,
            "uncommitted": scan_uncommitted(ctx), "kit_tweaks": scan_kit_tweaks(ctx, base),
            "extra_files": scan_extra_files(ctx, base),
            "blocked": ctx.load(BLOCKED_FILE, None)}


# ─────────────────────────────────────────────────────────────────────────────
# main
# ─────────────────────────────────────────────────────────────────────────────


def parse_args(argv: list[str]) -> tuple[argparse.Namespace, list[str]]:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0], epilog=SCAN_HELP,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", required=True, type=Path)
    ap.add_argument("--claude-dir", required=True, type=Path)
    ap.add_argument("--workspace", type=Path)
    ap.add_argument("--agent", default=None)
    ap.add_argument("--chat-id", default="")
    ap.add_argument("--tz", default="")
    ap.add_argument("--settings", type=Path)
    ap.add_argument("--ref", default=DEFAULT_REF)
    ap.add_argument("--branch", default="", help="branch to deepen (default: from FETCH_HEAD)")
    ap.add_argument("--expect", default="",
                    help="apply/skip from a button: refuse unless the saved plan has this fetch_head")
    ap.add_argument("--sent", action="store_true", help="notify: mark the current plan as sent")
    ap.add_argument("command")
    ap.add_argument("rest", nargs="*")
    ns = ap.parse_args(argv)
    return ns, ns.rest


def make_ctx(ns: argparse.Namespace) -> Ctx:
    claude_dir = ns.claude_dir.resolve()
    workspace = (ns.workspace or claude_dir.parent).resolve()
    tz = ns.tz
    if not tz:
        try:
            tz = (claude_dir / "core" / "owner-tz").read_text().strip()
        except OSError:
            tz = ""
    settings = ns.settings or Path.home() / ".claude" / "settings.json"
    repo = ns.repo.resolve()
    # scan reads an unknown agent name back from the installed files instead
    agent = ns.agent if ns.agent is not None else ("" if ns.command == "scan" else "agent")
    return Ctx(repo, claude_dir, workspace, agent, ns.chat_id, tz, settings, ns.ref, Git(repo),
               ns.branch, ns.expect.lower())


COMMANDS = {
    "plan": lambda ctx, rest: cmd_plan(ctx),
    "auto": cmd_auto,
    "apply": cmd_apply,
    "skip": cmd_skip,
    "skipped": cmd_skipped,
    "unskip": cmd_unskip,
}


def main(argv: list[str]) -> int:
    ns, rest = parse_args(argv)
    ctx = make_ctx(ns)
    handler = COMMANDS.get(ns.command)
    if ns.command == "notify":
        def handler(c: Ctx, r: list[str]) -> str:
            return cmd_notify(c, r, ns.sent)
    elif ns.command == "scan":
        def handler(c: Ctx, r: list[str]) -> dict[str, Any]:
            return cmd_scan(c, ns.agent)
    if handler is None:
        print(f"unknown command: {ns.command}", file=sys.stderr)
        return 2
    try:
        out = handler(ctx, rest)
    except GitError as err:
        if ns.command == "notify":
            print(f"update-plan notify: {err}", file=sys.stderr)
            return 1
        out = {"status": "ERROR",
               "text_html": f"<b>update</b> — не смог разобрать обновление: <code>{esc(str(err))[:300]}</code>"}
    finally:
        ctx.git.close()
    if isinstance(out, str):
        sys.stdout.write(out)
    else:
        print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
