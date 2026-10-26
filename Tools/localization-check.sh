#!/usr/bin/env bash
# Гейт локализации (docs/SDD, F-22; уточнение T-35 в 08 §8.1):
#  1) мастер-каталог App/Resources/{en,ru}.lproj/Localizable.strings —
#     набор ключей равен, значения непусты;
#  2) каждый ключ String(localized: "…") есть в каталоге; обратное — без
#     огрызков (orphan-ключей нет);
#  3) каталог-формат-ключи (%@ / %lld / %ld) — префикс чьей-то интерполяции
#     «ключ + пробел»;
#  4) UI-литералы (title/messageText/informativeText/placeholder/stringValue/
#     labelWithString/NSAttributedString и др. — 15 паттернов) содержат
#     БУКВЫ → FAIL; допускаются литералы без букв (числа, «[N]», «⌃», пустые)
#     либо inline-маркер // l10n-allow в конце строки.
# Работает на python3; Tests и .build не сканируются.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'localization-check: FAIL — %s\n' "$1" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "python3 не найден"
python3 - <<'PY'
import glob, os, re, sys

def fail(msg):
    print("localization-check: FAIL —", msg)
    sys.exit(1)

def catalog(path):
    text = re.sub(r'/\*.*?\*/', "", open(path, encoding="utf-8").read(), flags=re.S)
    entries = {}
    for line in text.split("\n"):
        s = line.strip()
        if not s:
            continue
        m = re.match(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";$', s)
        if not m:
            fail(f"{path}: cannot parse line: {s!r}")
        entries[m.group(1)] = m.group(2)
    return entries

en_path = "App/Resources/en.lproj/Localizable.strings"
ru_path = "App/Resources/ru.lproj/Localizable.strings"
en, ru = catalog(en_path), catalog(ru_path)
if set(en) != set(ru):
    fail("key parity broken: " + ", ".join(sorted(set(en) ^ set(ru))))
empty = [k for k, v in list(en.items()) + list(ru.items()) if not v.strip()]
if empty:
    fail("empty values: " + ", ".join(sorted(set(empty))))

plain, interp = set(), set()
NEEDLE = 'String(localized: "'
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
KEY_SHAPE = re.compile(r'^[a-z][a-zA-Z0-9]*(\.[a-zA-Z0-9_]+)+$')

sources = sorted(glob.glob("Packages/*/Sources/**/*.swift", recursive=True)
                 + glob.glob("App/**/*.swift", recursive=True))
sources = [p for p in sources if "/Tests/" not in p and "/.build/" not in p]

UI_PATTERNS = [
    ("addButton", r'addButton\(withTitle:'),
    ("title-arg", r'(?<!\w)title:'),
    ("labelWithString", r'labelWithString:'),
    ("string-arg", r'(?<!\w)string:'),
    ("stringValue", r'\.stringValue\s*=\s*'),
    ("placeholder=", r'placeholderString\s*=\s*'),
    ("placeholder-arg", r'placeholderString:'),
    ("messageText=", r'messageText\s*=\s*'),
    ("messageText-arg", r'messageText:'),
    ("informativeText", r'informativeText\s*=\s*'),
    ("toolTip=", r'toolTip\s*=\s*'),
    ("title-assign", r'\.title\s*=\s*'),
    ("menu-title", r'menuSubstitution\w*:'),
    ("nsattr-string", r'NSAttributedString\(string:'),
    ("alertButton", r'NSSegmentItem\(title:|buttonWithTitle:'),
]
hard_hits = []
for path in sources:
    src = open(path, encoding="utf-8").read()
    bats = src.split("\n")
    # КОСВЕННЫЕ ключи: контракты локализации по строкам —
    #  (a) titleKey-спеки MenuBuilder, (b) LocalizationValue-сайты колонок,
    #  (c) кортежи (CommandID…, «ключ») секций, (d) тернарники
    #  String(localized: <переменная> (±2 след. строки = сами литералы).
    INDIRECT = re.compile(r'titleKey|LocalizationValue\(|\((CommandID|ColumnID)\.|String\(localized:\s*[^"\s]')
    for n, line in enumerate(bats):
        if INDIRECT.search(line):
            for d in (0, 1, 2):
                if n + d < len(bats):
                    for m in LITERAL.finditer(bats[n + d]):
                        if KEY_SHAPE.match(m.group(1)):
                            plain.add(m.group(1))
    # Прямые ключи: паттерн-станок тот же, что в тесте.
    pos = 0
    while True:
        at = src.find(NEEDLE, pos)
        if at == -1:
            break
        pos = at + len(NEEDLE)
        buf = []
        interp_hit = False
        i = pos
        while i < len(src):
            ch = src[i]
            if ch == "\\":
                nxt = src[i + 1] if i + 1 < len(src) else ""
                i += 2
                if nxt == "(":
                    interp_hit = True
                    depth, j = 1, i
                    while depth and j < len(src):
                        c = src[j]
                        if c == "(":
                            depth += 1
                        elif c == ")":
                            depth -= 1
                            if depth == 0:
                                break
                        j += 1
                    i = j + 1
                else:
                    buf.append({"n": "\n", "t": "\t"}.get(nxt, nxt))
                continue
            if ch == '"':
                i += 1
                break
            buf.append(ch)
            i += 1
        literal = "".join(buf)
        if interp_hit:
            interp.add(re.sub(r'[\s)]+$', "", literal))
        else:
            plain.add(literal)
    # Хардкод-литералы UI: буква в литерале → fail.
    for ident, pat in UI_PATTERNS:
        for m in re.finditer(pat + r'\s*"([^"\\\n]*)"', src):
            line_no = src[:m.start()].count("\n") + 1
            line = bats[line_no - 1]
            if "String(localized" in line or "String(format:" in line or "// l10n-allow" in line:
                continue
            literal = m.group(1)
            if any(c.isalpha() for c in literal):
                hard_hits.append(f"{path}:{line_no} [{ident}] {literal!r}")

missing = [k for k in plain if k not in en]
if missing:
    fail("keys in sources, not in catalog: " + ", ".join(sorted(missing)[:14]))
format_keys = {k for k in en if "%" in k}
orphan = {k for k in en if k not in plain} - format_keys
if orphan:
    fail("catalog keys not used in sources: " + ", ".join(sorted(orphan)[:14]))
for fk in sorted(format_keys):
    prefix = fk.split("%", 1)[0].strip()
    if not any(p.strip() == prefix for p in interp):
        fail("format key without interpolation site: " + fk)
if hard_hits:
    fail("UI literals with letters (localize these):\n  " + "\n  ".join(hard_hits[:20]))

print(f"localization-check: OK ({len(en)} keys, {len(hard_hits)} hardcoded)")
PY
