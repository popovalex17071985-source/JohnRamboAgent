#!/usr/bin/env bash
# Смоук: scripts/tag-release.sh — следующий vX.Y.Z (аннотированный тег) на влитый
# main, чтобы `dashi-ctl rollback --to <тег>` было куда целиться. Сам не пушит.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="$ROOT/scripts/tag-release.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "✗ $*" >&2; exit 1; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
[[ -x "$TAG" ]] || fail "нет scripts/tag-release.sh"

R="$T/repo"; mkdir -p "$R/.claude-plugin"
git -C "$R" init -q -b main
ver() { printf '{\n  "name": "x",\n  "version": "%s"\n}\n' "$1" > "$R/.claude-plugin/plugin.json"; }
commit() { echo "$1" >> "$R/log.txt"; git -C "$R" add -A; git -C "$R" commit -q -m "$1"; }
tag() { (cd "$R" && "$TAG" "$@") > "$T/out" 2>&1; }

ver 1.2.0; commit "Релиз 1.2.0"; git -C "$R" tag -a v1.2.0 -m v1.2.0
ver 1.3.0; commit "Релиз 1.3.0 без тега"

# 1. plugin.json впереди последнего тега — тег ровно его версией
tag --ref main || fail "релиз: $(cat "$T/out")"
[[ "$(git -C "$R" rev-parse 'v1.3.0^{commit}')" == "$(git -C "$R" rev-parse main)" ]] || fail "нет v1.3.0 на main"
[[ "$(git -C "$R" cat-file -t v1.3.0)" == tag ]] || fail "тег не аннотированный"
grep -q "git push .* v1.3.0" "$T/out" || fail "нет подсказки, как отправить тег: $(cat "$T/out")"
echo "✓ версия из plugin.json"

# 2. Тот же коммит второй раз — ничего не делает
tag --ref main || fail "повтор упал"
grep -q "уже" "$T/out" || fail "повтор: $(cat "$T/out")"
[[ "$(git -C "$R" tag -l 'v*' | wc -l)" == 2 ]] || fail "повтор наплодил тегов"
echo "✓ повтор — без нового тега"

# 3. Слияние без смены версии — patch
commit "Фикс"; tag --ref main || fail "patch: $(cat "$T/out")"
git -C "$R" rev-parse -q --verify v1.3.1 >/dev/null || fail "ждали v1.3.1: $(cat "$T/out")"
echo "✓ без смены версии — patch"

# 4. minor / явная версия / dry-run / версия не больше последней
commit "Фича"; tag --ref main --dry-run || fail "dry-run"
grep -q "v1.3.2" "$T/out" || fail "dry-run не назвал v1.3.2"
! git -C "$R" rev-parse -q --verify v1.3.2 >/dev/null || fail "dry-run создал тег"
tag minor --ref main || fail "minor: $(cat "$T/out")"
git -C "$R" rev-parse -q --verify v1.4.0 >/dev/null || fail "ждали v1.4.0"
commit "Ещё"; tag 1.2.5 --ref main && fail "версия ниже последней принята"
tag 2.0.0 --ref main || fail "явная версия: $(cat "$T/out")"
git -C "$R" rev-parse -q --verify v2.0.0 >/dev/null || fail "ждали v2.0.0"
commit "Ещё раз"; tag junk --ref main && fail "мусор принят"
tag --ref nope && fail "несуществующий ref принят"
echo "✓ minor, явная версия, dry-run, отказы"

echo "✓ tag-release smoke ok"
