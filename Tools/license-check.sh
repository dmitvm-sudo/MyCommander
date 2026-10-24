#!/usr/bin/env bash
# Гейт лицензий (docs/SDD, N-10):
#  1) LICENSE и NOTICE.md обязательны;
#  2) каждая remote-зависимость Package.resolved должна значиться в NOTICE.md;
#  3) разрешены только пермиссивные лицензии (MIT / Apache-2.0 / BSD) — проверка
#     лицензии отдельного пакета выполняется человеком при добавлении (NOTICE.md, шаг 1).
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'license-check: FAIL — %s\n' "$1" >&2; exit 1; }

[ -f LICENSE ] || fail "LICENSE отсутствует"
[ -f NOTICE.md ] || fail "NOTICE.md отсутствует"

if [ -f Package.resolved ]; then
  # Package.resolved v2: «repositoryURL», v3: «location» — берём оба.
  deps=$(grep -E -o '"(repositoryURL|location)"[[:space:]]*:[[:space:]]*"[^"]+"' Package.resolved \
    | sed -E 's/.*"([^"]+)"$/\1/' || true)
  if [ -n "$deps" ]; then
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      name="$(basename "$url" .git)"
      grep -q -e "$name" NOTICE.md || fail "зависимость $url не описана в NOTICE.md"
      printf '  ok: %s\n' "$name"
    done <<< "$deps"
  fi
fi

echo "license-check: OK"
