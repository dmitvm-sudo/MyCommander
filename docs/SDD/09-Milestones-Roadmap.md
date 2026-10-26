# 09. Milestones и Roadmap

Реализация идёт строго по milestone. Каждый имеет жёсткий scope и exit-критерии. Фичи ссылаются на ID из `02`.

## M0 — Скелет (1 неделя)
**Scope:** репо, лицензия GPL-3.0 + NOTICE, CI (build/test/lint), SPM-граф `11`, пустое окно с двумя заглушками панелей и меню.
**Exit:** сборка зелёная в CI на macOS runner; окно запускается; README с инструкцией сборки; лицензия корректна.

## M1 — Core MVP: локальные панели и операции
**Scope:** F-1, F-2, F-3, F-4 (brief/full), F-5, F-7, F-8 (text/hex), F-9, F-10, F-17а, F-18, F-19, F-20, F-21 (базовые), F-6 — нет (это M2); полнофункционально только для локального диска.
**Exit-критерии:**
1. Ежедневно пригодно для работы с локальными файлами (smoke 8.4 п.1–5, 8).
2. Performance-бюджеты N-1…N-3 зелёные в CI.
3. Poison-test: FDA отозвано → Safe Mode полноценен; включено → полный доступ.
4. Zero known crashes в core-flow за 2 дня самостоятельного использования владельцем.

## M2 — Источники: архивы, SFTP, закладки + undo
**Scope:** F-6, F-11, F-12 (zip read/write; tar/gz/xz/bzip2 read), F-13 (SFTP + Connection Manager); capability-инварианты VFS на панелях (без watch-фич для сетевых).
**Exit:**
1. Smoke 8.4 п.6–7; все VFS-операции идут через один и тот же queue/conflicts-путь.
   *Уточнение T-27 (трактовка критерия):* «все VFS-операции» = **transfer-класс
   мутаций** — copy / move / delete / packZip / extract (копирование из
   archive-интерлюдии) / undo-reversals — все идут через ЕДИНЫЙ `OperationExecutor`
   (queue + conflicts + journal, один экземпляр на приложение). `mkdir` —
   задокументированное исключение по контракту §5.6 (T-20: mkdir реверсируется
   напрямую через JournalRecord без transfer engine); rename в v1 отсутствует
   (F6 = move). Доказательство — интеграционная сюита `UnifiedQueueIntegrationTests`
   (один executor прогоняет copy→move→delete→packZip, journal содержит все op-ы;
   cross-VFS Local↔SFTP через planCopy+executor; zip round-trip RU/emoji через
   pack→ArchiveVFS→extract тем же путём). Smoke 8.4 п.6–7: автоматизируемое ядро —
   эти тесты (08 §8.4 уточнение T-27); ручная часть (UI-прогон, «потушить Wi-Fi»
   на живом сервере) — владелец при выпуске M2-сборки.
2. SFTP: reconnect/backoff устойчив (ручной сценарий «перерубить сеть»); ключи хостов с pinning.
3. Архивы: round-trip тесты зелёные; path-traversal заблокирован.
4. Undo F-6 работает для rename/mkdir/move/trash.

## M3 — Power tools
**Scope:** F-14 (multi-rename), F-15 (compare/sync), F-16 (полнотекстовый поиск + виртуальная папка), F-17 (встроенный terminal), F-21 (полные настройки), F-4 (custom columns + thumbnails — частично может быть ранее).
**Exit:**
1. Smoke 8.4 п.8–9; инструменты не деградируют панель-перфоманс.
2. Dry-run по умолчанию для sync; undo для rename через F-6.
3. Terminal: vim/tmux работают корректно (на эмуляторе SwiftTerm), авто-cd работает.

## v1.0 — Release
**Scope:** F-22 (EN/RU), F-23 (темы: light/dark/NC-blue), полировка UX (диалоги, badge-иконки), документация (README/help), инфраструктура релиза: Sparkle, notarized DMG, GitHub Releases, beta-канал.
**Exit:**
1. 2 недели беты: crash-free ≥ 99.5 %, ноль блокеров.
2. Бюджеты производительности зелёные; память ок.
3. Лицензионный эффект: NOTICE полный, SPDX в файлах, CI license-check зелёный.
4. Дистрибуция: подпись+notarization проверены на чистой машине.

## v1.x — Расширения (бэклог, порядок по опросу аудитории)
| Фича | Приоритет-кандидат |
|---|---|
| F-24 Git-badges (custom column provider) | высокая (дифференциатор, dogfood плагин-контракта F-27) |
| F-25 SMB (AMSMB2) | высокая (частый запрос) |
| F-26 S3 / облака (aws-sdk-swift) | средняя |
| F-27 Плагин-контракт + SDK docs | высокая |
| F-28 FTP | низкая (SFTP покрывает; lib-проблема research/02) |
| F-29 Поиск дубликатов | средняя |
| F-30 Split/combine/checksums (md5/sha) | средняя |
| 7z write (через vendored 7z SDK или libarchive) | средняя |

## Маршрут найма (для вайбкодинга)
Каждая задача `12-VibeCoding-TaskPlan.md` привязана к milestone. Не переходить к следующей milestone без закрытия exit-критериев предыдущей.
