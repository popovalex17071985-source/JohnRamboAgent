#!/usr/bin/env bash
# modal-watch.sh — прожимает модалки Claude Code, на которых висла бы очередь.
#
# Симптом: после /cc model (или обновления) Claude показывает «Switch model?» /
# «Continue?» и ждёт нажатия в терминале, которого в headless-агенте некому
# сделать — бот молчит на всё, пока кто-то не прожмёт. Этот скрипт из крона
# смотрит в tmux-панель и жмёт «1» сам.
#
# Использование: modal-watch.sh <tmux-session>
# Жмёт ТОЛЬКО когда в панели виден известный вопрос — иначе не трогает ничего.
set -euo pipefail

SESSION="${1:?usage: modal-watch.sh <tmux-session>}"
tmux has-session -t "$SESSION" 2>/dev/null || exit 0

pane="$(tmux capture-pane -pt "$SESSION" -S -30 2>/dev/null || true)"

# Крон зовёт нас как «modal-watch.sh channel-<agent>» — имя агента и есть хвост
# имени сессии; его конфиг лежит в /etc/dashi-plugin/<agent>/.
AGENT="${SESSION#channel-}"
ENV_FILE="${DASHI_ENV_FILE:-/etc/dashi-plugin/$AGENT/channel.env}"
TOKEN=""; CHAT=""; STATE_DIR="${TMPDIR:-/tmp}"
if [[ -r "$ENV_FILE" ]]; then
  TOKEN="$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$ENV_FILE" | head -1)"
  CHAT="$(sed -n 's/^TELEGRAM_ALLOWED_USER_IDS=//p' "$ENV_FILE" | head -1 | cut -d, -f1)"
  sd="$(sed -n 's/^TELEGRAM_STATE_DIR=//p' "$ENV_FILE" | head -1)"
  [[ -d "${sd:-}" ]] && STATE_DIR="$sd"
fi

# tell <текст> — написать хозяину напрямую через Bot API (бот в залипшем
# состоянии молчит, канал тут не поможет).
tell() {
  [[ -n "$TOKEN" && -n "$CHAT" ]] || return 1
  curl -sf -m 10 -o /dev/null --data-urlencode "text=$1" -d "chat_id=$CHAT" \
    "${TELEGRAM_API_ROOT:-https://api.telegram.org}/bot$TOKEN/sendMessage"
}

# ── Лимит подписки ───────────────────────────────────────────────────────────
# «You've hit your session limit · resets 3:40pm (...)» -- один раз сказать
# хозяину «лимит кончился, вернусь примерно в HH:MM» и потом «снова на связи».
# Отдельный скрипт: разбор времени сброса и состояние окна в $WS/data/ проще на
# Python. Клавиш он не жмёт, поэтому стоит ДО замка панели: занятый замок
# (автосжатие печатает) не должен съедать минуту уведомления. Ниже по скрипту
# есть ранний exit (залипший ввод) -- тоже повод звать его здесь.
timeout 30 python3 "$(dirname "${BASH_SOURCE[0]}")/limit-notice.py" "$SESSION" \
  >/dev/null 2>&1 || true
# Замок на панель: в неё печатают ДВА автомата -- этот сторож и автосжатие
# (context-autocompact.sh). Между набором «/compact» и Enter есть пауза, и
# чужое нажатие в эту щель уходит не туда: в диалоге «No, exit» так убивает
# Claude, tmux-сессия умирает, systemd поднимает службу заново
# (11.09.2026, gorbot: 15 рестартов за день). Один писатель на панель.
exec 9>"/tmp/dashi-pane-${SESSION//[^a-zA-Z0-9]/_}.lock"
flock -w 3 9 || exit 0

# Известные блокирующие модалки: «Switch model?», «Continue?» с нумерованным
# выбором. Признак живой модалки — маркер выбора «❯» рядом с пунктом 1/2.
if printf '%s' "$pane" | grep -qE 'Switch model\?|Continue\?' \
   && printf '%s' "$pane" | grep -q '❯'; then
  tmux send-keys -t "$SESSION" 1 2>/dev/null || true
  logger -t modal-watch "pressed 1 in $SESSION (blocking modal)" 2>/dev/null || true
fi

# ── Предложение отправить баг-репорт ────────────────────────────────────────
# Claude Code сам предлагает пожаловаться на свою ошибку («Submit feedback /
# bug report», варианты 1 review / 2 send / 0 dismiss) и ждёт нажатия. В
# headless-агенте нажимать некому: очередь встаёт, бот молчит на всё подряд.
# Отправлять отчёт от чужого имени мы не вправе, поэтому закрываем окно -- «0».
# (11.09.2026: чужой агент так провисел, пока владелец не нажал 0 вручную.)
# 15.09.2026: у агента Гора окно назвалось иначе -- «Bug report drafted: ...»,
# и точное совпадение по 'Submit feedback / bug report' его не поймало: диалог
# провисел с 11:07. Узнаём по строке вариантов «0 to dismiss» рядом со словом
# про отчёт -- формулировка шапки у Claude Code меняется, а варианты нет.
if printf '%s' "$pane" | grep -qiE 'submit feedback|bug report' \
   && printf '%s' "$pane" | grep -qE '0 to dismiss|\bdismiss\b'; then
  tmux send-keys -t "$SESSION" 0 2>/dev/null || true
  logger -t modal-watch "pressed 0 in $SESSION (bug-report prompt)" 2>/dev/null || true
fi

# ── Протухший вход в Claude ──────────────────────────────────────────────────
# «Login expired» — модалка, которую нажатием не прожать: нужен полный
# перелогин через /relogin. Бот в этом состоянии молчит, поэтому пишем хозяину
# напрямую через Bot API (токен и chat-id читаем из channel.env, как это
# делает agent-advisor.sh). Антиспам: флаг-файл, не чаще раза в 6 часов.
if printf '%s' "$pane" | grep -qE 'Login expired|Please run /login'; then
  FLAG="$STATE_DIR/login-expired-alerted"
  # mtime-антиспам: флаг свежее 6 часов (360 минут) — молчим.
  if [[ -z "$(find "$FLAG" -mmin -360 2>/dev/null)" ]] \
     && tell "Вход в Claude протух — отправь /relogin"; then
    touch "$FLAG" 2>/dev/null || true
    logger -t modal-watch "login expired in $SESSION — owner alerted" 2>/dev/null || true
  fi
fi

# ── Залипший ввод ────────────────────────────────────────────────────────────
# Канал вставляет сообщение владельца в строку ввода, но ход не стартует: текст
# висит в «❯ …», бот молчит на всё. Лестница из трёх ступеней -- каждая мягче
# следующей, перезапуск только последним (он убивает сессию).
#   1. дожать Enter -- чаще всего подтверждение просто потерялось;
#   2. перенабрать: C-u, напечатать тот же текст самим и Enter. Свой набор
#      через send-keys доходит всегда (проверено на Смите 12.09), а вставка
#      канала -- нет, поэтому перенабор вытаскивает сообщение без перезапуска;
#   3. перезапуск службы -- и СРАЗУ после подъёма вернуть тот же текст в панель,
#      чтобы сообщение не пропало вместе с сессией.
STUCK="$STATE_DIR/stuck-input"
PRESSED="$STATE_DIR/stuck-pressed"
RETYPED="$STATE_DIR/stuck-retyped"
# Claude Code ставит после «❯» неразрывный пробел (U+00A0), обычный '^❯ ' по
# нему не матчится — залипание проходило мимо (проверено на живой панели).
# Длинное сообщение переносится, продолжение идёт без «❯» и с отступом --
# склеиваем блок до нижней рамки, иначе вернули бы обрезанный текст.

# Claude Code сам подставляет в пустую строку ввода ПОДСКАЗКУ -- текст, который
# он предлагает отправить. Выглядит в панели как обычный ввод, но печатается
# тусклым (ESC[2m), тогда как живой черновик -- обычной яркостью. Сторож ловил
# подсказку за «залипшее сообщение» и раз в 25 минут перезапускал агента,
# убивая живой ход (12.09.2026, gorbot: подсказка «Проверь и Buds 4 в кабинете»).
ghost=""
comp_raw="$(tmux capture-pane -pet "$SESSION" -S -5 2>/dev/null | grep -a '❯' | tail -1 || true)"
[[ "$comp_raw" == *$'\033[2m'* ]] && ghost=1

typed="$(printf '%s\n' "$pane" | awk '
  /^❯/ { buf = $0; on = 1; next }
  on && /^─/ { on = 0; next }
  on { line = $0; sub(/^ +/, "", line); sub(/ +$/, "", line)
       if (line != "") buf = buf " " line }
  END { print buf }' | sed 's/^❯//; s/^\(\xc2\xa0\| \)*//; s/\(\xc2\xa0\| \)*$//')"

# pane_send <текст> — набрать и отправить. Замок на панель уже взят в начале
# скрипта; брать его ВТОРОЙ раз нельзя -- flock считает это чужим захватом и
# ждёт до таймаута, после чего нажатие молча не уходит. Ровно так 11-12.09 у
# Гора «дожатый Enter» не нажимался ни разу, а в журнал писалось, что нажат.
pane_send() {
  tmux send-keys -t "$SESSION" C-u 2>/dev/null || return 1
  sleep 0.3
  tmux send-keys -t "$SESSION" -l "$1" 2>/dev/null || return 1
  sleep 0.5
  tmux send-keys -t "$SESSION" Enter 2>/dev/null || return 1
}

if [[ -n "$typed" && -z "$ghost" ]] && ! printf '%s' "$pane" | grep -q 'esc to interrupt'; then
  sum="$(printf '%s' "$typed" | md5sum | cut -c1-16)"
  if [[ "$(cat "$STUCK" 2>/dev/null)" != "$sum" ]]; then
    # Первый раз текст только ЗАСЕКАЕМ, не жмём. Скрипты самого агента печатают
    # промпт через pane-send.sh и жмут Enter сами; тик сторожа попадает ровно в
    # эту секунду (у Гора каждый час в :20:02), видит ещё не отправленный текст
    # и добавляет лишний Enter. Ждём минуту: живой ход к тому времени начнётся,
    # и текста в строке уже не будет.
    printf '%s' "$sum" > "$STUCK"
  elif [[ "$(cat "$PRESSED" 2>/dev/null)" != "$sum" ]]; then
    printf '%s' "$sum" > "$PRESSED"
    tmux send-keys -t "$SESSION" Enter 2>/dev/null || true
    logger -t modal-watch "stuck input in $SESSION — pressed Enter" 2>/dev/null || true
  elif [[ "$(cat "$RETYPED" 2>/dev/null)" != "$sum" ]]; then
    # Enter не помог: тот же текст висит вторую минуту — перенабираем сами.
    printf '%s' "$sum" > "$RETYPED"
    pane_send "$typed" || true
    logger -t modal-watch "stuck input in $SESSION — retyped the message" 2>/dev/null || true
  elif [[ -z "$(find "$STUCK" -mmin -3 2>/dev/null)" ]] \
       && [[ -z "$(find "$STATE_DIR/stuck-restarted" -mmin -15 2>/dev/null)" ]]; then
    # тот же текст висит дольше 3 минут и последний перезапуск был давно
    # Перезапуск службы сторожу ЗАПРЕЩЁН по умолчанию (19.09.2026): он дожимает
    # Enter, перенабирает и зовёт хозяина, но службу не трогает -- перезапуск
    # убивает сессию вместе с контекстом. Обкатка на Смите 12.09--19.09 прошла
    # чисто: ни одного срабатывания сторожа за неделю, единственный подъём службы
    # 14.09 был ручным. До обкатки Гор поднимался 27 раз за сутки.
    # DASHI_WATCH_ALLOW_RESTART=1 -- вернуть старое поведение на одном агенте.
    if [[ -z "${DASHI_WATCH_ALLOW_RESTART:-}" ]]; then
      tell "Твоё сообщение застряло в строке ввода, дожать не вышло. Службу не трогаю (так велено). Текст: «${typed:0:200}»" || true
      logger -t modal-watch "stuck input in $SESSION — restart withheld (default since 19.09)" 2>/dev/null || true
      exit 0
    fi
    CTL="/usr/local/bin/dashi-ctl-$AGENT"
    if [[ -x "$CTL" ]] && sudo -n "$CTL" restart >/dev/null 2>&1; then
      touch "$STATE_DIR/stuck-restarted" 2>/dev/null || true
      rm -f "$STUCK" "$PRESSED" "$RETYPED" 2>/dev/null || true
      # Ждём, пока поднимется панель, и возвращаем в неё то же сообщение.
      delivered=""
      for _ in $(seq 1 30); do
        sleep 2
        scr="$(tmux capture-pane -pt "$SESSION" -S -10 2>/dev/null || true)"
        printf '%s' "$scr" | grep -q 'bypass permissions on' || continue
        pane_send "$typed" && delivered=1
        break
      done
      if [[ -n "$delivered" ]]; then
        logger -t modal-watch "stuck input in $SESSION — restarted, message redelivered" 2>/dev/null || true
      else
        tell "Я завис на твоём сообщении и перезапустил себя, вернуть его в работу не вышло. Повтори, пожалуйста: «${typed:0:200}»" || true
        logger -t modal-watch "stuck input in $SESSION — restarted, redelivery FAILED" 2>/dev/null || true
      fi
    fi
  fi
else
  rm -f "$STUCK" "$PRESSED" "$RETYPED" 2>/dev/null || true   # ввод пуст или идёт ход — всё в порядке
fi
exit 0
