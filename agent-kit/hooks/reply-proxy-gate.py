#!/usr/bin/env python3
"""PreToolUse на отправку хозяину -- гейт первоисточника ДО того, как сообщение ушло.

stop-proxy-gate.py срабатывает на конце хода, когда ответ уже лежит в чате
хозяина: его блок покупает максимум поправку вторым сообщением. Здесь тот же
вердикт применяется к отправляемому ответу: негативное утверждение («нет такого»,
«ни разу не», «не пришло») или цифра по деньгам/метрике, когда в этом ходе не
открыто ничего, что с ними связано, -- отказ; сообщение не уходит, пока
источник не прочитан. Координатор, 25.10.2026: 8 ложных «нет» из 8 за неделю
дошли до хозяина раньше, чем Stop-гейт успел возразить.

Логика (шаблоны, связь сказанного с прочитанным) -- общая со stop-proxy-gate.py,
здесь только вход PreToolUse и честный выход: «гипотеза» / «не проверял» /
[unverified] в тексте -- это уже не утверждение, пропускаем.
Best-effort: любая внутренняя ошибка = пропускаем (exit 0).
"""
from __future__ import annotations

import importlib.util
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("stop_proxy_gate", HERE / "stop-proxy-gate.py")
spg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(spg)

UNVERIFIED = re.compile(r"гипотез|не\s+проверял|\[непроверено\]|\[unverified\]", re.I)


def decide(text: str, entries: list[dict]) -> str | None:
    """Причина отказа для этого ответа или None."""
    if not text or UNVERIFIED.search(text):
        return None
    _, probes, evidence = spg.scan(entries)
    return spg.verdict(text, probes, evidence)


def main() -> int:
    try:
        data = json.load(sys.stdin)
        text = str((data.get("tool_input") or {}).get("text", ""))
        tp = data.get("transcript_path")
        entries = spg.turn_entries(Path(tp)) if tp and Path(tp).exists() else []
        why = decide(text, entries)
    except Exception:
        return 0
    if why:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "permissionDecision": "deny",
            "permissionDecisionReason": "Сообщение НЕ отправлено. " + why
            + "\nЧестно не знаешь -- так и напиши: «гипотеза, проверяю»."}},
            ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
