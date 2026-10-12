#!/usr/bin/env python3
"""T1 — unit tests for the OpenViking memory hooks (no network)."""
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ov_memory import (  # noqa: E402
    RECALL_THRESHOLD, clean_text, is_noise, last_turn, make_digest, rank, render, threshold_for,
    uses_new_scale,
)

WRAPPED = ('<channel source="dashi-channel" source="telegram" chat_id="140141496" user_id="140141496" '
           'ts="2026-08-21T13:15:04.306Z" message_id="32583">\nА почему написано на куче трубок '
           'нет в прайсе?\n<untrusted_metadata type="telegram_reply">\n{"sender":"agent","body":"x"}\n'
           '</untrusted_metadata>\n</channel>')
VOICE = ('<channel source="dashi-channel" chat_id="1" message_id="2">\n<media kind="voice" file_id="A" '
         'mime="audio/ogg" transcript="Еще смотри какой вопрос про агента." transcription_status="ok" />\n'
         '</channel>')


def test_clean_text():
    assert clean_text(WRAPPED) == "А почему написано на куче трубок нет в прайсе?"
    assert clean_text(VOICE) == "Еще смотри какой вопрос про агента."
    assert "chat_id" not in clean_text(WRAPPED)
    assert clean_text("<system-reminder>junk</system-reminder> привет мир, как дела") == "привет мир, как дела"
    assert clean_text("") == ""


def test_is_noise():
    for ack in ("ок", "Все понял вопросов нет", "Делай", "👍", "да.", "", "спасибо!"):
        assert is_noise(ack), ack
    assert not is_noise("заморозь цены на iPhone 16 256")
    assert not is_noise(clean_text(WRAPPED))


def test_make_digest():
    assert make_digest("ок", "ответ") is None
    assert make_digest(WRAPPED, "") is None
    d = make_digest(WRAPPED, "17-я серия сматчилась, 26 без закупа")
    assert d and not d.lesson and d.ask.startswith("А почему")
    assert "chat_id" not in d.user_text()
    d2 = make_digest("Запомни: продано значит выдано клиенту", "Принято, записал")
    assert d2 and d2.lesson and d2.user_text().startswith("[урок/правило]")


def test_rank_and_render():
    cands = [
        {"uri": "viking://user/default/memories/events/a.md", "score": 0.61, "abstract": "чистая запись A"},
        {"uri": "viking://user/default/memories/events/b.md", "score": 0.55,
         "abstract": '[user]: <channel source="x" chat_id="1"> старый мусор'},
        {"uri": "viking://user/default/memories/events/a.md", "score": 0.50, "abstract": "дубль A"},
        {"uri": "viking://user/default/memories/events/c.md", "score": 0.30, "abstract": "ниже порога"},
        {"uri": "viking://user/default/memories/profile.md", "score": 0.90, "abstract": "Саня — директор"},
        {"uri": "viking://agent/jarvis/memories/soul.md", "score": 0.80, "abstract": "я помощник"},
        {"uri": "viking://user/default/memories/events/echo.md", "score": 0.71,
         "abstract": "time: 2026-08-21 [user]: так теперь смотри нужно раз в неделю обзор плагина делать"},
    ]
    picked = rank(cands, threshold=0.38, limit=3,
                  query="так теперь смотри нужно раз в неделю обзор плагина делать")
    assert [p["uri"][-4:] for p in picked] == ["a.md", "b.md"], picked  # no profile/soul/echo
    assert picked[1]["text"] == "старый мусор"  # legacy wrapper stripped for display
    out = render(picked)
    assert out.startswith("<relevant-memories>") and "events/a.md" in out and "0.61" in out
    assert "chat_id" not in out and "[user]" not in out
    assert render([]) == ""


def _row(kind, content, uuid, **extra):
    return json.dumps({"type": kind, "uuid": uuid, "message": {"role": kind, "content": content}, **extra},
                      ensure_ascii=False)


def test_last_turn_prefers_reply_tool_text():
    rows = [
        _row("user", "старый вопрос", "u0"),
        _row("assistant", [{"type": "text", "text": "старый ответ"}], "a0"),
        _row("user", WRAPPED, "u1", isMeta=True),
        _row("assistant", [{"type": "tool_use", "name": "Bash", "input": {"command": "ls"}}], "a1"),
        _row("user", [{"type": "tool_result", "content": "x"}], "t1"),
        _row("assistant", [{"type": "tool_use", "name": "mcp__dashi-channel__reply",
                            "input": {"chat_id": "1", "text": "Ответ в телеграм"}}], "a2"),
        _row("assistant", [{"type": "text", "text": "эхо в терминал"}], "a3"),
    ]
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False, encoding="utf-8") as fh:
        fh.write("\n".join(rows) + "\nnot json\n")
        path = fh.name
    uuid, ask, answer = last_turn(path)
    assert uuid == "u1" and ask == WRAPPED and answer == "Ответ в телеграм"


def test_last_turn_falls_back_to_final_text():
    rows = [_row("user", "вопрос без реплая в чат", "u1"),
            _row("assistant", [{"type": "text", "text": "финальный текст"}], "a1")]
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False, encoding="utf-8") as fh:
        fh.write("\n".join(rows))
        path = fh.name
    assert last_turn(path) == ("u1", "вопрос без реплая в чат", "финальный текст")


def test_threshold_follows_server_scale():
    # OpenViking >= 0.4.22 scores (cos + 1) / 2: 0.40 raw cosine == 0.70 now
    assert RECALL_THRESHOLD == 0.70
    assert uses_new_scale("v0.5.0") and uses_new_scale("v0.4.22") and uses_new_scale("")
    assert not uses_new_scale("v0.4.16") and not uses_new_scale("0.4.21")
    assert threshold_for("v0.5.0") == 0.70
    assert threshold_for("v0.4.16") == 0.40
    assert threshold_for("v0.4.16", 0.71) == 0.42


def test_recall_asks_server_for_scale():
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "ov_recall", Path(__file__).resolve().parent / "ov-recall.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.log = lambda *a, **k: None  # no log file in the tester's home
    hits = [{"uri": "viking://user/x/memories/events/a.md", "score": 0.66, "abstract": "запись A"},
            {"uri": "viking://user/x/memories/events/b.md", "score": 0.45, "abstract": "запись B"}]

    class Fake:
        def __init__(self, version):
            self.version = version

        def server_version(self):
            return self.version

        def find(self, query, scope, limit=8):
            return [dict(h) for h in hits]

    q = "какие цены на айфоны мы ставили на прошлой неделе"
    old = [m["uri"][-4:] for m in mod.recall(q, client=Fake("v0.4.16"))]
    new = [m["uri"][-4:] for m in mod.recall(q, client=Fake("v0.5.0"))]
    assert old == ["a.md", "b.md"], old   # raw cosine: both above 0.40
    assert new == [], new                 # (cos + 1) / 2: both are noise below 0.70


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print("ok", t.__name__)
    print(f"T1 unit: {len(tests)} passed")
