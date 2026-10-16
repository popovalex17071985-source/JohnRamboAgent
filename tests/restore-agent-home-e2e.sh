#!/usr/bin/env bash
# E2E of the whole-home backup -> restore on two clean ubuntu:22.04 containers.
#   A = the old server: an agent with real work (a project dir next to the
#       workspace, a ~/.local/bin tool called from crontab, a venv with a pip
#       package, an apt package) -> agent-backup.sh as the agent user.
#   B = a new empty server: restore-agent.sh with the archive and the password.
# The installer is stubbed here (that path is covered by restore-agent-e2e.sh and
# by the real run on the staging server): this test is about the agent's data.
# Needs docker; network for apt and pip inside the containers.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
A=bk-old-$$; B=bk-new-$$; AGENT=e2ebot; PASS=e2e-pass-123
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; docker rm -f "$A" "$B" >/dev/null 2>&1' EXIT
ok(){ echo "✓ $1"; }
fail(){ echo "✗ $1" >&2; exit 1; }
inA(){ docker exec "$A" bash -c "$1"; }
inB(){ docker exec "$B" bash -c "$1"; }

for c in "$A" "$B"; do
  docker run -d --name "$c" ubuntu:22.04 sleep infinity >/dev/null || fail "контейнер $c не стартовал"
  docker cp "$PLUGIN" "$c:/opt/plugin" >/dev/null
done
inA "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gnupg python3 python3-venv cron jq >/dev/null 2>&1" \
  || fail "A: пакеты не встали"
ok "A: ubuntu 22.04 + gnupg/python3-venv/cron/jq"

# ── the old server: an agent with work outside the classic workspace items ──
inA "adduser --disabled-password --gecos '' agent >/dev/null
W=/home/agent/.claude-lab/$AGENT
mkdir -p \$W/.claude/memory \$W/secrets \$W/logs /home/agent/shop/data /home/agent/.local/bin /home/agent/.cache/x
echo '# память агента' > \$W/.claude/memory/MEMORY.md
echo '$PASS' > \$W/secrets/backup.pass; chmod 600 \$W/secrets/backup.pass
echo 'sku;price' > /home/agent/shop/data/prices.csv
printf '#!/bin/sh\necho tick >> /home/agent/shop/logs/tick.log\n' > /home/agent/.local/bin/tick; chmod +x /home/agent/.local/bin/tick
mkdir -p /home/agent/shop/logs; echo old > /home/agent/shop/logs/tick.log
echo cache > /home/agent/.cache/x/blob
chown -R agent:agent /home/agent
printf '[Service]\nUser=agent\nExecStart=/home/agent/.local/bin/tick\n' > /etc/systemd/system/shop-web.service
echo Asia/Yekaterinburg > /etc/timezone
mkdir -p \$W/state/backup; echo '{"ts": 1, "method": "rclone", "file": "x.gpg"}' > \$W/state/backup/last-offsite.json; chown -R agent:agent \$W/state
su - agent -c 'python3 -m venv /home/agent/shop/.venv && /home/agent/shop/.venv/bin/pip install -q six==1.16.0' >/dev/null 2>&1
su - agent -c '(echo \"* * * * * /home/agent/.local/bin/tick >> /home/agent/shop/logs/cron.log 2>&1\") | crontab -'
su - agent -c 'DASHI_AGENT=$AGENT DASHI_WORKSPACE=\$HOME/.claude-lab/$AGENT bash /opt/plugin/scripts/agent-backup.sh'
ls \$W/backups/*.gpg" >/dev/null || fail "A: бэкап не создан: $(inA "tail -5 /home/agent/.claude-lab/$AGENT/logs/backup.log")"
inA "tail -3 /home/agent/.claude-lab/$AGENT/logs/backup.log"
ARCH="$(inA "ls /home/agent/.claude-lab/$AGENT/backups/*.gpg | head -1")"
docker cp "$A:$ARCH" "$WORK/arch.gpg" >/dev/null || fail "архив не скопирован"
docker rm -f "$A" >/dev/null   # the old server is dead
ok "A: бэкап снят ($(du -h "$WORK/arch.gpg" | cut -f1)), старый сервер «умер»"

# ── the new server ──────────────────────────────────────────────────────────
docker cp "$WORK/arch.gpg" "$B:/root/$AGENT-20990101-0000.tar.gz.gpg" >/dev/null
# The stub does what the real installer does to deploy/: its «first backup» run
# rewrites the snapshots from the NEW box (found on Smith 17.10.2026: the agent's
# own units were lost that way).
inB "cat > /opt/plugin/scripts/install-agent.sh <<'EOS'
#!/bin/sh
echo stub installer \"\$@\" > /root/installer-called
runuser -u agent -- env DASHI_AGENT=$AGENT DASHI_WORKSPACE=/home/agent/.claude-lab/$AGENT bash /opt/plugin/scripts/agent-backup.sh
EOS"
out="$(inB "apt-get update -qq >/dev/null; bash /opt/plugin/scripts/restore-agent.sh --name $AGENT \
  --archive /root/$AGENT-20990101-0000.tar.gz.gpg --pass '$PASS' --yes" 2>&1)"; rc=$?
echo "$out" | tail -25
[[ $rc -eq 0 ]] || fail "restore rc=$rc"

inB "grep -q 'память агента' /home/agent/.claude-lab/$AGENT/.claude/memory/MEMORY.md" && ok "память на месте" || fail "нет памяти"
inB "grep -q 'sku;price' /home/agent/shop/data/prices.csv" && ok "проект рядом с workspace на месте" || fail "нет проекта"
inB "test -x /home/agent/.local/bin/tick" && ok "инструмент из ~/.local/bin на месте" || fail "нет ~/.local/bin/tick"
inB "test -d /home/agent/shop/logs && ! test -e /home/agent/shop/logs/tick.log" \
  && ok "папка логов есть, старые логи не приехали" || fail "логи: $(inB 'ls -la /home/agent/shop/logs')"
inB "test ! -e /home/agent/.cache/x/blob" && ok "кэш не приехал" || fail "кэш в архиве"
inB "crontab -u agent -l | grep -q /home/agent/.local/bin/tick" && ok "crontab восстановлен" || fail "нет crontab"
inB "su - agent -c '/home/agent/.local/bin/tick' && test -s /home/agent/shop/logs/tick.log" \
  && ok "скрипт из крона отрабатывает на новом сервере" || fail "скрипт из крона не работает"
inB "su - agent -c '/home/agent/shop/.venv/bin/python -c \"import six; print(six.__version__)\"' | grep -qx 1.16.0" \
  && ok "venv пересобран тем же python, six==1.16.0 импортируется" || fail "venv не пересобран"
inB "command -v jq >/dev/null" && ok "apt-пакет со старого сервера (jq) поставлен" || fail "jq не поставлен"
inB "grep -q -- '--name $AGENT' /root/installer-called" && ok "установщик вызван" || fail "установщик не вызван"
inB "grep -q /home/agent/.local/bin/tick /etc/systemd/system/shop-web.service" \
  && ok "свой юнит агента вернулся, хоть установщик и переснял снимки" || fail "юнит shop-web не вернулся"
grep -q 'Asia/Yekaterinburg' <<<"$out" && ok "restore знает пояс старого сервера" || fail "пояс старого сервера не прочитан"
inB "test ! -e /home/agent/.claude-lab/$AGENT/state/backup/last-offsite.json && test -s /home/agent/.claude-lab/$AGENT/state/backup/last-offsite.json.old-server" \
  && ok "журнал облака старого сервера отложен (сторож не скажет OK по чужим успехам)" || fail "журнал облака старого сервера остался"
inB "stat -c %U /home/agent/shop/data/prices.csv | grep -qx agent" && ok "владелец файлов — agent" || fail "владелец не agent"

# idempotent re-run: no re-extract, no failure
inB "echo 'новая запись' >> /home/agent/shop/data/prices.csv"
inB "bash /opt/plugin/scripts/restore-agent.sh --name $AGENT --archive /root/$AGENT-20990101-0000.tar.gz.gpg --pass '$PASS' --yes" \
  >"$WORK/rerun.log" 2>&1 || fail "повторный restore упал: $(tail -5 "$WORK/rerun.log")"
inB "grep -q 'новая запись' /home/agent/shop/data/prices.csv" && ok "повторный запуск не затёр новые данные" \
  || fail "повторный restore перезаписал данные"
grep -q 'уже распакованы' "$WORK/rerun.log" || fail "повторный restore не сказал, что пропускает распаковку"

echo "✓✓ whole-home restore e2e ПРОЙДЕН"
