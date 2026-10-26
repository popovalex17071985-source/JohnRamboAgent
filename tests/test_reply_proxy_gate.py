"""Tests for agent-kit/hooks/reply-proxy-gate.py -- the source gate BEFORE a reply leaves.

The Stop-time proxy gate fires when the answer is already in the owner's chat.
This one denies the reply itself: a negative/absence claim or a money figure
with nothing related opened in this turn does not go out. The eight phrases are
the eight false «нет» that reached the coordinator's owner in week 19-25.10.2026.
"""

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
HOOK = REPO_ROOT / "agent-kit" / "hooks" / "reply-proxy-gate.py"
_spec = importlib.util.spec_from_file_location("reply_proxy_gate", HOOK)
rpg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rpg)

PAD = " строка вывода источника" * 5     # evidence must pass MIN_EVIDENCE

WEEK = ["у аксессуаров нет серийников", "по дням нет.", "они не считаются нигде",
        "ни разу не тестировали", "оплата не пришла", "в логе не видно запуска",
        "маркетплейс такое не возьмёт", "у этой модели нет eSIM-версии"]


def probe(out: str) -> list[dict]:
    return [{"type": "assistant", "message": {"content": [
                {"type": "tool_use", "name": "Bash", "input": {"command": "cat x"}}]}},
            {"type": "user", "message": {"content": [
                {"type": "tool_result", "content": out + PAD}]}}]


class Decide(unittest.TestCase):
    def test_week_phrases_blocked_without_source(self) -> None:
        for t in WEEK:
            self.assertIsNotNone(rpg.decide(t, []), t)

    def test_money_figure_blocked_without_source(self) -> None:
        self.assertIsNotNone(rpg.decide("маржа сегодня 23 984 руб", []))

    def test_blocked_when_source_is_about_something_else(self) -> None:
        self.assertIsNotNone(
            rpg.decide("у аксессуаров нет серийников", probe("дамп конкурентов nkperm")))

    def test_passes_when_figure_is_in_what_was_read(self) -> None:
        self.assertIsNone(rpg.decide("маржа сегодня 23 984 руб", probe("итог: 23984")))

    def test_negative_about_opened_source_passes(self) -> None:
        self.assertIsNone(rpg.decide("в Dyson снимке ни разу не встречается",
                                     probe("trade59-dyson-snapshot.json пуст")))

    def test_lowercase_russian_claim_grounded_by_word_stem(self) -> None:
        # The right source was opened; inflected forms differ («аксессуаров»/«аксессуары»).
        self.assertIsNone(rpg.decide("у аксессуаров нет серийников",
                                     probe("аксессуары: серийники не ведутся")))
        self.assertIsNone(rpg.decide("оплата не пришла", probe("платёж 77: оплата ожидается")))

    def test_passes_when_marked_unverified(self) -> None:
        for t in ["гипотеза: у аксессуаров нет серийников, проверяю",
                  "оплата не пришла [unverified]", "не проверял, но по дням нет"]:
            self.assertIsNone(rpg.decide(t, []), t)

    def test_plain_chat_passes(self) -> None:
        for t in ["Принял, делаю", "Нет проблем, сделаю", "Сделано. Коммит 4419554",
                  "проблем нет.", "готово, коммит fc6ec9b, 3 файла", "нет пока, не готово",
                  "пока нет.", "замечаний нет.", "нет замечаний", ""]:
            self.assertIsNone(rpg.decide(t, []), t)


class Hook(unittest.TestCase):
    """The rendered hook as Claude Code runs it: stdin JSON in, deny JSON out."""

    def run_hook(self, text: str, rows: list[dict]) -> str:
        with tempfile.TemporaryDirectory() as tmp:
            tp = Path(tmp) / "t.jsonl"
            tp.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n")
            payload = {"tool_name": "mcp__dashi-channel__reply", "transcript_path": str(tp),
                       "tool_input": {"chat_id": "1", "text": text}}
            res = subprocess.run([sys.executable, str(HOOK)], input=json.dumps(payload),
                                 capture_output=True, text=True, timeout=30)
        self.assertEqual(res.returncode, 0, res.stderr)
        return res.stdout

    def test_denies_negative_claim_when_turn_opened_nothing(self) -> None:
        out = json.loads(self.run_hook("у этой модели нет eSIM-версии",
                                       [{"type": "user", "message": {"content": "есть eSIM?"}}]))
        hso = out["hookSpecificOutput"]
        self.assertEqual(hso["hookEventName"], "PreToolUse")
        self.assertEqual(hso["permissionDecision"], "deny")
        self.assertIn("НЕ отправлено", hso["permissionDecisionReason"])

    def test_only_the_current_turn_counts(self) -> None:
        # The read happened in the PREVIOUS turn: this turn opened nothing.
        rows = ([{"type": "user", "message": {"content": "раз"}}] + probe("итог: 23984")
                + [{"type": "user", "message": {"content": "а маржа?"}}])
        self.assertIn('"deny"', self.run_hook("маржа сегодня 23 984 руб", rows))
        self.assertEqual(self.run_hook("маржа сегодня 23 984 руб", rows[:-1]), "")

    def test_broken_input_never_blocks(self) -> None:
        res = subprocess.run([sys.executable, str(HOOK)], input="not json",
                             capture_output=True, text=True, timeout=30)
        self.assertEqual((res.returncode, res.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main()
