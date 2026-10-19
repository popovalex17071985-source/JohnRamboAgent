#!/usr/bin/env bash
# setup-memory.sh -- give the agent long-term memory (OpenViking) on its own box.
#
# Runs from install-kit.sh and from `dashi-ctl update`; idempotent, and skips
# instead of failing whenever the host cannot carry it.
#
# Money: none. Embeddings run locally when the box has RAM to spare; summaries
# reuse a provider key the box ALREADY holds (never copied in from elsewhere).
# No RAM and no local key -> the agent asks its owner via bin/memory-key-ask.py.
#
# Usage: setup-memory.sh --workspace DIR --agent NAME [--port 1933]
set -euo pipefail

WORKSPACE=""; AGENT=""; OV_PORT=1933; EMBED_PORT=1934
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --port) OV_PORT="$2"; shift 2 ;;
    --embed-port) EMBED_PORT="$2"; shift 2 ;;
    *) echo "setup-memory: неизвестный флаг $1" >&2; exit 2 ;;
  esac
done
[ -n "$WORKSPACE" ] && [ -n "$AGENT" ] || { echo "setup-memory: нужны --workspace и --agent" >&2; exit 2; }

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# OpenViking v0.5.0, pinned by digest like scripts/install-agent.sh: «:latest» gave
# every new agent whatever was out that day (0.4.21+ moved the data dir, see
# ov-conf-fix.py). Bump only after the old-memory recall check on Smith.
OV_IMAGE="ghcr.io/volcengine/openviking@sha256:c60a83cd79cfce80db5266acb8bdd0908eee8abe8ff559a5f786aa504c251ccf"
OWNER="$(stat -c %U "$WORKSPACE")"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
say() { echo "[memory] $*"; }

# --- gates: a missing prerequisite is a skip, never a failed install ---------
command -v docker >/dev/null 2>&1 || { say "docker нет -- долгую память пропускаю"; exit 0; }
[ "$(id -u)" = "0" ] || { say "нужен root для службы эмбеддингов -- пропускаю"; exit 0; }
MEM_AVAIL_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
SWAP_MB=$(awk '/SwapFree/ {print int($2/1024)}' /proc/meminfo)
# Подкачка тоже считается: модель эмбеддингов держит в памяти одни и те же веса,
# ядро спокойно свопит её холодную часть. Без этого VPS на 2 ГБ с включённым
# свопом отбраковывался как «не потянет».
MEM_BUDGET_MB=$(( MEM_AVAIL_MB + SWAP_MB / 2 ))
say "свободно памяти: ${MEM_AVAIL_MB} МБ (с подкачкой в расчёте: ${MEM_BUDGET_MB} МБ)"

# --- embeddings: local service when RAM allows ------------------------------
# 1500 MB is measured, not guessed: the service settles at ~1.0 GB and OpenViking
# itself takes ~0.5 GB (gorbot, 19.09.2026).
EMBED_OK=0
# Re-run on a box where the service already answers: it is holding that RAM
# itself, so the free-memory gate below would read "too tight" and wrongly
# report the local path as impossible (caught on gorbot, 19.09.2026).
# Порт может отвечать процессом, поднятым руками: после перезагрузки он не
# вернётся, а прошлая версия считала такой порт «уже готовым» и уходила дальше
# без автозапуска (поймано на Смите 20.09.2026). Нет службы -- гасим процесс и
# ставим всё как положено.
if curl -sf -m 5 "http://127.0.0.1:$EMBED_PORT/health" >/dev/null 2>&1 \
   && ! systemctl is-enabled --quiet dashi-embed 2>/dev/null; then
  say "эмбеддинги отвечают, но без службы -- оформляю автозапуск"
  pkill -f "uvicorn embed-serve[r]" 2>/dev/null || true
  sleep 2
fi

if curl -sf -m 5 "http://127.0.0.1:$EMBED_PORT/health" >/dev/null 2>&1; then
  EMBED_OK=1
  say "служба эмбеддингов уже живёт на 127.0.0.1:$EMBED_PORT"
# Замер 20.09.2026 на Смите: поднятый сервер эмбеддингов держит 735 МБ.
# Порог 1500 был взят с потолка и отсекал машины, где он помещается.
elif [ "$MEM_BUDGET_MB" -ge 1100 ]; then
  # 24.09.2026, агент Лены: у агентов со старого установщика нет $WORKSPACE/scripts,
  # install без -d падал «No such file or directory», и память молча не вставала.
  install -d -o "$OWNER" -g "$OWNER" "$WORKSPACE/scripts"
  install -o "$OWNER" -g "$OWNER" -m 755 "$KIT/embed-server.py" "$WORKSPACE/scripts/embed-server.py"
  # Там же не было pip (голая Ubuntu 22.04), а uv -- тоже нет: ставим pip из apt.
  # apt-get update обязателен -- со старым индексом пакеты отдают 404. Замок dpkg
  # ждём до 5 минут: на свежем сервере его держит unattended-upgrades.
  if ! python3 -m pip --version >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update -q >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q python3-pip >/dev/null 2>&1 \
      || say "pip из apt не встал"
  fi
  # Ставим с логом и второй попыткой: 20.09.2026 на Смите первый прогон pip
  # отвалился, вывод ушёл в /dev/null, и агент молча остался без памяти -- со
  # стороны это выглядело как «путь невозможен». Ровно та же команда со второго
  # раза отработала за минуту.
  PIPLOG="$WORKSPACE/logs/embed-install.log"
  mkdir -p "$(dirname "$PIPLOG")"
  PKGS="fastembed fastapi uvicorn"
  for attempt in 1 2; do
    su - "$OWNER" -c "python3 -m pip install -q --user $PKGS" >>"$PIPLOG" 2>&1 && break
    say "зависимости эмбеддингов не встали с попытки $attempt (подробности: $PIPLOG)"
    sleep 5
  done
  # pip не справился вовсе -- пробуем uv, он есть почти на каждой машине агента.
  if ! su - "$OWNER" -c "python3 -c 'import fastembed, fastapi, uvicorn'" >/dev/null 2>&1 \
     && command -v uv >/dev/null 2>&1; then
    su - "$OWNER" -c "uv pip install --system -q $PKGS" >>"$PIPLOG" 2>&1 || true
  fi
  if su - "$OWNER" -c "python3 -c 'import fastembed, fastapi, uvicorn'" >/dev/null 2>&1; then
    cat > /etc/systemd/system/dashi-embed.service <<UNIT
[Unit]
Description=Local OpenAI-compatible embeddings for agent memory
After=network.target

[Service]
User=$OWNER
Environment=HOME=$OWNER_HOME
Environment=OMP_NUM_THREADS=1
Environment=EMBED_MODEL=sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2
ExecStart=$OWNER_HOME/.local/bin/uvicorn embed-server:app --host 127.0.0.1 --port $EMBED_PORT
WorkingDirectory=$WORKSPACE/scripts
Restart=always
MemoryMax=1200M

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload; systemctl enable -q dashi-embed; systemctl restart dashi-embed
    for _ in $(seq 1 24); do sleep 5; curl -sf -m 5 "http://127.0.0.1:$EMBED_PORT/health" >/dev/null && { EMBED_OK=1; break; }; done
  fi
fi
[ "$EMBED_OK" = 1 ] && say "эмбеддинги локально на 127.0.0.1:$EMBED_PORT" \
  || say "локальные эмбеддинги не поднялись -- ключ попросит сам агент (bin/memory-key-ask.py)"

# --- summaries: only a key that already lives on this box -------------------
VLM_BASE=""; VLM_MODEL=""; VLM_KEY=""
ENV_FILE="/etc/dashi-plugin/$AGENT/channel.env"
if [ -f "$ENV_FILE" ]; then
  K="$(grep -oP '(?<=^GROQ_API_KEY=).*' "$ENV_FILE" || true)"
  if [ -n "$K" ]; then VLM_KEY="$K"; VLM_BASE="https://api.groq.com/openai/v1"; VLM_MODEL="openai/gpt-oss-20b"; fi
fi
[ -n "$VLM_KEY" ] && say "пересказы -- на ключе, который уже лежит на этой машине" \
  || say "ключа для пересказов на машине нет -- память поедет без них"

# --- config -----------------------------------------------------------------
OV_DIR="$OWNER_HOME/.openviking"
install -d -o "$OWNER" -g "$OWNER" "$OV_DIR" "$OV_DIR/appdata"
if [ "$EMBED_OK" = 1 ] && [ ! -s "$OV_DIR/ov.conf" ]; then
  DIM="$(curl -s -m 60 -X POST "http://127.0.0.1:$EMBED_PORT/v1/embeddings" \
    -H 'Content-Type: application/json' -d '{"input":"проверка"}' \
    | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"][0]["embedding"]))')"
  say "размерность вектора: $DIM"
  EMBED_BASE="http://127.0.0.1:$EMBED_PORT/v1" \
  EMBED_DIM="$DIM" VLM_BASE="$VLM_BASE" VLM_MODEL="$VLM_MODEL" VLM_KEY="$VLM_KEY" \
  python3 - "$OV_DIR/ov.conf" <<'PY'
import json, os, sys
path = sys.argv[1]
cfg = {
    "embedding": {"dense": {
        "api_base": os.environ["EMBED_BASE"], "api_key": "local",
        "provider": "openai", "dimension": int(os.environ["EMBED_DIM"]),
        "model": "local-embed", "input": "text"}},
    "server": {"host": "127.0.0.1"},
    # Absolute: since v0.4.21 the image cwd is /app/.openviking and the default
    # "./data" misses the appdata volume (ov-conf-fix.py).
    "storage": {"workspace": "/app/data"},
}
if os.environ.get("VLM_KEY"):
    cfg["vlm"] = {"api_base": os.environ["VLM_BASE"], "api_key": os.environ["VLM_KEY"],
                  "provider": "openai", "model": os.environ["VLM_MODEL"]}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, ensure_ascii=False, indent=2)
os.chmod(path, 0o600)
PY
  chown "$OWNER:$OWNER" "$OV_DIR/ov.conf"
elif [ -s "$OV_DIR/ov.conf" ]; then
  say "настройка памяти уже есть -- не переписываю"
fi
# Старый ov.conf (до 12.10.2026) без storage.workspace: дописываем ровно эту строку,
# туда, где память лежит сейчас -- иначе после обновления образа она «пропадает».
[ -s "$OV_DIR/ov.conf" ] && python3 "$KIT/ov-conf-fix.py" "$OV_DIR" | sed 's/^/[memory] /' || true

# --- service ----------------------------------------------------------------
if ! docker ps --format '{{.Names}}' | grep -qx openviking; then
  docker rm -f openviking >/dev/null 2>&1 || true
  # --network host + explicit SERVER_HOST: without the env it binds 0.0.0.0 and
  # dev auth mode refuses to start ("must not be exposed to the network").
  docker run -d --name openviking --restart unless-stopped --network host \
    -e OPENVIKING_SERVER_HOST=127.0.0.1 -e OPENVIKING_CONFIG_FILE=/app/.openviking/ov.conf \
    -v "$OV_DIR:/app/.openviking" -v "$OV_DIR/appdata:/app/data" \
    "$OV_IMAGE" >/dev/null
fi
for _ in $(seq 1 24); do sleep 5; curl -sf -m 5 "http://127.0.0.1:$OV_PORT/health" >/dev/null && break; done
curl -sf -m 5 "http://127.0.0.1:$OV_PORT/health" >/dev/null \
  && say "сервис памяти жив на 127.0.0.1:$OV_PORT" \
  || { say "сервис памяти не поднялся -- смотри docker logs openviking"; exit 0; }
# Порог плагина памяти -- под шкалу этого сервера (с v0.4.22 похожесть = (cos + 1) / 2).
OV_VER="$(curl -s -m 5 "http://127.0.0.1:$OV_PORT/health" 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("version",""))' 2>/dev/null || true)"
[ -n "$OV_VER" ] && python3 "$KIT/ov-conf-fix.py" "$OV_DIR" --server-version "$OV_VER" \
  | grep -v 'уже закреплена' | sed 's/^/[memory] /' || true

# --- flush path: a copied kit used to point at the coordinator's own folder --
SYNC="$WORKSPACE/scripts/ov-session-sync.sh"
install -o "$OWNER" -g "$OWNER" -m 755 "$KIT/ov-session-sync.sh" "$SYNC" 2>/dev/null || true
HOOK="$WORKSPACE/.claude/hooks/flush-to-openviking.sh"
if [ -f "$HOOK" ]; then
  # Only the legacy hard-coded SYNC path is rewritten. AGENT_NAME is already
  # filled by the installer; the old `AGENT_NAME=[..]*` rewrite matched the
  # empty string before a quote and produced AGENT_NAME=x"x" (06.10.2026).
  sed -i "s#SYNC=\"\$HOME/.claude-lab/[^/]*/scripts/ov-session-sync.sh\"#SYNC=\"$SYNC\"#" "$HOOK"
fi
install -d -o "$OWNER" -g "$OWNER" -m 700 "$OWNER_HOME/.claude-lab/shared/secrets"
KEYF="$OWNER_HOME/.claude-lab/shared/secrets/openviking.key"
[ -f "$KEYF" ] || { head -c 24 /dev/urandom | base64 > "$KEYF"; chmod 600 "$KEYF"; chown "$OWNER:$OWNER" "$KEYF"; }
if [ -f "$HOOK" ]; then
  say "готово: память подключена, слив идёт через $HOOK"
else
  # Раньше это место рапортовало об успехе безусловно: сервер стоял, а
  # писать в него было нечем, и понять это было неоткуда.
  say "! сервер памяти жив, но хука слива нет ($HOOK) -- память писаться НЕ будет"
fi
