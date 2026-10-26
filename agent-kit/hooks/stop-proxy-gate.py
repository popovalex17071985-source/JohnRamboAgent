#!/usr/bin/env python3
"""Stop hook — не дать сдать цифру или негативное утверждение, ничего не открыв.

Топ-1 класс рецидивов: 22 записи в LEARNINGS.md с 19.06 по 04.08.2026 — «соврал,
что AirPods 0», «стальных Watch S9 не бывает», «0 из 28 заказов». Один и тот же
сценарий: беру число или отсутствие из памяти/соседнего артефакта и выдаю как
факт, не открыв первоисточник. rules.md §1 про это написан в июне и не сработал
ни разу — в момент отправки я уверен, что уже знаю ответ. Уверенность лечится
гейтом, не правилом.

Гейт узкий, чтобы не мешать жить: блокирует, только когда в сообщении хозяину есть
сильный триггер (негативное утверждение о наличии, деньги/метрика, «продано/
остаток/маржа/оборот» с числом) И в ЭТОМ ходе не было НИ ОДНОГО чтения источника.

06.09.2026 обнаружилась вторая дыра, из-за которой за неделю прошли 4 таких
случая: «прочитал что угодно» засчитывалось за проверку. Открыл один файл, а
утверждение сделал про другой — гейт молчал. Так прошло «по Дайсонам конкурентов
не собираем» при живом снимке: в том ходе читалось другое.

Поэтому теперь мало ФАКТА чтения — нужна СВЯЗЬ прочитанного с утверждением:
хотя бы одно число (или, для негативных утверждений, хотя бы одно предметное
слово) из ответа должно встречаться в том, что этот ход реально открыл. Ни
одного совпадения = число пришло из головы. Агрегаты не страдают: совпадения
достаточно ОДНОГО, а итог обычно стоит рядом со слагаемыми.

Best-effort: любая внутренняя ошибка = пропускаем ход (exit 0).
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import sys as _sys
_sys.path.insert(0, str(Path(__file__).resolve().parent))
from turnlib import turn_entries  # noqa: E402

REPLY_TOOL = "mcp__dashi-channel__reply"
PROBE_TOOLS = {"Bash", "Read", "Grep", "Glob", "WebFetch", "WebSearch", "Task"}

# Негативные утверждения о наличии — самый дорогой класс ошибок (rules.md §1).
NEGATIVE = re.compile(
    r"\bнет\s+(?:такого|таких|ни\s+одного|в\s+наличии|записей|данных|позиц)|"
    r"не\s+бывает|отсутству|ни\s+одного|нигде\s+не\s+|"
    r"\b0\s+(?:из|шт|позиц|заказ)|нулево|"
    # 25.10.2026, координатор: все 8 ложных «нет» недели прошли мимо старого
    # списка («у аксессуаров нет серийников», «по дням нет», «не считаются
    # нигде», «ни разу не тестировали»). Обычные «нет проблем/смысла» -- мимо.
    r"ни\s+разу\s+не|не\s+[а-яё]+\s+нигде|\bне\s+(?:пришл|видно|возьм|считают|считает)|"
    r"\bнет\s+(?!проблем|смысла|вопрос|времени)[A-Za-zа-яё][\w-]{3,}|"
    r"\b(?!или\b|проблем\b)[а-яё]{3,}\s+нет(?=\s*[.,;!?)\n]|\s*$)",
    re.IGNORECASE | re.MULTILINE,
)
# Деньги и метрики: число рядом с денежным/учётным словом.
METRIC = re.compile(
    r"(?:\d[\d\s.,]*)\s*(?:₽|руб)|"
    r"(?:маржа|оборот|выручк|продано|остаток|закуп|средний\s+чек|конверси)"
    r"[^\n]{0,40}?\d",
    re.IGNORECASE,
)


def scan(entries: list[dict]) -> tuple[str, int, str]:
    """(текст хозяину; число обращений к источникам; всё, что этот ход открыл).

    В evidence идут и аргументы вызовов (путь, команда, паттерн), и их вывод —
    цифру можно назвать и по имени файла, и по содержимому.
    """
    said, probes, seen = [], 0, []
    for e in entries:
        for block in (e.get("message") or {}).get("content") or []:
            if not isinstance(block, dict):
                continue
            kind = block.get("type")
            if kind == "tool_result":                      # вывод инструмента
                seen.append(_flatten(block.get("content")))
                continue
            if kind != "tool_use" or e.get("type") != "assistant":
                continue
            name = block.get("name") or ""
            if name == REPLY_TOOL:
                said.append(str((block.get("input") or {}).get("text", "")))
            elif name in PROBE_TOOLS or name.startswith("mcp__"):
                probes += 1
                seen.append(json.dumps(block.get("input") or {}, ensure_ascii=False))
    return "\n".join(said), probes, "\n".join(seen)


def _flatten(content) -> str:
    """tool_result бывает строкой, списком блоков или картинкой."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            c.get("text", "") if isinstance(c, dict) else str(c) for c in content)
    return ""


# Число от трёх знаков: «7 позиций» ловить не надо, «13 500» и «105990» -- надо.
_NUM = re.compile(r"\d[\d\s\u00a0.,]{2,}\d")
# Предметное слово: латинская сущность (Dyson, trade59, AirPods) или имя с
# заглавной. Служебные слова короче четырёх букв отсекаются длиной.
_WORD = re.compile(r"[A-Za-z][A-Za-z0-9_.\-]{3,}|[А-ЯЁ][а-яё]{3,}")
MIN_EVIDENCE = 50          # меньше -- открывали картинку или пустой вывод


def _digits(s: str) -> set[str]:
    """Числа в обоих написаниях: «105 990» и «105990» -- одно и то же число.

    Разделитель тысяч бывает пробелом, поэтому берём и склеенные группы, и
    каждое число по отдельности: иначе «105990 99990» в выводе слипается в
    одно и не совпадает ни с чем.
    """
    out = {re.sub(r"[\s\u00a0.,]", "", m) for m in _NUM.findall(s)}
    out |= {m for m in re.findall(r"\d{3,}", s)}
    return out


def grounded(text: str, evidence: str, negative: bool) -> bool:
    """Есть ли связь между сказанным и тем, что ход реально открыл."""
    if len(evidence) < MIN_EVIDENCE:
        return True                                  # нечем судить -- не мешаем
    nums = _digits(text)
    if nums and (nums & _digits(evidence)):
        return True
    if negative:
        # Сравниваем вхождением, а не равенством: «Dyson» обязано засчитаться
        # против «trade59-dyson-snapshot.json» в пути открытого файла.
        low = evidence.lower()
        words = {w.lower() for w in _WORD.findall(text)}
        if words and any(w in low for w in words):
            return True
        return False
    return not nums                                  # чисел нет -- судить не о чем


def verdict(text: str, probes: int, evidence: str = "") -> str | None:
    """Причина блокировки или None."""
    if not text:
        return None
    negative = bool(NEGATIVE.search(text))
    hit = "негативное утверждение" if negative else (
        "цифру по деньгам/метрике" if METRIC.search(text) else None)
    if not hit:
        return None
    if probes:
        if grounded(text, evidence, negative):
            return None
        return (
            f"Ты отдаёшь хозяину {hit}, и источники в этом ходе открывал -- но НЕ ТЕ: "
            "ни одно число (ни одно предметное слово) из ответа не встречается в "
            "том, что ты прочитал. Значит проверял одно, а говоришь про другое -- "
            "ровно так 05.09 прошло «по Дайсонам конкурентов не собираем» при "
            "живом снимке.\n"
            "Открой источник ИМЕННО про то, о чём говоришь, и пересчитай оттуда. "
            "Если цифра действительно выведена (сумма, разница) -- покажи рядом "
            "слагаемые из источника."
        )
    return (
        f"Ты отдаёшь хозяину {hit}, а в этом ходе не открыл НИ ОДНОГО источника: "
        "ни Read, ни Bash, ни запроса к API. Значит цифра или «нет такого» "
        "взяты из памяти или соседнего артефакта — это ровно тот класс, из-за "
        "которого уже 22 раза выходило враньё (rules.md §1).\n"
        "Открой первоисточник (core/SOURCES.md — какой именно), пересчитай "
        "оттуда, потом отвечай. Если утверждение не про наши данные и источник "
        "не нужен — переформулируй без цифры и без «нет такого»."
    )


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    if data.get("stop_hook_active"):
        return 0
    tp = data.get("transcript_path")
    if not tp or not Path(tp).exists():
        return 0
    try:
        why = verdict(*scan(turn_entries(Path(tp))))
    except Exception:
        return 0
    if why:
        print(json.dumps({"decision": "block", "reason": why}))
    return 0


def _selfcheck() -> None:
    def reply(text):
        return {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": REPLY_TOOL, "input": {"text": text}}]}}

    def probe(path="/x"):
        return {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": "Read", "input": {"file_path": path}}]}}

    def out(text):
        return {"type": "user", "message": {"content": [
            {"type": "tool_result", "content": text}]}}

    pad = " строка вывода источника" * 5      # чтобы перевалить MIN_EVIDENCE

    # Цифра по деньгам без единого чтения — блок.
    assert verdict(*scan([reply("маржа сегодня 23 984 руб")])) is not None
    # Негативное утверждение без чтения — блок.
    assert verdict(*scan([reply("таких позиций нет в наличии")])) is not None
    # То же самое, но источник открыт — пропускаем.
    assert verdict(*scan([probe(), reply("маржа сегодня 23 984 руб")])) is None
    # Обычный разговор без цифр — не трогаем.
    assert verdict(*scan([reply("принято,делаю")])) is None
    # Технический отчёт про файлы — не должен ловиться.
    assert verdict(*scan([reply("готово, коммит fc6ec9b, 3 файла")])) is None
    # Дыра 06.09.2026: читал одно -- говорю про другое. Раньше проходило.
    assert verdict(*scan([probe(), out("дамп конкурентов nkperm" + pad),
                          reply("маржа сегодня 23 984 руб")])) is not None
    # Число из ответа реально было в выводе -- пропускаем.
    assert verdict(*scan([probe(), out("итог: 23984" + pad),
                          reply("маржа сегодня 23 984 руб")])) is None
    # Агрегат: итог сам не встречается, но слагаемое -- да. Не мешаем.
    assert verdict(*scan([probe(), out("105990 99990" + pad),
                          reply("было 105 990, стало 99 990, экономия 6 000 руб")])) is None
    # Негативное утверждение про то, что открывали -- пропускаем.
    assert verdict(*scan([probe(), out("файл trade59-dyson-snapshot пуст" + pad),
                          reply("по Dyson снимка нет, отсутствуют записи")])) is None
    # ...а про то, чего не открывали -- блок.
    assert verdict(*scan([probe(), out("совсем про другое" + pad),
                          reply("по Dyson конкурентов нет, ни одного")])) is not None
    print("stop-proxy-gate: selfcheck ok")


if __name__ == "__main__":
    if "--selfcheck" in sys.argv:
        _selfcheck()
    else:
        sys.exit(main())
