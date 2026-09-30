"""Tests for agent-kit/hooks/promise-alarm.py -- the Stop hook that arms an alarm.

The whole point of the hook is that «вернусь с прогоном» stops being a promise
nothing enforces. Untested, it had two ways to fail silently: never recognising
the promise, or arming the same alarm on every turn of one conversation.

The shipped file carries a `__WORKSPACE__` placeholder that install-kit.sh
substitutes, so the loader here does the same substitution against a tmpdir.
"""

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[1]
HOOK_PATH = REPO_ROOT / "agent-kit" / "hooks" / "promise-alarm.py"


def load_hook(workspace: Path):
    """Load the hook with __WORKSPACE__ pointed at a throwaway directory."""
    source = HOOK_PATH.read_text(encoding="utf-8").replace("__WORKSPACE__", str(workspace))
    module_name = f"promise_alarm_{abs(hash(str(workspace)))}"
    spec = importlib.util.spec_from_loader(module_name, loader=None)
    module = importlib.util.module_from_spec(spec)
    module.__file__ = str(HOOK_PATH)
    sys.modules[module_name] = module
    exec(compile(source, str(HOOK_PATH), "exec"), module.__dict__)
    return module


def transcript(tmp: Path, entries) -> str:
    """Write a Claude Code style JSONL transcript and return its path."""
    path = tmp / "transcript.jsonl"
    with path.open("w", encoding="utf-8") as fh:
        for entry in entries:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
    return str(path)


def assistant(text: str) -> dict:
    return {"message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}


def user(text: str) -> dict:
    return {"message": {"role": "user", "content": [{"type": "text", "text": text}]}}


class HookCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ws = Path(self.tmp.name)
        (self.ws / "bin").mkdir(parents=True)
        (self.ws / "bin" / "remind-at.sh").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.hook = load_hook(self.ws)
        self.addCleanup(self.tmp.cleanup)


class PromiseSentenceTest(HookCase):
    def test_finds_the_committing_sentence(self):
        text = "Тесты зелёные. Беру правку 4, вернусь с прогоном."

        self.assertEqual(
            self.hook.promise_sentence(text), "Беру правку 4, вернусь с прогоном."
        )

    def test_plain_report_is_not_a_promise(self):
        self.assertIsNone(self.hook.promise_sentence("Готово. 2903 теста, 0 падений."))

    def test_bare_done_line_never_arms_an_alarm(self):
        self.assertIsNone(self.hook.promise_sentence("Сделано."))

    def test_matches_each_commitment_form(self):
        for phrase in (
            "Берусь за карантин.",
            "Вернусь с результатом.",
            "Продолжу завтра.",
            "Дальше правка 5.",
            "Иду копать логи.",
            "Сейчас сделаю прогон.",
            "Запустил, вернусь через час.",
            "Отчитаюсь по итогам.",
        ):
            with self.subTest(phrase=phrase):
                self.assertEqual(self.hook.promise_sentence(phrase), phrase)

    def test_returns_the_first_promise_when_there_are_several(self):
        text = "Беру карантин. Потом продолжу с будильником."

        self.assertEqual(self.hook.promise_sentence(text), "Беру карантин.")

    def test_long_promise_is_trimmed_for_the_pane(self):
        promise = "Беру " + "очень длинную задачу " * 20

        result = self.hook.promise_sentence(promise)

        self.assertEqual(len(result), self.hook.MAX_PROMISE_CHARS)

    def test_promise_split_across_lines_is_still_found(self):
        text = "Итог: тесты прошли\nВернусь с питоновой частью."

        self.assertEqual(self.hook.promise_sentence(text), "Вернусь с питоновой частью.")

    def test_empty_text_is_not_a_promise(self):
        self.assertIsNone(self.hook.promise_sentence(""))

    def test_future_verbs_ending_in_beru_are_not_a_promise(self):
        for text in ("Соберу сводку к вечеру.", "Разберу логи завтра."):
            with self.subTest(text=text):
                self.assertIsNone(self.hook.promise_sentence(text))

    def test_conditional_promises_do_not_arm(self):
        for text in (
            "Ответит — соберу сводку и вернусь.",
            "Когда подключу, сразу вернусь с разбором.",
            "Кинешь ссылку -- подключу и отчитаюсь.",
            "Если нужно — скажи склад, вернусь со сводкой.",
        ):
            with self.subTest(text=text):
                self.assertIsNone(self.hook.promise_sentence(text))

    def test_the_three_false_alarms_of_30_09(self):
        for text in (
            "Ответит — соберу сводку по накладной №487 и после его «да» оприходую.",
            "Когда подключу, сразу разберу всё, что вышло с 24.08.",
            "Приходовать не стал: Сане написал, что если нужно — пусть назовёт склад, "
            "соберу сводку.",
        ):
            with self.subTest(text=text):
                self.assertIsNone(self.hook.promise_sentence(text))

    def test_quoted_verbs_do_not_arm(self):
        self.assertIsNone(
            self.hook.promise_sentence("- **Причина:** шаблон «беру» ловил «соберу» и «разберу».")
        )
        self.assertEqual(
            self.hook.promise_sentence("Сказал «беру», вернусь с прогоном."),
            "Сказал «беру», вернусь с прогоном.",
        )


class FinalTextTest(HookCase):
    def test_reads_the_last_assistant_message(self):
        path = transcript(
            self.ws,
            [assistant("первый ответ"), user("дальше?"), assistant("вернусь с прогоном")],
        )

        self.assertEqual(self.hook.final_text(path), "вернусь с прогоном")

    def test_user_messages_are_ignored_even_when_last(self):
        path = transcript(self.ws, [assistant("беру правку"), user("вернусь сам")])

        self.assertEqual(self.hook.final_text(path), "беру правку")

    def test_joins_several_text_blocks_of_one_message(self):
        path = transcript(
            self.ws,
            [
                {
                    "message": {
                        "role": "assistant",
                        "content": [
                            {"type": "text", "text": "часть 1"},
                            {"type": "tool_use", "name": "Bash"},
                            {"type": "text", "text": "часть 2"},
                        ],
                    }
                }
            ],
        )

        self.assertEqual(self.hook.final_text(path), "часть 1\nчасть 2")

    def test_tool_only_message_is_skipped_for_the_text_one_below(self):
        path = transcript(
            self.ws,
            [
                assistant("вернусь с прогоном"),
                {"message": {"role": "assistant", "content": [{"type": "tool_use"}]}},
            ],
        )

        self.assertEqual(self.hook.final_text(path), "вернусь с прогоном")

    def test_broken_lines_do_not_stop_the_scan(self):
        path = self.ws / "t.jsonl"
        path.write_text(
            json.dumps(assistant("беру задачу")) + "\n{ битая строка\n", encoding="utf-8"
        )

        self.assertEqual(self.hook.final_text(str(path)), "беру задачу")

    def test_missing_transcript_returns_empty(self):
        self.assertEqual(self.hook.final_text(str(self.ws / "нет.jsonl")), "")


class RecentlyArmedTest(HookCase):
    def test_first_call_is_not_recent_and_records_the_state(self):
        self.assertFalse(self.hook.recently_armed("Беру правку 4."))
        state = json.loads(self.hook.STATE_PATH.read_text(encoding="utf-8"))
        self.assertEqual(state["promise"], "Беру правку 4.")

    def test_same_promise_inside_the_cooldown_is_suppressed(self):
        self.hook.recently_armed("Беру правку 4.")

        self.assertTrue(self.hook.recently_armed("Беру правку 4."))

    def test_different_promise_arms_again(self):
        self.hook.recently_armed("Беру правку 4.")

        self.assertFalse(self.hook.recently_armed("Вернусь с прогоном."))

    def test_state_older_than_the_cooldown_stops_suppressing(self):
        self.hook.recently_armed("Беру правку 4.")
        state = json.loads(self.hook.STATE_PATH.read_text(encoding="utf-8"))
        stale = datetime.fromisoformat(state["armed_at"]) - timedelta(
            minutes=self.hook.COOLDOWN_MIN + 1
        )
        state["armed_at"] = stale.isoformat()
        self.hook.STATE_PATH.write_text(json.dumps(state), encoding="utf-8")

        self.assertFalse(self.hook.recently_armed("Беру правку 4."))

    def test_corrupt_state_is_treated_as_no_alarm_set(self):
        self.hook.STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        self.hook.STATE_PATH.write_text("{{{", encoding="utf-8")

        self.assertFalse(self.hook.recently_armed("Беру правку 4."))


class MainTest(HookCase):
    def run_hook(self, payload):
        calls = []

        def fake_run(command, **kwargs):
            calls.append(command)

            class Done:
                returncode = 0
                stdout = b""
                stderr = b""

            return Done()

        with patch.object(sys, "stdin", io.StringIO(json.dumps(payload))):
            with patch.object(self.hook.subprocess, "run", fake_run):
                code = self.hook.main()
        return code, calls

    def test_promise_schedules_the_reminder(self):
        path = transcript(self.ws, [assistant("Беру правку 4, вернусь с прогоном.")])

        code, calls = self.run_hook({"transcript_path": path})

        self.assertEqual(code, 0)
        self.assertEqual(len(calls), 1)
        command = calls[0]
        self.assertEqual(command[0], str(self.ws / "bin" / "remind-at.sh"))
        self.assertIn("ПРОДОЛЖАЙ БЕЗ НАПОМИНАНИЯ", command[2])
        self.assertIn("Беру правку 4, вернусь с прогоном.", command[2])

    def test_reminder_time_is_a_few_minutes_out(self):
        path = transcript(self.ws, [assistant("Вернусь с прогоном.")])

        _, calls = self.run_hook({"transcript_path": path})

        fire_at = datetime.now(self.hook.OWNER_TZ) + timedelta(minutes=self.hook.DELAY_MIN)
        allowed = {
            (fire_at + timedelta(minutes=drift)).strftime("%d.%m %H:%M") for drift in (-1, 0, 1)
        }
        self.assertIn(calls[0][1], allowed)

    def test_report_without_a_promise_schedules_nothing(self):
        path = transcript(self.ws, [assistant("Готово. Тесты зелёные.")])

        code, calls = self.run_hook({"transcript_path": path})

        self.assertEqual(code, 0)
        self.assertEqual(calls, [])

    def test_repeated_turn_about_the_same_task_does_not_pile_up_alarms(self):
        path = transcript(self.ws, [assistant("Беру правку 4, вернусь с прогоном.")])

        self.run_hook({"transcript_path": path})
        _, calls = self.run_hook({"transcript_path": path})

        self.assertEqual(calls, [])
        log = self.hook.LOG_PATH.read_text(encoding="utf-8")
        self.assertIn("будильник уже стоит", log)

    def test_successful_arming_is_logged(self):
        path = transcript(self.ws, [assistant("Беру правку 4.")])

        self.run_hook({"transcript_path": path})

        self.assertIn("поставил будильник", self.hook.LOG_PATH.read_text(encoding="utf-8"))

    def test_payload_without_transcript_path_exits_quietly(self):
        code, calls = self.run_hook({})

        self.assertEqual(code, 0)
        self.assertEqual(calls, [])

    def test_broken_payload_exits_quietly(self):
        with patch.object(sys, "stdin", io.StringIO("{ не json")):
            self.assertEqual(self.hook.main(), 0)

    def test_scheduler_failure_is_logged_not_raised(self):
        path = transcript(self.ws, [assistant("Беру правку 4.")])

        def boom(command, **kwargs):
            raise OSError("remind-at.sh отсутствует")

        with patch.object(sys, "stdin", io.StringIO(json.dumps({"transcript_path": path}))):
            with patch.object(self.hook.subprocess, "run", boom):
                code = self.hook.main()

        self.assertEqual(code, 0)
        self.assertIn("будильник не встал", self.hook.LOG_PATH.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
