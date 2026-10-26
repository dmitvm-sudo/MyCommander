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

*Уточнение T-35 (F-22, L10n-интегрити):* единственный мастер-каталог
`App/Resources/{en,ru}.lproj/Localizable.strings` (CLI-SwiftPM НЕ компилирует
.xcstrings — пробанка T-35: файл копируется в бандл как есть и не резолвится,
поэтому форма — классические .strings в lproj-папках; `defaultLocalization: "en"`
на пакете; пакеты резолвят через Bundle.main = app-bundle, код НЕ трогаем).
Тест `LocalizationStringsTests` (ListViewKitTests, name-space `loc`): (a) en/ru
разбираются `NSDictionary(contentsOfFile:)`, ключи-наборы равны, значения
непустые; (b) каждый source-ключ `String(localized: "…")` (скан
Packages/*/Sources + App, однострочный мини-парсер) есть в каталоге; (c) каждый
каталог-формат-ключ (`… %@`, `… %lld`) обязан быть префиксом чьей-то
интерполированной исходной строки «ключ + пробел» — сверка в обе стороны.
Lint-гейт `Tools/localization-check.sh`: UI-литералы (title/messageText/
placeholder/stringValue/label-инициалы и др. — 15 паттернов) НЕ содержат букв
(иначе fail, inline-исключение `// l10n-allow`); плюс сверки ключей ↔ .strings.
CI-рега: прогон скрипта в отдельном шаге ci.yml до merge.

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

*Уточнение T-27 (автоматизируемое ядро п.6–7):* п.6 — zip round-trip с RU/emoji
именами через панельный путь = `UnifiedQueueIntegrationTests
.zipRoundTripThroughUnifiedPathSurvivesUnicodeNames` (VFSKitTests: pack →
ArchiveVFS-mount → extract через planner+executor). Панель-UI-часть (диалоги Pack)
остаётся ручной. п.7 — browse/copy/copy-назад SFTP = `localToSftpCopy…` /
`sftpCopyPreservesUnicodeNames` (планнер+executor, live in-process сервер, 06 §6.5);
reconnect после разрыва сети = `SftpRobustnessTests.liveCablePull…` (T-25) — честная
симуляция обрыва через TCP-прокси. Ручной остаток п.7: реальный внешний сервер +
«потушить Wi-Fi» (нельзя автоматизировать честно в CI).

*Уточнение T-34 (автоматизируемое ядро п.8–9):* п.8 — quick filter = `FilterEngineTests`
+ `PanelViewModelFilterSelectionTests`; quick search = `SearchEngineTests` (VFSFlatScan)
+ `SearchResultVFSTests`; multi-rename = `RenamePlannerTests` (планнер, T-28) +
`MultiRenameDialogTests` (T-34: preview 100 имён; чужие конфликты → Apply disabled
и красные строки «new»-колонки; dry-run apply → `.move`-план без записи на диск) +
`multiRenameThroughUnifiedQueue` (commit через единый queue). Ручной остаток п.8 — глазная
Москва-проверка панелей. п.9 — cd-след = `TerminalPathSeederTests` (T-31); ручной остаток:
vim/tmux в терминале и подтверждение при закрытии окна с активной задачей (прецедент
T-27/T-31: нельзя честно автоматизировать).

## 8.5 Performance-бюджеты в CI (fail build при регрессе)

| Метрика | Бюджет | Фиксчура |
|---|---|---|
| catalog open (list+diff) | ≤ 300 мс P95 | 10k файлов |
| quick filter pass | ≤ 50 мс | 50k имён |
| дифф панель-обновление | ≤ 100 мс | 100 changed |
| queue: copy throughput | ≥ 90 % `cp -R` | 2 GB, same image |
| lister open | ≤ 200 мс до первого листания | 4 GB sparse |
| launch to first panel | ≤ 1.5 с | временный профайл |

*Уточнение T-19 (CI-гейт v1):* в CI отдельная job прогоняет весь suite в Release (fail-on-regression, N-1); Debug-прогон уже несёт budget-ассерты. Автоматизировано (где живёт): catalog open 10k — LocalVFS leg (VFSKit, in-test ≤ 1.2 с = CI-запас ×4 от честного 300 мс регистра; дифф-leg покрыт T-06 `DiffUpdateTests`); quick filter 50k ≤ 50 мс (F-10, T-07); дифф 100 changed на 50k ≤ 100 мс (T-06); scroll-sweep 5k×3 кол + структура (T-05); lister open 4 GB sparse + первое окно 8 MB (FileOpsKit, in-test ≤ 1.0 с = CI-запас ×5 от 200 мс). Memory-профили N-2: footprint panel-данных 100k строк ≤ +100 MB (ListViewKit) и Lister-окна по 4 GB sparse → delta ≤ 64 MB (стрим без буферизации, FileOpsKit). Не автоматизируем в CI: copy throughput 2 GB ≥ 90 % `cp -R` и launch to first panel ≤ 1.5 с — фиксчуры рантайм-тяжёлые/аппаратно-зависимые, их регистр = smoke 8.4 п.1/3 вручную.

*Уточнение T-34 (ретрай-цикл перф-гейтов при внешней нагрузке):* бюджетные тесты
T-05/T-06/T-07 ассертят одиночную пробу из таблицы §8.5 и флейкят, когда машина под ВНЕШНЕЙ
нагрузкой (load average ≥ 6 от посторонних процессов: WebContent/BTLEServer/Safari —
замечено в T-06/T-07, гейт T-33 закрыт третьей попыткой). Политика локального гейта: если
в `swift test` упали ТОЛЬКО перф-ассерты, прогон считается флейком → ретрай-цикл целых
прогонов (до 5 попыток, пауза 75–90 с); зелёный прогон гейт закрывает, число попыток
фиксируется в уроке задачи. Функциональные падения никогда не ретраятся. CI Release-job
(T-19) не ретраит — ранер не несёт посторонней нагрузки.

*Уточнение T-36 (истина гейта — счётчик, а не exit-код):* наблюдение T-36 —
полный параллельный Debug-прогон напечатал «failed after» (перф-флейки) при
exit=0: `swift test` под параллельным раннером этого тулчейна может вернуть
0 даже при падениях (квирк). Истина гейта = счётчик «failed after» /
«recorded an issue» в полном прогоне (= 0); exit-код — вторичен (T-34-легенда
«exit-код = истина» уточнена). Изолированный ретрай упавших тестов зелёным
прогоном закрывает перф-флейк без повторного полного прогона.
