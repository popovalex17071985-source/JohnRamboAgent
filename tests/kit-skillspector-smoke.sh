#!/usr/bin/env bash
# Smoke: install-kit.sh puts the skill scanner (skillspector) in reach of the agent
# and wires skill-install-gate.sh -- without the scanner the gate demands a check
# nothing can run. Best-effort: no uv / no network / a failing uv must never fail
# the kit. No network here: uv and curl are fakes, PATH holds only what the kit needs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "✗ $*"; exit 1; }

# A PATH with no real uv, curl or skillspector, whatever the host has installed.
mkdir -p "$T/sys" "$T/fake"
for tool in bash sh env sed mktemp cmp cat cp mkdir chmod dirname basename python3 date \
            grep stat id getent cut rm timeout printf head tr uname tar sha256sum mv; do
  p="$(command -v "$tool" 2>/dev/null)" && ln -sf "$p" "$T/sys/$tool"
done
# Fake uv: logs its argv and "installs" the scanner where uv tool install puts it.
cat > "$T/fake/uv" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$UV_LOG"
[ "${UV_FAIL:-0}" = 1 ] && exit 1
mkdir -p "$HOME/.local/bin" && printf '#!/bin/sh\n' > "$HOME/.local/bin/skillspector" \
  && chmod +x "$HOME/.local/bin/skillspector"
SH
# Fake curl: the network is down.
printf '#!/bin/sh\nexit 7\n' > "$T/fake/curl"
chmod +x "$T/fake/uv" "$T/fake/curl"
export UV_LOG="$T/uv.log"

kit() { # name, PATH, extra env...
  local name="$1" path="$2"; shift 2
  mkdir -p "$T/$name/home" "$T/$name/ws/.claude"
  env -i PATH="$path" HOME="$T/$name/home" UV_LOG="$UV_LOG" KIT_NO_CRON=1 KIT_NO_MEMORY=1 "$@" \
    bash "$ROOT/agent-kit/install-kit.sh" --claude-dir "$T/$name/ws/.claude" --chat-id 42 \
    --agent smoke --tz UTC > "$T/$name.out" 2>&1
}

# 1. uv present -> the scanner is installed from its repo, once.
kit a "$T/fake:$T/sys" || { cat "$T/a.out"; fail "комплект упал с uv"; }
# Pinned commit: the scanner is installed past its own gate, a moving HEAD won't do.
grep -qxE -- "tool install -q git\+https://github.com/NVIDIA/skillspector\.git@[0-9a-f]{40}" "$UV_LOG" \
  || fail "uv не позван ставить skillspector: $(cat "$UV_LOG" 2>/dev/null)"
grep -q "сканер навыков skillspector поставлен" "$T/a.out" || fail "нет строки об установке сканера"
python3 -c "
import json,sys;d=json.load(open('$T/a/ws/.claude/settings.json'))
sys.exit(0 if any(e.get('matcher')=='Bash' and any(h['command'].endswith('/skill-install-gate.sh') for h in e['hooks'])
                  for e in d['hooks'].get('PreToolUse',[])) else 1)" \
  || fail "гейт установки навыков не зарегистрирован на PreToolUse/Bash"
[ -x "$T/a/ws/.claude/hooks/skill-install-gate.sh" ] || fail "гейт установки навыков не разложен"

# 2. Re-run: already installed -> uv is not called again.
kit a "$T/fake:$T/sys" || fail "повторный прогон упал"
[ "$(wc -l < "$UV_LOG")" = 1 ] || fail "сканер ставится заново на каждом прогоне: $(cat "$UV_LOG")"

# 3. No uv, network down -> the pinned release is not fetched, one line, kit alive.
rm -f "$T/fake/uv"; : > "$UV_LOG"
printf '#!/bin/sh\necho curl >> "$UV_LOG"; exit 7\n' > "$T/fake/curl"
kit b "$T/fake:$T/sys" || { cat "$T/b.out"; fail "без uv и сети комплект упал"; }
grep -q curl "$UV_LOG" || fail "без uv комплект даже не попробовал скачать проверенный uv"
grep -q "uv не скачался" "$T/b.out" || fail "без сети нет понятной строки: $(tail -3 "$T/b.out")"
grep -q "сканер навыков не поставлен" "$T/b.out" || fail "без uv нет строки про сканер"
[ ! -e "$T/b/home/.local/bin/uv" ] || fail "без сети uv откуда-то появился"

# 3b. A tarball that is not the pinned release (checksum mismatch) -> nothing
# installed, nothing executed, one line. Real curl over file://, no network.
rm -f "$T/fake/curl"; ln -sf "$(command -v curl)" "$T/sys/curl"
arch=$(uname -m); case "$arch" in amd64) arch=x86_64 ;; arm64) arch=aarch64 ;; esac
mkdir -p "$T/rel/uv-$arch-unknown-linux-gnu"
printf '#!/bin/sh\necho EXECUTED >> "%s"\n' "$UV_LOG" > "$T/rel/uv-$arch-unknown-linux-gnu/uv"
chmod +x "$T/rel/uv-$arch-unknown-linux-gnu/uv"
tar -czf "$T/rel/uv-$arch-unknown-linux-gnu.tar.gz" -C "$T/rel" "uv-$arch-unknown-linux-gnu"
: > "$UV_LOG"
kit m "$T/fake:$T/sys" KIT_UV_URL_BASE="file://$T/rel" || { cat "$T/m.out"; fail "чужой архив uv уронил комплект"; }
grep -q "контрольная сумма uv не сошлась" "$T/m.out" || fail "подменённый uv без строки о сумме: $(tail -3 "$T/m.out")"
[ ! -e "$T/m/home/.local/bin/uv" ] || fail "подменённый uv положен в ~/.local/bin"
grep -q EXECUTED "$UV_LOG" && fail "подменённый uv был запущен"
grep -q "сканер навыков не поставлен" "$T/m.out" || fail "после несошедшейся суммы нет строки про сканер"
rm -f "$T/sys/curl"
# The hardcoded sums are real sha256 and the installer is never piped into a shell.
grep -qE '^UV_SHA256_X86_64="[0-9a-f]{64}"$' "$ROOT/agent-kit/install-kit.sh" \
  && grep -qE '^UV_SHA256_AARCH64="[0-9a-f]{64}"$' "$ROOT/agent-kit/install-kit.sh" \
  || fail "суммы uv не вшиты"
grep -qE 'astral\.sh/uv/install|\|[[:space:]]*(env[^|]*[[:space:]])?(ba)?sh([[:space:]]|$)' "$ROOT/agent-kit/install-kit.sh" \
  && fail "в комплекте снова скачанный скрипт отдаётся в shell"

# 4. uv that fails (network down mid-install) -> one line, the kit still succeeds.
printf '#!/bin/sh\necho "$*" >> "$UV_LOG"; exit 1\n' > "$T/fake/uv"; chmod +x "$T/fake/uv"
kit c "$T/fake:$T/sys" || { cat "$T/c.out"; fail "упавший uv уронил комплект"; }
grep -q "сканер навыков не поставился" "$T/c.out" || fail "упавший uv без строки: $(tail -3 "$T/c.out")"

# 5. KIT_NO_SKILLSPECTOR=1 -> not even attempted.
: > "$UV_LOG"
kit d "$T/fake:$T/sys" KIT_NO_SKILLSPECTOR=1 || fail "KIT_NO_SKILLSPECTOR=1: комплект упал"
[ ! -s "$UV_LOG" ] || fail "KIT_NO_SKILLSPECTOR=1 всё равно звал uv"
echo "✓ kit skillspector smoke ok (ставится один раз, без uv/сети комплект живой)"
