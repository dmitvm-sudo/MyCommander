# Test fixtures (T-21, F-12) — provenance

Deterministic containers generated once for golden tests
(`swift test` decodes nothing at runtime — bytes are committed).

| Файл | Как получен | Проверки |
|---|---|---|
| `golden-tar.xz` | python `tarfile` (USTAR, mtime 1700000000; dir `golddir`, `golddir/alpha.txt`, `beta.txt`) → `lzma.compress` | tar.xz-контейнер, ustar-заголовки, PAX-отсутствие; размеры/содержимое |
| `pax.tar` | python `tarfile` PAX_FORMAT, имя `pax` + 130×`x` + `.txt` (133) | PAX «x»-extended header («path»-record) |
| `gnu.tar` | python `tarfile` GNU_FORMAT, имя `gnu` + 130×`g` + `.txt` (133) | GNU «L» longname |
| `traversal.tar` | python `tarfile` USTAR: `../evil.txt`, `a/../b.txt`, `stay.txt` | F-12 path-traversal lock: escape-DROP, clamp, контроль |
| `cp866.zip` | собранный руками stored-ZIP (CRC32 + EOCD), имя `привет.txt` в CP866-байтах (`afe0a8a2a5e22e747874`), UTF-8 flag = 0 | CP866 fallback через ISO-866 `pathEncoding` (IANA «IBM866») |
| `single.xz` | python `lzma.compress(b"MyCommander golden xz payload\n")` | single .xz → разворачивание одного файла |
| `plain.txt` | литерал «definitely-not-an-archive» | refusal-ветка vfsUnsupported |

Пересоздание: `python3` + встроенный скрипт не хранится — файлы dirt-cheap
(мелки) и меняются предельно редко; правки версии SDD 06 §6.4 при смене
фикстур — обязательны.
