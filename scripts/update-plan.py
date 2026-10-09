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
  apply all|keep|N [M ...]  install (keep = all except items with the owner's tweaks)
  skip N [M ...]            do not install and never offer again (until it changes)
  skipped                   what was skipped
  unskip all                forget every skip
  notify [--sent]           plain text for the daily advisor, only when changed

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
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

DEFAULT_REF = "FETCH_HEAD"
CONSTITUTION = "agent-kit/core/constitution.md"
KIT_TREE_ARGS = ("agent-kit/hooks/", "agent-kit/bin/", "agent-kit/agents/", CONSTITUTION)
KIT_LOG_PATHS = ("agent-kit/hooks", "agent-kit/bin", "agent-kit/agents", CONSTITUTION)
IGNORED_REPO_PATHS = frozenset({"plugin/bun.lock"})
NOTES_FILE = "update-notes.json"
TRAILER = "Хозяину:"
HIDE = "-"
HISTORY_DEPTH = 300
MAX_NOTES_PER_ITEM = 4
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

    def run(self, *args: str) -> str:
        res = subprocess.run(["git", "-C", str(self.repo), *args],
                             capture_output=True, text=True)
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
    subject = commit.body.splitlines()[0].strip() if commit.body else commit.sha[:7]
    return subject or commit.sha[:7]


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


def kit_history(ctx: Ctx) -> dict[str, list[tuple[str, str, str]]]:
    """path -> [(commit, old blob, new blob)], newest first, along ref's history."""
    hist: dict[str, list[tuple[str, str, str]]] = {}
    try:
        raw = ctx.git.run("log", "--format=%x01%H", "--raw", "--no-abbrev", "--no-renames",
                          "-n", str(HISTORY_DEPTH), ctx.ref, "--", *KIT_LOG_PATHS)
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


def build_plan(ctx: Ctx) -> Plan:
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
        item = {"n": 1, "kind": "bridge", "title": "Основное обновление агента",
                "notes": shown, "hidden": hidden,
                "earlier_skipped": len(bridge_all) - len(bridge_new),
                "commits": [c.sha for c in bridge_all], "tweak": bool(repo_tweaks)}
        items.append(item)
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


def item_block(item: dict[str, Any], max_notes: int) -> str:
    n = item["n"]
    if item["kind"] == "bridge":
        head = (f"<b>{n}. {esc(item['title'])}</b> — ставится целиком, "
                "после него перезапуск (связь моргнёт на ~10 сек)")
    else:
        folder, _, name = item["path"].rpartition("/")
        label = esc(item["title"].rsplit(" ", 1)[0]) if item["path"] != CONSTITUTION \
            else esc(item["title"])
        head = f"<b>{n}. {label}</b>" + ("" if item["path"] == CONSTITUTION
                                         else f" <code>{esc(name)}</code>")
        if item.get("new_file"):
            head += " — новый"
    if item.get("tweak"):
        head += " — <i>у вас тут своя правка</i>"
    lines = [head]
    notes: list[str] = item.get("notes", [])
    for note in notes[:max_notes]:
        lines.append(f"• {esc(note)}")
    extra = len(notes) - max_notes if len(notes) > max_notes else 0
    hidden = item.get("hidden", 0) + extra
    if hidden:
        lines.append(f"• и ещё {hidden} {plural(hidden, 'мелкая правка', 'мелкие правки', 'мелких правок')}")
    if not notes and not hidden:
        lines.append("• обновлённая версия" if not item.get("new_file") else "• новый файл")
    if item.get("earlier_skipped"):
        k = item["earlier_skipped"]
        lines.append(f"• плюс {k} {plural(k, 'правка', 'правки', 'правок')}, "
                     "которые вы раньше пропускали — они встанут вместе с этим пунктом")
    return "\n".join(lines)


def tweak_block(plan: Plan) -> str:
    if not plan.tweaks:
        return ""
    lines = ["<b>У вас своё</b> — эти пункты перезапишут ваши правки:"]
    for tw in plan.tweaks:
        if tw.get("deleted"):
            what = "у вас файл удалён"
        else:
            what = f"у вас +{tw['added']} / −{tw['removed']} строк"
        lines.append(f"• п.{tw['n']}, <code>{esc(tw['target'])}</code>: {what}")
        for line in tw.get("lines", []):
            lines.append(f"   <code>{esc(line)}</code>")
    lines.append("Если перезапишу — копия вашего файла останется рядом, ничего не пропадёт.")
    return "\n".join(lines)


def commands_block(plan: Plan) -> str:
    nums = [i["n"] for i in plan.items]
    example = f"{nums[0]} {nums[-1]}" if len(nums) > 1 else str(nums[0])
    lines = ["<b>Как ответить</b>",
             "<code>/update всё</code> — поставить всё"
             + (" (ваши правки перезапишу, копию сохраню)" if plan.tweaks else "")]
    if plan.tweaks:
        lines.append("<code>/update своё</code> — всё, кроме пунктов с вашими правками")
    lines.append(f"<code>/update {example}</code> — только выбранные пункты")
    lines.append(f"<code>/update пропусти {nums[-1]}</code> — не ставить и больше не предлагать")
    return "\n".join(lines)


def plan_text(plan: Plan) -> str:
    for max_notes in (MAX_NOTES_PER_ITEM, 1, 0):
        parts = [f"<b>Вышло обновление</b> — {len(plan.items)} "
                 f"{plural(len(plan.items), 'пункт', 'пункта', 'пунктов')}"]
        parts += [item_block(i, max_notes) for i in plan.items]
        tb = tweak_block(plan)
        if tb:
            parts.append(tb)
        footer: list[str] = []
        if plan.own_only:
            footer.append(f"Ваши правки ещё в {plan.own_only} "
                          f"{plural(plan.own_only, 'файле', 'файлах', 'файлах')} "
                          "обновление не трогает — они останутся как есть.")
        if plan.skipped_count:
            footer.append(f"Пропущено раньше: {plan.skipped_count} — "
                          "<code>/update пропущенные</code>")
        if footer:
            parts.append("\n".join(footer))
        parts.append(commands_block(plan))
        text = "\n\n".join(parts)
        if len(text) <= TEXT_BUDGET:
            return text
    return text[:TEXT_BUDGET - 1] + "…"


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
        text = "<b>update</b> — уже стоит последняя версия, ставить нечего."
        if plan.skipped_count:
            text += (f"\nПропущено раньше: {plan.skipped_count} — "
                     "<code>/update пропущенные</code>")
        return {"status": "UPTODATE", "text_html": text, "items": [], "tweaks": [],
                "fetch_head": plan.fetch_head}
    return {"status": "PLAN", "text_html": plan_text(plan), "items": public_items(plan),
            "tweaks": plan.tweaks, "fetch_head": plan.fetch_head}


# ─────────────────────────────────────────────────────────────────────────────
# apply
# ─────────────────────────────────────────────────────────────────────────────

STALE_TEXT = "<b>update</b> — вышло ещё обновление, набери <code>/update</code> заново."
NOPLAN_TEXT = ("<b>update</b> — сначала набери <code>/update</code>: покажу, что вышло, "
               "потом выбирай.")


def saved_plan(ctx: Ctx) -> tuple[dict[str, Any] | None, str | None]:
    """(plan, refusal text). Refuse when the update moved since the owner saw it."""
    saved = ctx.load("update-plan.json", None)
    if not isinstance(saved, dict) or "items" not in saved:
        return None, NOPLAN_TEXT
    if saved.get("fetch_head") != ctx.git.rev(ctx.ref) or saved.get("head") != ctx.git.rev("HEAD"):
        return None, STALE_TEXT
    return saved, None


def pick(items: dict[str, dict[str, Any]], rest: list[str]) -> tuple[list[int], str | None]:
    words = [w for arg in rest for w in re.split(r"[\s,;]+", arg) if w]
    if words == ["all"]:
        return sorted(int(n) for n in items), None
    if words == ["keep"]:
        return sorted(int(n) for n, i in items.items() if not i.get("tweak")), None
    nums: list[int] = []
    for w in words:
        if not w.isdigit() or w not in items:
            have = ", ".join(sorted(items, key=int)) or "нет"
            return [], f"<b>update</b> — нет пункта «{esc(w)}». Пункты в плане: {have}."
        if int(w) not in nums:
            nums.append(int(w))
    return sorted(nums), None


def label(item: dict[str, Any]) -> str:
    if item["kind"] == "bridge":
        return f"п.{item['n']} (основное)"
    return f"п.{item['n']} ({esc(item['path'].rpartition('/')[2])})"


def bun_path() -> str:
    return os.environ.get("DASHI_BUN") or str(Path.home() / ".bun" / "bin" / "bun")


def apply_bridge(ctx: Ctx, fetch_head: str, keep: list[str]) -> tuple[bool, str]:
    """Backup -> reset -> bun install -> install-kit --keep. (ok, kit warning)."""
    bak = ctx.repo.with_name(ctx.repo.name + ".bak")
    if bak.exists():
        shutil.rmtree(bak)
    subprocess.run(["cp", "-a", str(ctx.repo), str(bak)], check=True)
    ctx.git.close()
    try:
        ctx.git.run("reset", "-q", "--hard", fetch_head)
        res = subprocess.run([bun_path(), "install", "--silent"], cwd=ctx.repo / "plugin",
                             capture_output=True, timeout=600)
        ok = res.returncode == 0
    except (GitError, OSError, subprocess.SubprocessError):
        ok = False
    if not ok:
        # Same as dashi-ctl: the copy taken a moment ago becomes the repo again.
        shutil.rmtree(ctx.repo)
        os.rename(bak, ctx.repo)
        return False, ""
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
        return ("Файлы комплекта разложились с ошибкой — подробности в "
                "<code>logs/update-kit.log</code>.")
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
                "text_html": "<b>update</b> — ставить нечего: все пункты с вашими правками."}
    chosen = [items[str(n)] for n in nums]
    left = [i for n, i in sorted(items.items(), key=lambda kv: int(kv[0])) if int(n) not in nums]
    lines: list[str] = []
    if any(i["kind"] == "bridge" for i in chosen):
        keep = list(saved.get("keep_always", [])) + [i["target"] for i in left if i["kind"] == "kit"]
        ok, warn = apply_bridge(ctx, saved["fetch_head"], keep)
        if not ok:
            return {"status": "ROLLBACK", "restart": False,
                    "text_html": "<b>update</b> — обновление упало, откатил на прежнюю версию. "
                                 "Сервис не трогал, всё работает как раньше."}
        # HEAD is the new baseline for everything install-kit rendered; files it
        # was told to keep stay on the blob they were on.
        baselines: dict[str, str] = saved.get("baselines", {})
        ctx.save("update-applied.json", {
            path: blob for path, blob in baselines.items()
            if str(ctx.kit_target(path)) in keep})
        lines.append("<b>update</b> — поставил: " + ", ".join(label(i) for i in chosen) + ".")
        if left:
            lines.append("Оставил как было: " + ", ".join(label(i) for i in left) + ".")
        if warn:
            lines.append(warn)
        lines.append("Перезапускаю — связь моргнёт на ~10 сек.")
        return {"status": "UPDATED", "restart": True, "text_html": "\n".join(lines)}
    # Kit files only: HEAD stays, each chosen file is rendered from its new blob.
    applied: dict[str, str] = ctx.load("update-applied.json", {})
    stamp = time.strftime("%Y%m%d-%H%M")
    for item in chosen:
        render_to(ctx, Path(item["target"]), ctx.render(ctx.git.blob(item["blob"])), stamp)
        applied[item["path"]] = item["blob"]
    ctx.save("update-applied.json", applied)
    lines.append("<b>update</b> — поставил: " + ", ".join(label(i) for i in chosen) + ".")
    if any(i.get("tweak") for i in chosen):
        lines.append(f"Ваши прежние файлы сохранил в <code>.kit-backup/{stamp}</code>.")
    lines.append("Перезапуск не нужен — работает со следующего хода.")
    return {"status": "UPDATED", "restart": False, "text_html": "\n".join(lines)}


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
# main
# ─────────────────────────────────────────────────────────────────────────────


def parse_args(argv: list[str]) -> tuple[argparse.Namespace, list[str]]:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", required=True, type=Path)
    ap.add_argument("--claude-dir", required=True, type=Path)
    ap.add_argument("--workspace", type=Path)
    ap.add_argument("--agent", default="agent")
    ap.add_argument("--chat-id", default="")
    ap.add_argument("--tz", default="")
    ap.add_argument("--settings", type=Path)
    ap.add_argument("--ref", default=DEFAULT_REF)
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
    return Ctx(repo, claude_dir, workspace, ns.agent, ns.chat_id, tz, settings, ns.ref, Git(repo))


COMMANDS = {
    "plan": lambda ctx, rest: cmd_plan(ctx),
    "apply": cmd_apply,
}


def main(argv: list[str]) -> int:
    ns, rest = parse_args(argv)
    ctx = make_ctx(ns)
    handler = COMMANDS.get(ns.command)
    if handler is None:
        print(f"unknown command: {ns.command}", file=sys.stderr)
        return 2
    try:
        out = handler(ctx, rest)
    except GitError as err:
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
