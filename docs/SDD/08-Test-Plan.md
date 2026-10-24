# 08. Тест-план

## 8.1 Уровни тестов

| Уровень | Что покрывает | Где живёт |
|---|---|---|
| Unit | DomainKit-модель, planner/executor-логика, engines, stores-миграции | `Tests/<Module>Tests/` |
| Integration | VFS-адаптеры на реальных фиксчурах (временные каталоги, образы, SFTP-сервер), queue end-to-end | `Tests/IntegrationTests/` |
| Performance | Бюджеты N-1…N-3 на фиксчурах | XCTest measure + CI-скрипт |
| Manual smoke | Полный пользовательский сценарий (чек-лист ниже) | перед release, руками |

Примечание к фреймворку: unit-тесты пишутся на swift-testing (`import Testing`); запуск — `swift test --enable-swift-testing` (флаг также в ci.yml). XCTest остаётся инструментом perf-suite на CI-раннерах с полным Xcode (см. раздел 8.5).

## 8.2 Фиксчуры

- `Tools/fixture-generator`: генерирует деревья (depth/широта/имена с юникодом, эмодзи, пробелами, очень длинными путями); каталоги 1k/10k/50k/100k файлов; «глубокое» дерево 8 уровней.
- Дисковые образы: `hdiutil` в CI создаёт образы **APFS / HFS+ / exFAT** для кросс-томных сценариев (mount/unmount в скрипте).
- Архивы-фиксчуры: zip (deflate/store/zip64/encrypted), tar, tar.gz, tar.xz, tar.bz2, 7z (v1.0) — золотые файлы в `Tests/Fixtures/Archives/`.
- SFTP: в CI поднимается локальный sshd (macOS runner: сгенерировать host/user keys → `sshd -f tmp/config` на 127.0.0.1:22x) — те же тесты, что и для Local, работающие через `SftpVFS`.
- In-memory фейки: `InMemoryVFS` — детерминированные сбои (errno-инжекция) для тестов ошибок очереди.

## 8.3 Ключевые unit-кейсы

**DomainKit:**
- `VFSPath` нормализация: `..`, дубли «/», unicode NFC/NFD round-trip; лимит длины.
- Сортировка: locale-aware (name), dirs-first, стабильность при равных ключах.

**FileOpsKit (самое важное), матрица:**
- copy: same-volume APFS (clonefile — проверить, что ctime/размер и inode разные), same-volume HFS+ (fcopyfile), cross-volume (data равна byte-wise для текстовых/бинарных/нулевых/разреженных файлов), папки с nestling деревом, конфликт-политики (overwrite/skip/keep-both/apply-to-all), unique-name suffix (name(1).ext).
- move: rename(2) vs copy+delete; перенос каталога в свою подпапку — отказ с сообщением.
- delete: пустые/непустые деревья, readonly-файлы, toTrash и восстановление записи.
- пауза/отмена/resume: cancel на 99 % копии не оставляет целевого файла; resume продолжает с offset.
- отказы: EACCES/ENOSPC/EIO-инжекция → корректные события, частичные результаты, summary.

**ArchiveVFS:** round-trip zip; чтение всех форматов фиксчур (имена/размеры/даты совпадают); zip64 (>4 GB через sparse), encrypted-zip (пароль-диалог); извлечение пути с `../` в архиве — security-проверка (path traversal block).

**EnginesKit:** FilterEngine (подстрока/fuzzy/пгебъеф-prefix, ties); RenamePlanner (маски-счислители, conflicts, dry-run); SyncReporter (disjoint/identical/diff/mirror-delete; hash-cache инвалмидация по mtime+размеру); SearchEngine (mask, size/date фильтры, content-hit).

**ServicesKit:** миграции settings schemaVersion n−1→n; keymap конфликт-detect; Keychain round-trip (интеграционно, macOS runner); log-scrubber (пути маскируются).

## 8.4 Ручной smoke-чеклист (каждый milestone exit)

1. Установить DMG, первый запуск: onboarding FDA (granted) — панели открываются < 1.5 с.
2. Пролистать каталог 100k файлов — скролл плавный, память в бюджете.
3. F5 копия 10k файлов с конфликтами (5 конфликтов, apply-to-all) → summary корректен; пауза/отмена на середине.
4. Отключить FDA → Safe Mode: работа в Desktop/Documents/Downloads, банер виден.
5. F3 просмотр 4 GB текста — мгновенно, память константна; Esc закрывает.
6. Открыть zip из панели → копия внутрь → извлечение → круглый цикл без потери имён (RU/emoji).
7. SFTP к тестовому серверу: browse/copy/copy-назад/reconnect после разрыва сети (потушить Wi-Fi).
8. Quick filter / quick search на Москве-наборе; multi-rename 100 файлов с конфликтами.
9. Terminal ⌃\`: cd-след patrimonio, vim/tmux работают, закрытие с задачами — подтверждение.
10. Обновление через Sparkle: старая версия → новая без слома settings (миграции).

## 8.5 Performance-бюджеты в CI (fail build при регрессе)

| Метрика | Бюджет | Фиксчура |
|---|---|---|
| catalog open (list+diff) | ≤ 300 мс P95 | 10k файлов |
| quick filter pass | ≤ 50 мс | 50k имён |
| дифф панель-обновление | ≤ 100 мс | 100 changed |
| queue: copy throughput | ≥ 90 % `cp -R` | 2 GB, same image |
| lister open | ≤ 200 мс до первого листания | 4 GB sparse |
| launch to first panel | ≤ 1.5 с | временный профайл |
