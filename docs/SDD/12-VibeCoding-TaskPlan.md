# 12. План задач для вайбкодинга (task-by-task)

## Правила выполнения задач (для AI-агентов — обязательно)

1. **Одна сессия = одна задача** из этого списка, в порядке следования внутри milestone.
2. Не расширять scope: критерии «Готово» — граница. Найденная смежная проблема → issue, не код.
3. Контракты — из `05-DataModel-VFS.md` / `06-Subsystems-Design.md`; их изменение = отдельная задача + правка SDD.
4. Тесты обязательны для каждой задачи (уровень по N-6 / `08`); CI зелёный до передачи следующей задачи.
5. Ошибки — только `MCError`; UI-строки — через Localizable; приваты — только Keychain.
6. В конце задачи: обновить `docs/SDD` если реализация что-то уточнила (формат: «Уточнение: …»).

---

## M0 — Скелет

### T-01. Bootstrap репозитория
- **Цель:** рабочая сборка в CI, лицензия, линт.
- **Файлы:** LICENSE, NOTICE.md, README.md, AGENTS.md, `.github/workflows/ci.yml`, lint-конфиги, Package.swift-граф из `11`.
- **Шаги:** создать монорепо; граф SPM (пустые модули с минимальными public-файлами); ci.yml: macOS runner, build+test+lint+license-check; AGENTS.md со ссылкой на SDD.
- **Готово:** CI зелёный на пустых модулях; README описывает сборку за 3 команды.
- **Уточнение (по ходу реализации T-01):** юнит-плейсхолдеры используют swift-testing (`import Testing`); запуск — `swift test --enable-swift-testing` (так же в ci.yml). Причина: на dev-машине без полного Xcode модуль XCTest недоступен (CLT без XCTest.swiftmodule), а установка CLT содержала дефект ManifestAPI (нет символов `Package.__allocating_init`), вылеченный локальным swift.org-тулчейном 6.3.2 в `~/Library/Developer/Toolchains`; это не меняет контрактов SDD — только выбор тест-фреймворка для unit-уровня и флаг в командах.

### T-02. DomainKit: модель и ошибки
- **Цель:** базовые типы и contracts (5.1–5.2, 5.8, 5.9).
- **Файлы:** DomainKit: VFSItem/VFSPath/MCError/SortCriteria/Masks + тесты.
- **Готово:** unit-тесты нормализации путей, сортировки, масок; типы Sendable.
- **Уточнение (по ходу реализации T-02):** (1) `ColumnID` — фиксированный enum; кейс custom(String) — это расширение v1.x (плагины, F-27), добавляется отдельной задачей, контракт §5.9 не менялся. (2) `ByteSizeFormat` без `ByteCountFormatter`: он не даёт ни pinned-локали, ни двойного стиля (1024/1000) — реализовано детерминированное форматирование `NumberFormatter`-ом (числовая часть locale-aware, юниты латиницей bytes/KB/kB/MB; локализованные юнит-слова — T-35, L10n). (3) Порядок тай-ов при сортировке тестами не фиксируется (устойчивость Swift `sorted` не гарантирована); `dirsFirst` применяется, если он выставлен хотя бы у одного критерия. (4) `SortCriteria/SortKey/SortOrder` сделаны `Codable` (нужно для персистентного `ViewPreset`); `VFSPath` в T-02 без `Codable` — добавит персистентность в своих задачах (сессии/журнал) с отдельной SDD-заметкой.

### T-03. DomainKit: протоколы и InMemoryVFS
- **Цель:** VFS-протоколы (5.3–5.5), TransferModels (5.6); fake-адаптер для тестов.
- **Файлы:** VFS.swift, VFSCapabilities.swift, ByteStream.swift, WatchEvents.swift, TransferModels.swift, (InMemoryVFS перенесён в T-04? нет — здесь базовый, errno-инжекция в T-11).
- **Готово:** компилируется с пустыми обработками; тест: простой «list→copy» сценарий через InMemoryVFS.
- **Уточнение (по ходу реализации T-03):** (1) Семантика `copyContents(from:to:target:)` уточнена как two-panel copy: `target` — каталог-приёмник на принимающем VFS, объект создаётся как `target/<from.name>`; занятый файл-приёмник → `MCError.transferConflict`, существующий каталог — merge. (2) Поля служебных типов, не заданных в SDD, зафиксированы реализацией: `ProgressSink` = `@Sendable`-замыкание от `ProgressUpdate` (completedItems/totalItems?/message), `Conflict.Kind` = targetExists/insideSelfMove/sourceVanished, `ConflictPolicy` = defaultResolution + perTargetPath(+ unwrap applyToAll), `Summary` = счётчики items + bytesTransferred + canceled, `OperationID` = UUID, `Reversal` = renameBack/restoreFromTrash/deleteCreated. (3) `VFSPath` стал `Codable` — востребовано `JournalRecord` (§5.6); пункт (4) «Уточнения T-02» этим закрыт. (4) `InMemoryVFS` — в VFSKit (по карте `11`), тесты там же; Package.swift: `VFSKit → DomainKit` (библиотека и тесты). Имена `createDirectory`/`rename` с пустым/`/`-содержащим name → `MCError.vfsUnsupported` (в духе POSIX EINVAL); InMemory `delete` удаляет каталог целиком (вкл. сам каталог).

## M1 — Core MVP

### T-04. LocalVFS (минимальный полный)
- **Цель:** реализация 5.3 для локального диска (без watch).
- **Файлы:** VFSKit/LocalVFS.swift, +Attributes.swift; InMemoryVFS errno-инжекция.
- **Готово:** integration-тесты list/stat/mkdir/rename/delete/copy на временных каталогах; Sendable-адаптер; атрибуты (xattr/тэги).

### T-05. Скелет UI: окно, две панели, будущий киоск
- **Цель:** видимое двухпанельное окно, листает каталоги.
- **Файлы:** App (MyCommanderApp, MainWindowController, PanelsCoordinator, MenuBuilder), ListViewKit (PanelViewModel, FileListView, ListItemCells, ItemCache, FocusController).
- **Шаги:** NSTableView cell-based; навигация Enter/⌘↑; активная панель.
- **Готово:** browse локальных дисков; скролл 50k строк без hitching (fixtures).

### T-06. FSEventsWatcher + дифф-обновление панели
- **Цель:** живые панели (F-1, watch).
- **Файлы:** VFSKit/FSEventsWatcher.swift, VolumeMonitor.swift; ListViewKit/DiffUpdate.swift.
- **Готово:** внешние изменения отражаются ≤ 1 с; дифф ≤ 100 мс на 100 changed; mount/unmount обрабатывается.

### T-07. Сортировка, quick filter, selections
- **Цель:** F-3, F-10, старт F-4 (full/brief).
- **Файлы:** EnginesKit/FilterEngine.swift; ListViewKit (selection-модель, режимы).
- **Готово:** критерии приёмки F-3/F-10; type-to-filter; Num-клавиши.

### T-08. Табы и сессии
- **Цель:** F-2 + restore-сессия.
- **Файлы:** ListViewKit/PanelTabsView.swift; ServicesKit/SessionStore.swift.
- **Готово:** критерии F-2; сессия восстанавливается после рестарта.

### T-09. CommandRouter + KeymapStore + меню
- **Цель:** F-7 каркас: все действия = CommandID, remap работает.
- **Файлы:** App/CommandRouter.swift; ServicesKit/KeymapStore.swift; Resources/keymap-*.json.
- **Готово:** карта `07` активна; конфликты при ремапе блокируются; сброс к профилю.

### T-10. Planner + Executor: copy same-volume
- **Цель:** ядро F-5 — планирование и исполнение копий с прогрессом.
- **Файлы:** FileOpsKit (TransferPlanner, OperationExecutor, CopyTransaction, TransferEvents); ListViewKit/ProgressWindow.swift (stub-UI).
- **Готово:** транспортные тесты same-volume (APFS clonefile-ветка + fcopyfile-ветка); пауза/отмена; прогресс-события.

### T-11. Cross-volume move/delete + resume
- **Цель:** F-5 полностью для локального.
- **Файлы:** MoveTransaction, DeleteTransaction; конфигурабельные воркеры.
- **Готово:** матрица томов из 8.3 (апфс/хфс+/exFAT образы); resume `.mc-partial`; troubles errno.

### T-12. Конфликт-диалог + summary
- **Цель:** UX F-5 (конфликты, apply-to-all, отчёт).
- **Файлы:** ListViewKit/ConflictDialog.swift; FileOpsKit/ConflictModels (связка).
- **Готово:** превью-таблица; policy per-item/all; summary ok/skip/fail.

### (Слот T-13: Journal/undo перенесён в T-20 внутри M2; нумерация сохранена для стабильности ссылок)
_(этот слот оставлен пустым намеренно: нумерация стабильнее, чем перемещение.)_

### T-13. Lister + Quick Look
- **Цель:** F-8, F-9.
- **Файлы:** ListViewKit/ListerWindow.swift; byte-stream чтение через VFS.
- **Готово:** критерии F-8/F-9 (4 GB текста — окно-стрим; QL для VFS через temp).

### T-14. Command bar (⌘L)
- **Цель:** F-17а.
- **Файлы:** ListViewKit/CommandBar.swift; TerminalKit/ShellSession (только exec-ветка).
- **Готово:** cd/mkdir/open/!с; плейсхолдеры %f %F %d %D %s; история.

### T-15. Info/properties + dirSize
- **Цель:** F-19.
- **Файлы:** ListViewKit/InfoDialog.swift; VFS directorySize (progress).
- **Готово:** карточка без блокировки UI; zh onNext cursor-idle подсчёт.

### T-16. Drag & Drop обе стороны
- **Цель:** F-18.
- **Файлы:** FileListView (NSPasteboard/DnD мост) + FileOpsKit-интеграция.
- **Готово:** Finder↔панель, panel↔panel; курсор-бейджи; drop в архив — extract.

### T-17. FDA onboarding + Safe Mode
- **Цель:** F-20.
- **Файлы:** App/Onboarding/*; status-индикатор в панели.
- **Готово:** критерии F-20 (grant / fail / hide); работает после отказа.

### T-18. Настройки (базовые) 
- **Цель:** F-21 MVP: шрифты, подтверждения, редактор, экспорт/импорт JSON.
- **Файлы:** ServicesKit/SettingsStore.swift; App/Dialogs/Settings.
- **Готово:** применение без рестарта; schemaVersion заложена.

### T-19. M1 hardening
- **Цель:** закрыть exit-критерии M1.
- **Шаги:** perf-бюджеты в CI (8.5); memory-профили; smoke 8.4 п.1–5, 8 вручную; багфикс.
- **Готово:** все пункты M1-exit зелёные.

## M2 — Архивы, SFTP, закладки

### T-20. Journal + undo (F-6)
- **Файлы:** FileOpsKit/JournalStorage.swift; ⌘Z-интеграция.
- **Готово:** критерии F-6; кольцевой буфер 20; частичные undo-диалоги.

### T-21. ArchiveVFS: чтение (zip/tar/gz/xz/bz2)
- **Файлы:** ArchiveVFS.swift, ZipReader/TarReader; реестр; открытие по Enter.
- **Готово:** критерии F-12 (read); path-traversal блок; тесты на golden-архив.

### T-22. Pack zip + extract-все
- **Файлы:** Archive/ZipWriter; диалог Pack; интеграция queue.
- **Готово:** упаковка выбранных → zip (уровень/опции); прогресс; перенос в очередь.

### T-23. SftpVFS: ядро
- **Файлы:** Sftp/SftpVFS.swift, SftpConnection.swift на Citadel; errno-маппинг.
- **Готово:** все 5.3-операции на живом SFTP-тест-сервере CI; resume offset; числа статов.

### T-24. ConnectionStore + Keychain + UI подключений
- **Файлы:** ServicesKit/ConnectionStore ↔ KeychainBridge; Connections-панель (SwiftUI).
- **Готово:** критерии F-13 (host-key pinning; fingerprint change → красный экран).

### T-25. SFTP robustness
- **Цель:** reconnect/backoff, отмена, таймауты.
- **Готово:** сценарий «перерубить сеть» восстанавливается; idle-KA; panel shows «Reconnect…».

### T-26. LocationsStore: закладки/история/hotlist
- **Цель:** F-11.
- **Готово:** критерии F-11 (⌘D; Alt-слоты; back/forward per tab).

### T-27. M2 hardening
- **Готово:** smoke 8.4 п.6–7; все VFS-операции через unified queue-путь; exit M2.

## M3 — Power tools

### T-28. RenamePlanner + диалог multi-rename (F-14)
### T-29. SyncReporter + dry-run UI (F-15)
### T-30. SearchEngine + результаты-виртуальная папка (F-16)
### T-31. TerminalPane встроенный (F-17): SwiftTerm, ⌃`, auto-cd, вставка путей
### T-32. Настройки полные + custom columns + thumbnails (F-21, F-4)
### T-33. Темы (F-23 частично): light/dark/NC-blue, шрифты
_(каждая задача: файлы из соответствующих модулей по карте `11`, критерии приёмки — из карточек фич `02`; тесты — unit + integration; пункт «Готово» = все acceptance критерии фичи.)_

### T-34. M3 hardening: smoke 8.4 п.8–9; перф-регрессии; ADR-догма обновлений.

## v1.0
### T-35. Локализация EN/RU (F-22, String Catalogs, lint-правило)
### T-36. Темы довести до релиза (F-23), полиш диалогов/badges
### T-37. Релиз-инженерия: Sparkle, DMG+notarization, GitHub Releases, README/help, NOTICE-проверка, beta-канал
### T-38. Бета-цикл: сбор фидбек, краш-фиксы, замер crash-free ≥ 99.5 %

## v1.x (бэклог — спецификации пишутся при входе)
- T-40 Git column provider (F-24, dogfood F-27)
- T-41 SMB (F-25, AMSMB2)
- T-42 S3 (F-26) · T-43 Plugin contract + SDK (F-27) · T-44 FTP (F-28) · T-45 Дубликаты (F-29) · T-46 Split/combine/checksums (F-30)
