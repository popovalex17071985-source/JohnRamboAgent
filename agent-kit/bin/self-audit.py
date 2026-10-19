#!/usr/bin/env python3
"""Самодиагностика обвязки: какие механизмы живы, а какие только числятся.

14.08.2026 выяснилось, что пять Stop-гейтов не срабатывали ни разу с рождения —
нарезали ход неверным условием. Проверялись они только логикой в голове, а не
на живых данных. Этот скрипт проверяет ФАКТ работы, а не наличие файла:

  1. хуки из .claude/settings.json — файл на месте, исполняемый, selfcheck
     проходит, сухой прогон на реальном транскрипте не падает;
  2. хуки-сироты в hooks/ — лежат, но ни в одном событии не подключены;
  3. кроны — команда существует; лог, в который пишет строка, обновлялся
     не позже, чем 3 периода назад (иначе задание молчит);
  4. скрипты, на которые ссылается память (MEMORY.md/LEARNINGS.md/rules.md),
     но которых нет на диске.

    python3 bin/self-audit.py            # отчёт в консоль
    python3 bin/self-audit.py --json     # машинный вид
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import sys
import datetime as dt
import time
from pathlib import Path

# bin/self-audit.py -> ROOT = рабочая папка агента. Зашитого пути нет: комплект
# раскладывается в /home/<user>/.claude-lab/<agent> и имя агента заранее неизвестно.
ROOT = Path(os.environ.get("AGENT_WORKSPACE_ROOT") or Path(__file__).resolve().parent.parent)
SETTINGS = ROOT / ".claude/settings.json"
HOOK_DIRS = [ROOT / "hooks", ROOT / ".claude/hooks"]
TRANSCRIPTS = Path.home() / ".claude/projects"
MEMORY_FILES = [ROOT / ".claude/core/MEMORY.md", ROOT / ".claude/core/LEARNINGS.md",
                ROOT / ".claude/core/rules.md", ROOT / ".claude/core/TOOLS.md"]
PY = str(ROOT / ".venv-bot/bin/python")
DAY = 86400
# Как часто должен отмечаться крон: минимальный период из расписания -> допуск.
PERIOD_TOLERANCE = 3


def sh(cmd: list[str], stdin: str = "", timeout: int = 20, full: bool = False) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, input=stdin, capture_output=True, text=True, timeout=timeout)
        out = p.stdout + p.stderr
        return p.returncode, out if full else out[-400:]
    except subprocess.TimeoutExpired:
        return 124, "таймаут"
    except Exception as e:                     # noqa: BLE001
        return 1, str(e)[:200]


def expand(cmd: str) -> str:
    r"""Путь к скрипту из команды хука или крон-строки.

    Крон почти всегда пишет `cd <root> && python bin/x.py`: путь относительный,
    и наивный поиск `/...\.py` ловил хвост «/offload-effect.py» и объявлял
    несуществующий скрипт. Берём первый токен-скрипт после интерпретатора и
    резолвим относительно ROOT.
    """
    cmd = cmd.replace("$HOME", str(Path.home()))
    cmd = cmd.split("#")[0]
    for tok in re.findall(r"[^\s'\"><|]+\.(?:py|sh|ts|js|mjs)", cmd):
        p = Path(tok) if tok.startswith("/") else ROOT / tok
        if p.exists():
            return str(p)
    m = re.search(r"[^\s'\"><|]+\.(?:py|sh|ts|js|mjs)", cmd)
    if not m:
        return ""
    tok = m.group(0)
    return str(Path(tok) if tok.startswith("/") else ROOT / tok)


def latest_transcript() -> Path | None:
    files = sorted(TRANSCRIPTS.rglob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    return files[0] if files else None


def audit_hooks() -> list[dict]:
    data = json.loads(SETTINGS.read_text())
    tp = latest_transcript()
    out, wired = [], set()
    for event, groups in (data.get("hooks") or {}).items():
        for g in groups:
            for h in g.get("hooks", []):
                path = expand(h.get("command", ""))
                if not path:
                    continue
                p = Path(path)
                wired.add(p.name)
                row = {"event": event, "hook": p.name, "path": str(p)}
                if not p.exists():
                    row["verdict"] = "НЕТ ФАЙЛА"
                    out.append(row)
                    continue
                if p.suffix in (".py", ".sh") and not os.access(p, os.X_OK):
                    row["verdict"] = "не исполняемый"
                    out.append(row)
                    continue
                src = p.read_text(errors="ignore") if p.suffix in (".py", ".sh") else ""
                row["selfcheck"] = "--selfcheck" in src
                if row["selfcheck"]:
                    runner = [PY, str(p)] if p.suffix == ".py" else ["bash", str(p)]
                    code, out_txt = sh(runner + ["--selfcheck"])
                    row["selfcheck_ok"] = code == 0
                    if code:
                        row["detail"] = out_txt[-120:]
                # сухой прогон на живом транскрипте — падает или нет
                if tp and p.suffix in (".py", ".sh"):
                    payload = json.dumps({"transcript_path": str(tp), "hook_event_name": event})
                    runner = [PY, str(p)] if p.suffix == ".py" else ["bash", str(p)]
                    # honour the hook's own timeout from settings.json: a slow but
                    # legitimately-configured hook (flush-to-openviking: 90s) must not
                    # be reported dead just because our default is 20s
                    limit = int(h.get("timeout") or 20) + 5
                    code, out_txt = sh(runner, stdin=payload, timeout=limit)
                    row["dry_run"] = code
                    if code not in (0, 2):
                        row["detail"] = out_txt[-120:]
                row["verdict"] = verdict_hook(row)
                out.append(row)
    # ov_memory lesson 24.08: a file can be a library imported by wired hooks —
    # grep siblings for its stem before calling it an orphan (delete-safety).
    sibling_src = "\n".join(
        q.read_text(errors="ignore")
        for d in HOOK_DIRS for q in list(d.glob("*.py")) + list(d.glob("*.sh")))
    for d in HOOK_DIRS:
        for p in sorted(d.glob("*.py")) + sorted(d.glob("*.sh")):
            if p.name not in wired and p.name != "turnlib.py":
                refs = len(re.findall(rf"\b{re.escape(p.stem)}\b", sibling_src))
                if refs > 1:  # 1 = its own occurrences boundary; >1 = referenced elsewhere
                    out.append({"event": "—", "hook": p.name, "path": str(p),
                                "verdict": "ок (модуль, импортируется хуками)"})
                else:
                    out.append({"event": "—", "hook": p.name, "path": str(p),
                                "verdict": "СИРОТА (не подключён)"})
    return out


def verdict_hook(row: dict) -> str:
    if row.get("selfcheck") and not row.get("selfcheck_ok"):
        return "SELFCHECK ПАДАЕТ"
    if row.get("dry_run") not in (None, 0, 2):
        return f"ПАДАЕТ (exit {row['dry_run']})"
    if not row.get("selfcheck"):
        return "жив, но без самопроверки"
    return "ок"


def cron_period(spec: str) -> int:
    """Грубая оценка периода задания в секундах по первым 5 полям."""
    f = spec.split()[:5]
    if len(f) < 5:
        return DAY
    minute, hour, dom, mon, dow = f
    if minute.startswith("*/"):
        period = int(minute[2:]) * 60
        hw = re.fullmatch(r"(\d+)-(\d+)", hour)
        if hw:  # hour window (e.g. 6-23): overnight silence is scheduled, not death
            period = max(period, (24 - int(hw.group(2)) - 1 + int(hw.group(1))) * 3600 + period)
        return period
    if hour.startswith("*/"):
        return int(hour[2:]) * 3600
    if hour == "*":
        return 3600
    if dom != "*" or mon != "*":
        return 31 * DAY
    if dow != "*":
        return 7 * DAY
    return DAY * (1 if "," not in hour else 1)


def product_age(script: str) -> float | None:
    """Возраст самого свежего файла, который скрипт пишет (часы).

    Пустой лог с древним mtime ещё не значит смерть: скрипт может не писать в
    stdout вовсе. price-check-cycle.sh молчит с мая, а рекомендации по ценам
    сыплются каждый день — судить надо по продукту, а не по логу.
    """
    if not script or not Path(script).exists():
        return None
    try:
        src = Path(script).read_text(errors="ignore")
    except Exception:                          # noqa: BLE001
        return None
    best = None
    # файл состояния часто назван по скрипту, а в коде собирается из кусков
    stem = Path(script).stem.replace("_", "-").split("-")[0]
    if len(stem) > 3:
        for d in ("data", "state", "logs"):
            for c in (ROOT / d).glob(f"*{stem}*"):
                if c.is_file():
                    age = (time.time() - c.stat().st_mtime) / 3600
                    best = age if best is None else min(best, age)
    for m in re.finditer(r"((?:data|logs|state)/[\w./-]+)", src):
        f = ROOT / m.group(1)
        cands = sorted(f.parent.glob(f.name.replace("$", "*") + "*")) if "*" in f.name or "$" in f.name else [f]
        for c in cands:
            if c.is_file():
                age = (time.time() - c.stat().st_mtime) / 3600
                best = age if best is None else min(best, age)
    return round(best, 1) if best is not None else None


def audit_cron() -> list[dict]:
    code, raw = sh(["crontab", "-l"], timeout=10, full=True)   # обрезка съедала 108 строк
    if code:
        return [{"job": "crontab -l", "verdict": "НЕ ЧИТАЕТСЯ"}]
    rows = []
    # usage-report/digest теперь пишут success-строку сами — им тишина снова симптом
    QUIET_BY_DESIGN = ("rotate-warm.sh", "deferred-reminder.py", "task-runner.py", "logrotate",
                       "insales-mail-orders-tg.py",  # пишет только при заявке/ошибке (проверен руками 24.08)
                       "pricespot-agent.py",  # 1/мин, пишет только при СОБРАНО (проверен руками 26.08)
                       "insales-orders-tg.py")  # 1/2мин, пишет только при новом заказе (проверен руками 28.08)
    now = time.time()
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" in line.split()[0]:
            continue
        script = expand(line)
        log = re.search(r">>?\s*([^\s|&]+\.log)", line)
        row = {"job": (script or line)[-70:], "period_h": round(cron_period(line) / 3600, 2)}
        if script and not Path(script).exists():
            row["verdict"] = "НЕТ СКРИПТА"
            rows.append(row)
            continue
        row["product_age_h"] = product_age(script)
        if log:
            lp = Path(log.group(1))
            if not lp.exists():
                row["verdict"] = "ЛОГА НЕТ (не запускался?)"
            else:
                age = now - lp.stat().st_mtime
                # ponytail: cron-редирект ловит только stdout. Скрипт со своим
                # logging-файлом оставляет <name>.cron.log пустым навсегда —
                # insales-orders-tg выглядел мёртвым 97.9 дн, пиша в <name>.log
                # каждые 2 минуты (28.08.2026). Судим по свежайшему из двух.
                own = lp.with_name(lp.name.replace(".cron.log", ".log"))
                if own != lp and own.exists():
                    age = min(age, now - own.stat().st_mtime)
                row["log_age_h"] = round(age / 3600, 1)
                # Суточной задаче допуск x3 = трое суток слепоты: пропущенная
                # ночь Б/У-карточек 27.08 прошла незамеченной. Редким задачам —
                # допуск в четверть периода, частым остаётся x3.
                per = cron_period(line)
                limit = per * (1.25 if per >= 6 * 3600 else PERIOD_TOLERANCE)
                fresh_product = (row["product_age_h"] is not None
                                 and row["product_age_h"] * 3600 <= limit)
                # ponytail: quiet-by-design jobs write stdout only on action/error;
                # an old log there is normal, not death
                quiet_ok = any(q in line for q in QUIET_BY_DESIGN)
                row["verdict"] = ("ок" if age <= limit else
                                  # скрипт может молчать в stdout: тогда судим по продукту
                                  "ок (по продукту)" if fresh_product else
                                  "ок (тихий по природе)" if quiet_ok else
                                  f"МОЛЧИТ {age / DAY:.1f} дн")
        else:
            row["verdict"] = "нет лога — проверить вручную"
        rows.append(row)
    return rows


def audit_model() -> list[dict]:
    """Model drift: any usage.jsonl row in the last 24h whose model differs from the
    wrapper's --model flag. Closes the 21.08 hole (27 turns on opus-4-8, nobody saw)."""
    import re as _re
    root = Path(__file__).resolve().parent.parent
    usage = root / ".claude/core/usage.jsonl"
    # Флаг модели живёт в systemd-юните агента (ExecStart ... --model X). Юнита или
    # флага нет — проверка молчит: у агента может быть модель по умолчанию аккаунта,
    # и это не поломка, а выбор хозяина.
    want = None
    for unit in Path("/etc/systemd/system").glob("dashi-*.service"):
        m = _re.search(r"--model\s+(\S+)", unit.read_text(errors="ignore"))
        if m:
            want = m.group(1)
            break
    if not want:
        return [{"job": "model", "verdict": "ок", "detail": "модель по умолчанию аккаунта"}]
    since = time.time() - 24 * 3600
    seen: dict[str, int] = {}
    if usage.exists():
        for line in usage.read_text().splitlines()[-2000:]:
            try:
                row = json.loads(line)
                ts = dt.datetime.fromisoformat(row["ts"]).timestamp()
            except Exception:
                continue
            if ts >= since and True:
                seen[row.get("model") or "?"] = seen.get(row.get("model") or "?", 0) + 1
    drift = {k: v for k, v in seen.items() if k != want}
    if drift:
        return [{"job": "model", "verdict": "ДРЕЙФ",
                 "detail": f"ждём {want}, за 24ч ходов на других: {drift}"}]
    return [{"job": "model", "verdict": "ок", "detail": f"{want}, ходов за 24ч: {seen.get(want, 0)}"}]


# Ссылка на скрипт в памяти: bin/…, hooks/…, scripts/… -- от корня рабочей папки,
# либо целиком от ~ или / (группа 1). Префикс берётся только с начала пути: в
# «.claude/dashi-plugin-claude-code/agent-kit/bin/x.sh» кусок
# «/dashi-plugin-claude-code/agent-kit/» -- середина относительного пути, а не
# абсолютный путь, и такая ссылка по-прежнему ищется от корня.
MEMORY_REF_RE = re.compile(
    r"((?<![\w.~/-])(?:~|/)[\w.~/-]*/)?((?:bin|hooks|scripts)/[\w./-]+\.(?:py|js|sh|mjs|ts))")


def audit_memory_refs() -> list[dict]:
    """Скрипты, на которые ссылается память, но которых нет на диске."""
    seen, out = set(), []
    for f in MEMORY_FILES:
        if not f.exists():
            continue
        for m in MEMORY_REF_RE.finditer(f.read_text(errors="ignore")):
            prefix, rel = m.group(1), m.group(2)
            ref = (prefix or "") + rel
            if ref in seen:
                continue
            seen.add(ref)
            # Путь от ~ или / -- скрипт другого проекта, проверяется как есть
            # (15.10.2026: заметка про ~/dkpbu/scripts/backup.sh числилась
            # пропавшей -- её искали в корне рабочей папки агента).
            if prefix:
                if not Path(ref).expanduser().exists():
                    out.append({"ref": ref, "in": f.name, "verdict": "НЕТ ФАЙЛА"})
                continue
            # Память ссылается и на скрипты комплекта агентов: они лежат в
            # репозитории плагина, а не в корне рабочей папки (13.09.2026 --
            # remind-at.sh и install-agent.sh два дня числились пропавшими).
            plug = ROOT / ".claude" / "dashi-plugin-claude-code"
            alts = [ROOT / rel, ROOT / ".claude" / rel,
                    plug / rel, plug / "agent-kit" / rel, plug / "plugin" / rel]
            if not any(a.exists() for a in alts):
                out.append({"ref": rel, "in": f.name, "verdict": "НЕТ ФАЙЛА"})
    return out


def audit_promises() -> list[dict]:
    """Скрипты, которые шлют Сане обещания от первого лица напрямую (tg-notify),
    но не будят сессию (oneshot-inject) — обещание повиснет, пока Саня не пнёт.
    Класс закрыт 26.08 (self-audit-morning); гейт ловит новых нарушителей."""
    root = Path(__file__).resolve().parent.parent
    # ponytail: «сделаю» выкинуто — оно ловит ОФФЕРЫ («Скажи «обновляй X» — сделаю»),
    # где обещания нет: скрипт ждёт команду, а не молча уносит задачу. (28.08.2026)
    promise = re.compile("проверю|вернусь|разберусь|посмотрю|займусь|исправлю|починю|подчищу")
    out = []
    for d in ("bin", "hooks", "scripts"):
        for f in (root / d).rglob("*"):
            if f.suffix not in (".py", ".sh") or "_archived" in str(f) or ".bak" in f.name:
                continue
            if f.name == Path(__file__).name:  # сам аудит: обещания в его тексте исполняет побудка morning.sh
                continue
            try:
                src = f.read_text(errors="ignore")
            except OSError:
                continue
            if "tg-notify" in src and promise.search(src) and "oneshot-inject" not in src:
                out.append({"job": str(f.relative_to(root)),
                            "verdict": "ОБЕЩАЕТ БЕЗ ПОБУДКИ",
                            "detail": "шлёт «проверю/вернусь» напрямую, сессию не будит"})
    return out


def audit_cron_alive() -> list[dict]:
    """Канарейка: минутный крон трогает файл. Файл протух — крон НЕ выполняет мой
    список задач, какой бы ни была причина. 27.08.2026 крон 6 часов отказывался
    грузить crontab из-за лишней жёсткой ссылки, и это было не видно ниоткуда."""
    hb = Path(__file__).resolve().parent.parent / "data" / "cron-heartbeat"
    if not hb.exists():
        return [{"job": "крон-канарейка", "verdict": "КРОН НЕ РАБОТАЕТ",
                 "detail": "минутная задача ещё ни разу не отметилась"}]
    age_min = (time.time() - hb.stat().st_mtime) / 60
    if age_min > 5:
        return [{"job": "крон-канарейка", "verdict": "КРОН НЕ РАБОТАЕТ",
                 "detail": f"минутная задача молчит {age_min:.0f} мин"}]
    return [{"job": "крон-канарейка", "verdict": "ок", "detail": f"{age_min:.1f} мин"}]


def main() -> int:
    report = {"hooks": audit_hooks(), "cron": audit_cron(), "model": audit_model(), "cron_alive": audit_cron_alive(),
              "memory_refs": audit_memory_refs(), "promises": audit_promises()}
    if "--json" in sys.argv:
        print(json.dumps(report, ensure_ascii=False, indent=1))
        return 0
    if "--human" in sys.argv:
        probs = []
        for section, rows in report.items():
            for r in rows:
                v = str(r.get("verdict", ""))
                name = pathlib.Path(str(r.get("hook") or r.get("job") or r.get("ref") or "?")).name
                if v in ("нет лога — проверить вручную", "ЛОГА НЕТ (не запускался?)"):
                    # 19.09.2026: именно через этот класс прошёл слив памяти --
                    # задача не запускалась ни разу, и отчёт об этом молчал.
                    probs.append(f"{name}: НИ РАЗУ НЕ ЗАПУСКАЛСЯ (лога нет)")
                    continue
                if v.startswith("ок") or v in ("?", "жив, но без самопроверки"):
                    continue
                if v.startswith("МОЛЧИТ"):
                    days = v.split()[1]
                    per = r.get("period_h") or 0
                    per_txt = (f"по крону должен работать примерно раз в {per:g} ч"
                               if per and per < 100 else "запускается по расписанию")
                    probs.append(f"• {name} — не подаёт признаков жизни {days} дн, хотя {per_txt}. Проверю, жив ли.")
                elif "СИРОТА" in v:
                    probs.append(f"• {name} — файл лежит в папке хуков, но никуда не подключён: мусор или забыли подключить. Разберусь.")
                elif v == "КРОН НЕ РАБОТАЕТ":
                    probs.append(f"• КРОН НЕ ВЫПОЛНЯЕТ ЗАДАЧИ — {r.get('detail','')}. "
                                 f"Это не одна задача, это все сразу. Разбираюсь немедленно.")
                elif "модель" in name or v == "ДРЕЙФ":
                    probs.append(f"• модель — {r.get('detail', 'часть ходов за сутки прошла не на основной модели')}. Если это не мои тесты — разберусь почему.")
                elif v == "НЕТ ФАЙЛА" and section != "memory_refs":
                    probs.append(f"• {name} — хук прописан в настройках, а файла нет. Починю.")
                elif v == "ОБЕЩАЕТ БЕЗ ПОБУДКИ":
                    probs.append(f"• {name} — шлёт тебе «проверю/вернусь» напрямую, но меня не будит: обещание повиснет. Подключу побудку.")
                elif v == "НЕТ СКРИПТА":
                    probs.append(f"• {name} — крон зовёт скрипт, которого нет на диске. Починю.")
                elif v == "НЕТ ФАЙЛА (ссылка из памяти)" or section == "memory_refs":
                    probs.append(f"• память — заметка ссылается на {name}, а файла нет. Подчищу.")
                else:
                    probs.append(f"• {name} — {v}")
        if probs:
            print(f"Самопроверка 07:00: {len(probs)} подозрений. Не всё из этого поломка — я проверю каждое и вернусь только с реальным.")
            print("\n".join(probs))
        else:
            print("Самопроверка 07:00: всё зелёное.")
        return 0
    bad = 0
    for section, rows in report.items():
        print(f"\n=== {section} ({len(rows)}) ===")
        for r in rows:
            v = r.get("verdict", "?")
            if v != "ок":
                bad += 1
            mark = "  " if v == "ок" else "! "
            name = r.get("hook") or r.get("job") or r.get("ref")
            extra = f" [{r['event']}]" if r.get("event") else ""
            print(f"{mark}{name}{extra}: {v}"
                  + (f" — {r['detail']}" if r.get("detail") else ""))
    print(f"\nитого проблемных строк: {bad}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
