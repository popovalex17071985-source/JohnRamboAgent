#!/usr/bin/env bash
# Помечает влитый main следующим тегом vX.Y.Z (аннотированным), чтобы у каждого
# слияния была версия и `dashi-ctl-<имя> rollback --to vX.Y.Z` было куда целиться.
# Тег создаётся ТОЛЬКО локально — отправка отдельной командой, её скрипт печатает.
#
#   scripts/tag-release.sh [patch|minor|major|X.Y.Z] [--ref <ref>] [--dry-run]
#
# Без версии: если в .claude-plugin/plugin.json на этом коммите версия новее
# последнего тега — тег ровно этой версией (релиз по docs/RELEASING.md), иначе
# patch от последнего тега. Коммит уже помечен vX.Y.Z — ничего не делает.
# --ref по умолчанию fork/main, если такой есть, иначе origin/main.
set -euo pipefail

die() { echo "tag-release: $*" >&2; exit 1; }
SEMVER='^[0-9]+\.[0-9]+\.[0-9]+$'

bump="" ref="" dry=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)     [[ $# -ge 2 ]] || die "--ref без значения"; ref="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    patch|minor|major) bump="$1"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) [[ "$1" =~ $SEMVER ]] || die "непонятный аргумент: $1"; bump="$1"; shift ;;
  esac
done

if [[ -z "$ref" ]]; then
  if git rev-parse -q --verify fork/main >/dev/null; then ref=fork/main; else ref=origin/main; fi
fi
sha="$(git rev-parse -q --verify "$ref^{commit}")" || die "нет такого коммита: $ref"

# Уже помечен — повторный прогон ничего не плодит
have="$(git tag --points-at "$sha" -l 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
if [[ -n "$have" ]]; then echo "уже помечено: $have на ${sha:0:7}"; exit 0; fi

latest="$(git tag -l 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' | sort -V | tail -1 || true)"
latest="${latest:-0.0.0}"
newer() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]; }
IFS=. read -r ma mi pa <<<"$latest"

case "$bump" in
  major) next="$((ma + 1)).0.0" ;;
  minor) next="$ma.$((mi + 1)).0" ;;
  patch) next="$ma.$mi.$((pa + 1))" ;;
  "")    pkg="$(git show "$sha:.claude-plugin/plugin.json" 2>/dev/null \
              | sed -n 's/^ *"version": *"\([0-9.]*\)".*/\1/p' | head -1 || true)"
         if [[ "$pkg" =~ $SEMVER ]] && newer "$pkg" "$latest"; then next="$pkg"
         else next="$ma.$mi.$((pa + 1))"; fi ;;
  *)     next="$bump" ;;
esac
newer "$next" "$latest" || die "v$next не новее последнего тега v$latest"
git rev-parse -q --verify "refs/tags/v$next" >/dev/null && die "тег v$next уже есть"

subject="$(git log -1 --format=%s "$sha")"
remote="${ref%%/*}"; [[ "$remote" != "$ref" ]] || remote=origin
if [[ $dry == 1 ]]; then
  echo "поставил бы v$next на ${sha:0:7} $subject (последний тег v$latest)"
  exit 0
fi
git tag -a "v$next" -m "v$next — $subject" "$sha"
echo "создал v$next на ${sha:0:7} $subject (до этого v$latest)"
echo "отправить: git push $remote v$next"
