"""Общая нарезка транскрипта на ходы для Stop-хуков.

Каждый гейт нарезал транскрипт сам условием `type=="user" and not isMeta` — и
все шесть промахивались одинаково: ответы инструментов приходят тем же
type=="user" (их в 9 раз больше промптов) и isMeta у них нет, а настоящие
сообщения из телеграма, наоборот, помечены isMeta=true. Итог: «ходом» гейт
считал 1-3 записи после последнего tool_result, текста для оператора там уже нет —
и ни один гейт не срабатывал (проверено на живом транскрипте 14.08.2026).
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

# Хуки на каждой отправке и в конце хода читают только хвост транскрипта: у
# координатора 19.10.2026 он дорос до 108 МБ, и чтение целиком брало ~0.9 ГБ
# памяти на хук -- сервер на 8 ГБ ловил OOM. Самый длинный ход там был 5.7 МБ;
# ход длиннее окна гейт видит как «весь хвост = ход» (промпт не найден -> с начала).
TAIL_BYTES = 8 * 1024 * 1024

# Хук-контекст и системные врезки приходят тем же type=="user", что и оператор.
NOISE_RX = re.compile(
    r"^\s*(?:\[SYSTEM\]|Telegram bridge:|<relevant-memories>|\[прошлый ход|"
    r"context-economy|<system-reminder|<command-|Caveat:|This session is being continued)")


def is_prompt(e: dict) -> bool:
    """Настоящий ввод оператора: не tool_result и не врезка хука."""
    if e.get("type") != "user":
        return False
    c = (e.get("message") or {}).get("content")
    return isinstance(c, str) and bool(c.strip()) and not NOISE_RX.match(c)


def tail_lines(path: Path | str, max_bytes: int = TAIL_BYTES) -> list[str]:
    """Последние целые строки файла из его хвостовых max_bytes байт.

    Файл меньше окна читается целиком. Иначе первая (обрезанная) строка окна
    отбрасывается; если срез пришёлся ровно на начало строки -- она остаётся.
    Делим только по \\n (JSONL), а не splitlines(): U+2028/NEL внутри JSON-строки
    не рвут запись.
    """
    lines = []
    with open(path, "rb") as fh:
        size = fh.seek(0, os.SEEK_END)
        start = max(0, size - max_bytes)
        if start > 0:
            # Байт перед окном не \n -- окно начинается с хвоста чужой строки.
            fh.seek(start - 1)
            if fh.read(1) != b"\n":
                fh.readline()
        else:
            fh.seek(0)
        # Построчно, без общего буфера: пик памяти ~ размер окна, не x3-x4.
        for raw in fh:
            if raw.endswith(b"\n"):
                raw = raw[:-1]
            lines.append(raw.decode("utf-8", errors="replace"))
    return lines


def turn_entries(transcript: Path) -> list[dict]:
    """Записи транскрипта ПОСЛЕ последнего сообщения пользователя (в хвосте)."""
    rows = []
    for line in tail_lines(transcript):
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    start = 0
    for i, e in enumerate(rows):
        if is_prompt(e):
            start = i
    return rows[start:]


def _selfcheck() -> None:
    tg = {"type": "user", "isMeta": True,
          "message": {"content": '<channel source="telegram"> Делаем </channel>'}}
    noise = {"type": "user", "isMeta": True,
             "message": {"content": "Telegram bridge: the sender reads Telegram"}}
    result = {"type": "user", "message": {"content": [{"type": "tool_result", "content": "ok"}]}}
    assert is_prompt(tg), "сообщение из телеграма — это промпт, несмотря на isMeta"
    assert not is_prompt(noise) and not is_prompt(result)
    print("turnlib: selfcheck ok")


if __name__ == "__main__":
    _selfcheck()
