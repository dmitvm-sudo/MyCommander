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
- **Уточнение (по ходу реализации T-04):** (1) Default `copyContents` вынесен в protocol extension `VFS` (DomainKit) — один two-panel алгоритм (источник ходит своим деревом, байты через `openRead`/`openWrite`+`finish`); InMemoryVFS дубль убран; серверные адаптеры (archive/SFTP) смогут переопределить. (2) LocalVFS — staged-писание: temp `.<name>.mc-partial` рядом с целью → fsync (`synchronizeFile`) → rename (06 §6.2); занятый `.mc-partial` обрезки прошлой сессии считается нашим и переиспользуется; replace-коммит через `replaceItemAt`; conflict на `finish` у занятой цели = `transferConflict` (temp подчищается, слот writer освобождается). (3) InMemoryVFS errno-инъекция — публичный API `injectFailure(_ error: MCError?, for operations: Set<VFSOperation>? = nil)`: `error == nil` — очистка, `operations == nil` — все 10 кейсов enum `VFSOperation`; проверки в головах публичных методов (употребится матрицей T-11). (4) Тэги — кодек plist-массива в xattr `com.apple.metadata:_kMDItemUserTags` (записи «имя+CR», чтение strip); FinderInfo (`com.apple.FinderInfo`) → base64-строка в `urlResourceMeta` + `writeFinderInfo` (хелперы в `LocalVFS+Attributes.swift`, Darwin getxattr/setxattr). (5) `posixPermissions` не экспонируется `URLResourceValues` — чтение через `attributesOfItem(atPath:)` (второй stat на item; при 50k — кандидат на оптимизацию, deferred). (6) `canWatch = false` до T-06; `LocalVFS(at:instanceID:)` — override идентичности для тестов (иначе два temp-каталога одного тома делят volume-UUID `specID`). (7) mtime, установленный через `setAttributes`, несёт микросекундную гранулярность utimes — тесты сравнивают даты с допуском; наносекундная сохранность (setattrlist) не нужна v1.

### T-05. Скелет UI: окно, две панели, будущий киоск
- **Цель:** видимое двухпанельное окно, листает каталоги.
- **Файлы:** App (MyCommanderApp, MainWindowController, PanelsCoordinator, MenuBuilder), ListViewKit (PanelViewModel, FileListView, ListItemCells, ItemCache, FocusController).
- **Шаги:** NSTableView cell-based; навигация Enter/⌘↑; активная панель.
- **Готово:** browse локальных дисков; скролл 50k строк без hitching (fixtures).
- **Уточнение (по ходу реализации T-05):** (1) T-05 = инфраструктура панели без `PanelViewController` (он появится с табами, T-08): статус-строка (путь · «n of m selected» · последняя ошибка) живёт внутри `FileListView`; табы/коммандная строка — позже. (2) Focus-модель уже в `FocusController` (`PanelSide` left/right, `activate`/`toggle`); координатор (App) слушает `onFocusChanged` → first-responder на таблицу активной панели; клик/клавиши в панели → `onActivated` → активация. (3) Навигация: Enter (и NumPad Enter) — open под курсором (директория; файл — no-op; symlink открывается на target того же инстанса), ⌘↑ — на уровень вверх, двойной клик — open; AppKit-стрелки работают как есть. (4) `PanelViewModel` держит 06 §6.1-поля (`path`/`rawItems`/`visibleIndices`/`selection`/`cursor`); selection хранит `VFSPath`-идентичности и переживает пересорт; setItems сбрасывает cursor/selection; selection/cursor НЕ шлют `onContentsChanged` (без reload-цикла), sort/листинг — шлют. (5) Perf N-1 «скролл 50k»: строка 22pt фикс, ячейки view-based с reuse (`NameCell`/`MetaCell`), высота без autoresizing; perf-тест крутит делегат-пайплайн 5 000 строк × 3 колонки по 50k-фикстуре: budget aggregate < 4 c, одна строка < 33 мс (~2 кадра) после одноразового warm-up (классы ячеек/иконки прогреваются один раз — как при запуске приложения). (6) `ItemCache` = `LRUCache` (N ≤ 500) + статические иконки типа; реальные файлы — точная `NSWorkspace.icon(forFile:)`, фикстуры/виртуальные источники — иконка по расширению (`UTType(filenameExtension:)`, fallback `.data`). (7) Diff-обновление таблицы (SetDiff-батчи 06 §6.1) — T-06, сейчас листинг → презамена со снятием selection. (8) Меню — ручной минимальный срез (`MenuBuilder`), действия таргетят `PanelsCoordinator` напрямую (`mcGoUp`/`mcReload`/`mcGoHome`/`mcFocusLeft/Right`/`mcSwapPanels`); CommandID-роутинг и keymap-профили — T-09. (9) Координатор стартует с панелями на `~/` через `LocalVFS(at: "/")` — один том-инстанс; вход в СОСЕДНИЕ диски (`/Volumes/*`) требует `VFSRegistry` с per-volume LocalVFS — каталог переезда зафиксирован в `11`, задача с registry пойдёт отдельно (зайдёт после T-06/T-07); UI-строки — `String(localized:)` (каталог локалей добавится в задаче локализации, юникс-юниты уже в DomainKit). (10) Package.swift: `testDependencyNames` — VFSKit дается только ListViewKitTests (библиотека ListViewKit зависит только от DomainKit, контракт «UI не знает про адаптеры»).

### T-06. FSEventsWatcher + дифф-обновление панели
- **Цель:** живые панели (F-1, watch).
- **Файлы:** VFSKit/FSEventsWatcher.swift, VolumeMonitor.swift; ListViewKit/DiffUpdate.swift.
- **Готово:** внешние изменения отражаются ≤ 1 с; дифф ≤ 100 мс на 100 changed; mount/unmount обрабатывается.
- **Уточнение (по ходу реализации T-06):** (1) `VFSItem.isContentEquivalent(to:)` в DomainKit — сравнение ВСЕХ отображаемых полей БЕЗ `revision`: каждая перелистовка перенумеровывает ревизии, без этого панели заливались бы фантомными updates; используют и watcher (§6.3 diff), и `DiffUpdate`. (2) Позиции `FileListDelta`: `inserted`/`updated` — в НОВОМ порядке строк, `removed` — в СТАРОМ; применение строго begin → remove → insert → reload → end; при `oldCount != numberOfRows` таблицы батч невалиден (`isValidAgainst`) → fallback полного reload. (3) Perf-гейт «дифф ≤ 100 мс на 100 changed» интерпретирован на реалистичной панели 10k записей (F-1 сам нормирует «10 000 записей, P95»); 50k — отдельный тест линейности с бюджетом 0.5 c (debug-сборка ≈ 10× медленнее release; в release — десятки мс). Стоимость диффа — O(n) словарь идентичностей + по одному сравнению контента на выжившую строку. (4) `PanelViewModel`: `watchEngine` (didSet → restartWatch), watch-луп с guard `self.path == expectedPath` (stale-события после навигации не применяются); `setItems(at:)` при смене пути шлёт `onPathChanged` + restartWatch; `applyExternalDiff` = merge по идентичности (removed → updated → added), re-sort, дельта по старому/новому порядку, курсор ремапится по идентичности выжившего элемента, selection форм-intersect с новым множеством. (5) FSEventsWatcher: один физический FSEventStream на ВСЕ каталоги (пересоздаётся при смене набора), `kFSEventStreamCreateFlagUseCFTypes` (пути — CFArray), latency 0.5 c (§6.3); коалесцирование — DispatchWorkItem + asyncAfter(max(16, options.coalescingMilliseconds)) per-path; self-suppression (`suppress/clearSuppression`) по КАНОНИЧЕСКИМ путям (realpath: FSEvents репортит `/private/var/...`, а temp-директории приходят как `/var/...`), экспирация ленивая при обработке событий; дифф = повторный `listDirectory` через панельный `any VFS` (§6.3 «snapshot vs повторный список», не прямой lstat — панель может смотреть через любой адаптер); каталог исчез → один removed-all дифф, затем стрим завершается. (6) `VolumeMonitor`: NSWorkspace didMount/didUnmount на injectable NotificationCenter (тесты постят синтетические уведомления); specID = `volumeUUIDString` ресурсных значений точки монтирования, fallback «mounted:/removed:» + путь для UUID-less томов; mount — no-op до registry-задачи, unmount — панели, чей `path.root` совпал с инстансом события, делают reload (ошибка уходит в статус-строку). Ограничение: панели, смотрящие ` /Volumes/X` ЧЕРЕЗ единый `/`-адаптер, по инстансу не смэтчатся — фиксируется per-volume адасптерами VFSRegistry (задача каталога в 11). (7) LocalVFS `canWatch = true` (слот T-04). (8) Тестовая инфраструктура: AsyncStream ТЕРМИНИРУЕТСЯ при отмене читателя (semantics §5.4) — тест-хелперы держат ОДНОГО долгоживущего читателя (sink с lock) на весь тест и отменяют его только в конце; «group.next + cancelAll» теряет результат читателя и убивает подписку (ловилось минуту — зафиксировано, чтобы не повторить). (9) Package.swift: ListViewKitTests дополнительно получает VFSKit через `testDependencyNames` (T-05).

### T-07. Сортировка, quick filter, selections
- **Цель:** F-3, F-10, старт F-4 (full/brief).
- **Файлы:** EnginesKit/FilterEngine.swift; ListViewKit (selection-модель, режимы).
- **Готово:** критерии приёмки F-3/F-10; type-to-filter; Num-клавиши.
- **Уточнение (по ходу реализации T-07):** (1) `FilterEngine` работает над prepared (lowercased) именами: панель держит индекс рядом с `rawItems` (§6.6 «без создания строк повторно»); `candidates` — это «какие строки и в каком порядке проверять», поэтому порядок сортировки сохраняется всегда, а инкрементальность — расширение query → кандидаты = прошлый результат; любой другой edit пересчитывает полный сортированный проход. Fuzzy = жадная подпоследовательность символов. Perf-гейт F-10 (≤ 50 мс на 50k) проверен и на cold-проходе, и на инкрементальном stroke в debug-сборке. (2) Граф: ListViewKit → EnginesKit (слои 04; «UI не знает адаптеров» из T-05 касалось VFS-адаптеров — движки разрешены). (3) Фильтр живёт в VM (`setFilter`/`appendFilterCharacter`/`deleteLastFilterCharacter`/`clearFilter`/`acceptFilter`, `filterStyle` настраиваемый); type-to-filter: ВСЕ печатаемые клавиши, кроме Space и Num +/−/*// (они — выделение, F-3); Esc — сброс; Enter при активном фильтре — курсор на первое совпадение, фильтр остаётся активным (суженный вид = контекст панели); индикатор «filter: …» в статус-строке (F-10). (4) Смена видимости публикуется дельтой (`onContentsDelta` через `DiffUpdate`), а не reload; курсор «остаётся в контексте»: ремап по идентичности элемента под курсором, иначе clamp на прежнюю позицию; selection живёт в rawItems-пространстве и фильтром НЕ режется — при сбросе фильтра выделение невидимых строк возвращается. (5) Refresh-семантика `setItems` (F-3 «выделения выживают после refresh»): тот же путь → selection form-intersection по выжившим, потерянная часть запоминается в `previousSelection`, курсор ремапится по идентичности; смена пути → полный сброс (selection, previousSelection, фильтр, курсор). (6) Selection-операции: Space/Ins — toggle под курсором + сдвиг вниз (подсчёт размера папки для Space приходит с F-19 directorySize); Num `+`/`−` — select/deselect по маске (`FileMask`, DomainKit), сейчас клавиши работают с маской «*» (диалог ввода маски — с командным слоем T-09); Num `*` — инвертировать видимые; Num `/` — restore (swap с `previousSelection`); `effectiveSelection` — selection, при пустом — элемент под курсором (пакетные операции T-09). (7) F-4 старт: `PanelViewModel.ViewMode` brief/full; brief — только имя (макс. плотность); колонки pre-built и attach/detach'атся без пересоздания; переключение ⌃1/⌃2 (классификатор + меню View); custom columns/thumbnails — поздние фазы F-4. (8) `PanelKeys` — чистый классификатор (keyCode, modifiers, characters) → `PanelKeyCommand`; NSEvent не синтезируется, dispatch юнит-тестируется; Backspace при неактивном фильтре = на уровень выше (F-1 «Backspace/⌘↑»); нераспознанное — passToSuper (AppKit-стрелки и пр.). (9) main.swift печатает литеральный список модулей (BuildInfo-константы удалены из живых модулей; FileOpsKit/TerminalKit/ServicesKit заглушки остаются до их задач).

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
