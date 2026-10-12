#!/usr/bin/env python3
"""Shared helpers for the dashi OpenViking memory hooks (recall + digest capture).
Shipped with the dashi plugin; wired by install-agent.sh into the agent's settings.json.

Why this exists: the stock openviking plugin stored every raw Telegram turn
(including the `<channel ...>` wrapper with chat_id/message_id) and searched
with the raw prompt. Every memory looked like every other memory, so recall
was ~1 hit in 3. This module cleans text on both sides and turns a finished
turn into a short digest (ask + answer) before it is stored.
"""
from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

def _agent_id() -> str:
    """agentId of this install: the OpenViking plugin config (same file the installer
    writes), so several agents on one host keep separate memories. Env wins."""
    if os.environ.get("OV_AGENT"):
        return os.environ["OV_AGENT"]
    cfg = os.environ.get("OPENVIKING_CC_CONFIG_FILE") or str(
        Path.home() / ".openviking/claude-code-memory-plugin/config.json")
    try:
        return json.loads(Path(cfg).read_text()).get("agentId") or "agent"
    except (OSError, json.JSONDecodeError):
        return "agent"


OV_BASE = "http://127.0.0.1:1933"
OV_AGENT = _agent_id()
OV_TIMEOUT_S = 6
STATE_FILE = Path.home() / ".openviking/hooks/capture-state.json"
LOG_FILE = Path.home() / ".openviking/logs/memory-hooks.log"

RECALL_LIMIT = int(os.environ.get("OV_RECALL_LIMIT", "3"))
# OpenViking >= 0.4.22 reports similarity as (cos + 1) / 2. Measured 2026-08-21 on raw
# cosine: relevant 0.39-0.51, noise mostly <0.40 -> 0.40 raw == 0.70 now (v0.5.0 on
# Jarvis since 12.10.2026, 14-query check: new == (1 + old) / 2 within 0.0005).
# An older server still answers in raw cosine -- threshold_for() maps back for it.
RECALL_THRESHOLD = float(os.environ.get("OV_RECALL_THRESHOLD", "0.70"))
MIN_QUERY_WORDS = 3
MAX_ASK_CHARS = 500
MAX_ANSWER_CHARS = 900
MAX_MEMORY_CHARS = 320

_WRAPPER_RE = re.compile(
    r"<channel\b[^>]*>|</channel>"
    r"|<untrusted_metadata\b.*?</untrusted_metadata>"
    r"|<system-reminder>.*?</system-reminder>"
    r"|<relevant-memories>.*?</relevant-memories>",
    re.S,
)
_MEDIA_RE = re.compile(r"<media\b([^>]*?)/>", re.S)
_TRANSCRIPT_RE = re.compile(r'transcript="([^"]*)"')
_TAG_RE = re.compile(r"<[^>\n]{1,80}>")
_WS_RE = re.compile(r"[ \t]+")
_NL_RE = re.compile(r"\n{3,}")
# Acks / chit-chat that carry no fact worth remembering.
_NOISE_RE = re.compile(
    r"^(ок(ей)?|ok|да|нет|ага|угу|понял|понятно|принято|спасибо|спс|хорошо|ладно|давай|го|погнали|"
    r"делай|жду|норм|отлично|супер|всё понял|все понял|вопросов нет|все понял вопросов нет|"
    r"привет|здарова|пока|\+|👍|🙏|❤️)[\s.!)]*$",
    re.I,
)
_LESSON_RE = re.compile(
    r"запомни|правило|всегда|никогда|больше не|не так|неправильно|ошиб|блять|нахуя|какого хуя|"
    r"договорились|решили|с сегодняшнего|отныне",
    re.I,
)


# --- score scale ------------------------------------------------------------

NEW_SCALE_SINCE = (0, 4, 22)


def uses_new_scale(version: str) -> bool:
    """True for OpenViking >= 0.4.22 and for an unknown version (installer pins v0.5.0)."""
    nums = tuple(int(x) for x in re.findall(r"\d+", version or "")[:3])
    return not nums or nums >= NEW_SCALE_SINCE


def threshold_for(version: str, threshold: float = RECALL_THRESHOLD) -> float:
    """Thresholds here are on the >= 0.4.22 scale; a raw-cosine server gets 2t - 1."""
    return threshold if uses_new_scale(version) else round(2 * threshold - 1, 4)


def clean_text(text: str) -> str:
    """Strip channel wrappers, metadata, reminders; keep voice transcripts as text."""
    if not text:
        return ""

    def media(m: re.Match) -> str:
        t = _TRANSCRIPT_RE.search(m.group(1))
        return t.group(1) if t else ""

    text = _MEDIA_RE.sub(media, text)
    text = _WRAPPER_RE.sub("", text)
    text = _TAG_RE.sub("", text)
    text = text.replace("&quot;", '"').replace("&amp;", "&")
    text = _WS_RE.sub(" ", text)
    text = "\n".join(line.strip() for line in text.splitlines())
    return _NL_RE.sub("\n\n", text).strip()


def is_noise(text: str, min_words: int = MIN_QUERY_WORDS) -> bool:
    """True for acks, empty text and anything too short to carry a fact."""
    t = text.strip()
    if not t or _NOISE_RE.match(t):
        return True
    return len(re.findall(r"\w+", t)) < min_words


def looks_like_lesson(text: str) -> bool:
    return bool(_LESSON_RE.search(text))


def _trim(text: str, limit: int) -> str:
    text = text.strip()
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


@dataclass
class Digest:
    ask: str
    answer: str
    lesson: bool

    def user_text(self) -> str:
        """One user-role, declarative, dated record. Measured 2026-08-21 against the
        OpenViking extractor: assistant-role messages become agent identity/soul
        (never a searchable user memory); question-shaped text («Задача: почему…?
        Итог: …») is swallowed into profile.md; a statement «Запись от <дата>: <факты>.
        Повод: …» becomes an events/ memory and is found by paraphrase."""
        # Time + «новый эпизод»: without them OpenViking's LLM dedup judged a same-topic
        # follow-up (new facts, same day) a duplicate and dropped it; with them it merges.
        tag = "[урок/правило] " if self.lesson else ""
        now = datetime.now(ZoneInfo("Asia/Yekaterinburg")).strftime("%d.%m.%Y %H:%M")
        ask = _trim(self.ask, MAX_ASK_CHARS)
        if not self.answer:
            return f"{tag}Запись от {now} (новый эпизод): {ask}"
        return (f"{tag}Запись от {now} (новый эпизод): {_trim(self.answer, MAX_ANSWER_CHARS)} "
                f"Повод: оператор спросил/поручил «{ask}»")


def make_digest(ask_raw: str, answer_raw: str) -> Digest | None:
    """Turn one finished turn into a digest; None when there is nothing worth storing."""
    ask = clean_text(ask_raw)
    answer = clean_text(answer_raw)
    if is_noise(ask) or not answer:
        return None
    return Digest(ask=ask, answer=answer, lesson=looks_like_lesson(ask))


# --- transcript -------------------------------------------------------------

def _text_of(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content
                         if isinstance(b, dict) and b.get("type") == "text")
    return ""


def last_turn(transcript_path: str) -> tuple[str, str, str] | None:
    """Return (user_uuid, ask_raw, answer_raw) for the last user->assistant exchange.

    answer = text the user actually saw: the text of the last channel `reply`
    tool call in that turn, else the assistant's final text blocks.
    """
    rows = []
    with open(transcript_path, encoding="utf-8") as fh:
        for line in fh:
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    start = None
    for i in range(len(rows) - 1, -1, -1):
        r = rows[i]
        if r.get("type") != "user" or r.get("isSidechain"):
            continue
        c = r.get("message", {}).get("content")
        if isinstance(c, list) and all(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
            continue
        start = i
        break
    if start is None:
        return None
    ask_raw = _text_of(rows[start]["message"].get("content"))
    reply_text, final_text = "", ""
    for r in rows[start + 1:]:
        if r.get("type") != "assistant" or r.get("isSidechain"):
            continue
        for b in r.get("message", {}).get("content", []) or []:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "tool_use" and str(b.get("name", "")).endswith("__reply"):
                t = (b.get("input") or {}).get("text")
                if t:
                    reply_text = t
            elif b.get("type") == "text" and b.get("text", "").strip():
                final_text = b["text"]
    return rows[start].get("uuid", ""), ask_raw, reply_text or final_text


# --- OpenViking client ------------------------------------------------------

class OVClient:
    def __init__(self, base: str = OV_BASE, agent: str = OV_AGENT, timeout: float = OV_TIMEOUT_S):
        self.base, self.timeout = base, timeout
        self.headers = {"Content-Type": "application/json", "X-OpenViking-Agent": agent}

    def call(self, path: str, body=None, method: str | None = None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, headers=self.headers,
                                     method=method or ("POST" if body is not None else "GET"))
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return json.load(resp).get("result")

    def server_version(self) -> str:
        """Version from /health ("v0.5.0"); "" when the server does not say."""
        try:
            req = urllib.request.Request(self.base + "/health", headers=self.headers)
            with urllib.request.urlopen(req, timeout=min(self.timeout, 2)) as resp:
                return str(json.load(resp).get("version") or "")
        except (urllib.error.URLError, OSError, ValueError):
            return ""

    def find(self, query: str, scope: str, limit: int = 8) -> list[dict]:
        r = self.call("/api/v1/search/find",
                      {"query": query, "target_uri": scope, "limit": limit, "score_threshold": 0})
        if isinstance(r, dict):
            r = r.get("memories") or r.get("items") or r.get("results") or []
        return r or []

    def store_digest(self, digest: Digest) -> list[str]:
        """session -> 2 clean messages -> extract -> drop session. Returns created URIs."""
        sid = self.call("/api/v1/sessions", {})["session_id"]
        try:
            self.call(f"/api/v1/sessions/{sid}/messages", {"role": "user", "content": digest.user_text()})
            out = self.call(f"/api/v1/sessions/{sid}/extract", {}) or []
            return [e.get("uri", "") for e in out if isinstance(e, dict)]
        finally:
            try:
                self.call(f"/api/v1/sessions/{sid}", method="DELETE")
            except (urllib.error.URLError, OSError):
                pass


# --- recall formatting ------------------------------------------------------

_NEVER_RECALL = ("profile.md", "identity.md", "soul.md")  # self-model docs, never task-relevant


def rank(cands: list[dict], threshold: float = RECALL_THRESHOLD, limit: int = RECALL_LIMIT,
         query: str = "") -> list[dict]:
    """Threshold, dedupe by uri, best first. Legacy events still carry the Telegram
    wrapper in their body — they stay (they are real memories and rank fine against
    a clean query); only the display text is cleaned. Drops self-model docs and
    «echoes» — a stored copy of the very prompt being asked (blind judge 2026-08-21:
    both were the bulk of the noise)."""
    seen, out = set(), []
    q = clean_text(query)[:120].lower()
    for c in sorted(cands, key=lambda c: float(c.get("score") or 0), reverse=True):
        score = float(c.get("score") or 0)
        if score < threshold:
            break
        uri = c.get("uri", "")
        body = c.get("abstract") or c.get("content") or c.get("text") or ""
        if uri in seen or uri.endswith(_NEVER_RECALL):
            continue
        seen.add(uri)
        text = re.sub(r"(\[user\]:\s*)+", "", clean_text(body))
        if q and len(q) > 20 and (q in text.lower() or text.lower()[:120] in q):
            continue
        out.append({"uri": uri, "score": score, "text": text})
        if len(out) >= limit:
            break
    return out


def render(memories: list[dict]) -> str:
    if not memories:
        return ""
    lines = ["<relevant-memories>",
             "Память OpenViking (выжимки прошлых ходов; навигация, не источник истины):"]
    for m in memories:
        short = m["uri"].split("/memories/", 1)[-1]
        lines.append(f"- [{m['score']:.2f}] {short}: {_trim(m['text'], MAX_MEMORY_CHARS)}")
    lines.append("</relevant-memories>")
    return "\n".join(lines)


def log(event: str, **kw) -> None:
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"event": event, **kw}, ensure_ascii=False) + "\n")
    except OSError:
        pass
