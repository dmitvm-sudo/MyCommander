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
- **Уточнение (по ходу реализации T-08):** (1) `NavigationHistory` хранит только пути: `record(from:to:)` (первая локация — не back-запись; подряд-дубли схлопываются), `popBack/popForward(from:)` отдают destination — навигацию выполняет caller. (2) `PanelTab {id, viewModel, isLocked, history}`; workdir/selection/sort/filter/viewMode каждой табы живут в её собственной `PanelViewModel` (F-2). `PanelTabList`: `seed` идемпотентен при пустом списке; `appendTab(at:locked:restoringSelection:insertionIndex:)` — UUID генерируется ДО фабрики VM, позиция по умолчанию = после активной; загрузка пути асинхронная (Task); `closeTab` — последняя таба не закрывается; `closedStack ≤ 20` с исходной позицией; `reopenLastClosed` вставляет на исходную позицию и перезагружает сохранённый путь (история back/forward в v1-формате сессии НЕ восстанавливается). (3) Lock-семантика: `navigationGate` в VM (публичные точки openDirectory/openItem/goUp; приватный loadAndPublish, чтобы gate не вызывался дважды) дивертит открытие в НОВУЮ табу рядом + `onNavigationDenied`; лок блокирует только НОВЫЕ навигации — back/forward работают через `openDirectory(bypassingGate: true)` + `suppressHistoryRecording` (снимается defer'ом в конце Task). (4) `lastRecordedPaths [UUID: VFSPath]` — «previous» для истории; unwire закрытой табы: gate/onPathChanged = nil, watchEngine = nil (стоп watching); reopen возвращает engine из фабрики. (5) `stageSelectionRestore` в VM — сессионный selection применяется к следующей НЕ-refresh загрузке с intersection по свежему листингу. (6) UI: `PanelTabsView` — dumb view, полный rebuild при изменениях (≤ 20 табов — ок по F-2), `TabCellView` [lock][title][×] на NSButton target/action. `PanelViewController` — NSViewController, держит `PanelTabList` + таб-полосу + `FileListView` активной табы; `adoptTabList` для ⌘U swap (rebind при смене VM); `listTableView` — first-responder маршрутизация. (7) `SessionStore` (ServicesKit → DomainKit): `SessionSnapshot {schemaVersion=1 static, left/right PanelTabsSnapshot}`, `TabSnapshot {path, isLocked, selection: Set<VFSPath>, historyBack, historyForward}` (VFSPath Codable — §5.1); `load()` → nil на missing/corrupt/version mismatch; `save()` — atomic write + createDirectory; `init(storageURL:)` DI, дефолт `~/Library/Application Support/MyCommander/session.json`; `clear()`. (8) App: restore в init ДО создания панелей, fallback — seed home; `applicationWillTerminate` → `saveSession()`; ⌘T открывает клон текущей папки активной панели (классика NC/TC). (9) history replays не пишутся в историю (иначе back-стек растёт бесконечно при повторах).

### T-09. CommandRouter + KeymapStore + меню
- **Цель:** F-7 каркас: все действия = CommandID, remap работает.
- **Файлы:** App/CommandRouter.swift; ServicesKit/KeymapStore.swift; Resources/keymap-*.json.
- **Готово:** карта `07` активна; конфликты при ремапе блокируются; сброс к профилю.
- **Уточнение (по ходу реализации T-09):** (1) `CommandID` — enum String/CaseIterable (37 действий из карты 07: навигация/выделение/операции/режимы; операции F3–F9 пока без handler'ов — команды объявлены, чтобы профили были вперёд-совместимы; router возвращает `false`/меню их не показывает). `KeyCombo {keyCode: UInt16, modifiers: Set<ModifierToken>}` — AppKit-free (App мапит NSEvent.ModifierFlags ↔ tokens); `CommandContext {global, panelList, commandBar, lister, terminal}` (§5.7). Всё в `ServicesKit/KeymapStore.swift` (ServicesKit → DomainKit уже есть). (2) Профили: `KeymapProfile {id, name, entries}` — бандл `App/Resources/keymap-tc.json` (карта 07, ANSI-US) и `keymap-macos.json`; `keyCode`'ы F-клавиш = точные HID (F3=99, F4=118, F5=96, F6=97, F7=98, F8=100; Ins=114, Num+=69/−78/*67//75); первый профиль бандла = активный дефолт («карта 07 активна»). (3) Хранение: `keymap.json` (`{schemaVersion:1, profile}`) в App Support; `load()` → nil на missing/corrupt/version mismatch (семантика SessionStore); `save()` валидирует конфликты: «одинаковый (context, combo) у двух РАЗНЫХ команд» → `KeymapError.conflictingBinding`, сохранение блокируется и НЕ persists; одинаковый combo в разных контекстах и повтор одного command — легальны; `reset()` удаляет user-файл → бандл-дефолт. `KeymapStore` — `@unchecked Sendable` с NSLock (cachedActive). (4) `CommandRouter` (App): реестр `CommandID → handler` (регистрируют coordinator-классы, §6.10 «все команды реализуются методами coordinator-классов»); `@objc dispatchMenuItem(_)` — NSMenuItem.target, command id в `representedObject`; `dispatch()` → `false` если handler нет. (5) `MenuBuilder` переписан декларативно: секции/ItemsSpec = CommandID, item появляется только при зарегистрированном handler; keyEquivalent каждого пункта = из активного профиля (контекст global) через таблицу ANSI-US (keyCode → символ; непечатные кроме ↑ — без эквивалента, остаются в профиле); modifier'ы — из tokens. Меню: Go/Tabs/View/Selection/Window. (6) Реализованные handler'ы: goUp/goHome/reload/openItem, focusLeft/Right/swapPanels, newTab/closeTab/reopenClosedTab/nextTab/previousTab (⌃Tab/⌃⇧Tab — новый `PanelTabList.cycleTab(step:)` с wrap-around), viewFull/Brief, selectAll/invertAll/restoreSelection, selectMasked/deselectMasked — с sheet-диалогом ввода маски (NSAlert+ accessory NSTextField → `FileMask` → `select/deselect(matching:)`; закрывает долг T-07 «диалог маски — с командным слоем T-09»). (7) `main.swift` теперь реально запускает приложение (был smoke-принт с T-01: приложение ни разу не запускалось как GUI — первый реальный запуск отложен до ручной проверки). PanelKeys-классификатор таблицы пока НЕ ремапится (KeyBinder — ListViewKit, отдельная работа F-7); каркас ремапа пока на уровне меню. (8) Тесты: профили декодятся, tc-дефолт, roundtrip через файл, конфликты блокируются (и не персистятся), cross-context ок, reset → дефолт, lookup combo→command и command→entry, corrupt → дефолт; cycleTab wrap.

### T-10. Planner + Executor: copy same-volume
- **Цель:** ядро F-5 — планирование и исполнение копий с прогрессом.
- **Файлы:** FileOpsKit (TransferPlanner, OperationExecutor, CopyTransaction, TransferEvents); ListViewKit/ProgressWindow.swift (stub-UI).
- **Готово:** транспортные тесты same-volume (APFS clonefile-ветка + fcopyfile-ветка); пауза/отмена; прогресс-события.
- **Уточнение (по ходу реализации T-10):** (1) Вся «проводка» §5.6 уже была в DomainKit (TransferPlan/TransferItem/Conflict/ConflictPolicy/ConflictResolution/TransferEvent/Summary/OperationID/JournalRecord/Reversal — T-02/T-03) — T-10 только реализовала движок. (2) Контракт §5.6 уточнён: `enqueue` возвращает `(id: OperationID, events: AsyncStream<TransferEvent>)` — sketch возвращал только стрим, у вызывающего не было способа адресовать pause/resume/cancel. (3) Слои 04: FileOpsKit → DomainKit + VFSKit (LocalVFS.url(for:) стал public — локальные fast-paths), ListViewKit → + FileOpsKit (ProgressWindow). (4) `CopyTransaction` три ветки: clonefile(2) при same-volume+APFS (statfs f_fstypename; errno → fallback fcopyfile); fcopyfile в temp `.<name>.mc-partial` + F_FULLFSYNC + atomic rename; VFS-generic byteStream-ветка — чанки 1 MB через ByteStream, атомарность даёт staged writer destination-VFS (бросание writer'а без finish чистит temp — LocalByteWriter.deinit). Отмена: Task.checkCancellation между чанками; stream-ветка не оставляет целевого файла (8.3); для каталогов — materializeDirectory + `ensureAncestors` (mkdir -p-семантика: с пулом воркеров вложенный файл может стартовать раньше каталога-предка; гонка с созданием предка разрешается re-check'ом). Symlinks копируются по содержимому (презервация линков — T-11). (5) `OperationExecutor` (actor): windowed worker pool ≤ 4 (FIFO стартов), конфликт-резолюция per-item (precomputed Conflict > runtime re-check targetExists; overwrite → delete-target, skip → skippedItems, keepBoth → `uniqueTargetName` «name(1).ext», cancel →abort операции; insideSelfMove → itemFailed); journal-запись `.deleteCreated(target)` после каждого успешного item. (6) `OperationGate` (Sendable, NSLock + continuations): пауза проверяется между чанками; cancel будит всех ожидающих (отмена наблюдается через Task.isCancelled). (7) Прогресс: `CopyProgressSink` — async-колбэк, вызываемый inline копирующим циклом (опыт: detached Task-спавн на каждый чанк давал латентность событий, при параллельном наборе тестов пауза/отмена «опаздывали»; inline-await даёт честный бюджет ≤ 500 мс). Aggregate: completedBytes — дельта по itemBytes; summary.bytesTransferred = completedBytes на finish. queuePosition = 0 (v1, операции исполняются конкурентно; очередь с позициями — по мере надобности). (8) `TransferEvents` — app-wide hub (подписка AsyncStream<(OperationID, TransferEvent)>). `ProgressWindow` (stub): статус + Pause/Resume/Cancel, закрытие окна не отменяет операцию (F-5 фон); сводный диалог и дизайн — T-12. (9) App: `.copyFiles` handler — effectiveSelection активной панели → план в противоположную панель, policy `.keepBoth` (диалог конфликтов — T-12). F-клавиши F5–F9 пришли в keymap — PanelKeys.type-to-filter больше не глотает private-use скаляры (0xF704… от function-клавиш) — passToSuper. (10) Тесты (15): clone (inode различен, размер/контент равны, auto-транспорт = clonefile), fcopyfile byte-wise, byteStream cross-instance, дерево 4 items, политики overwrite/skip/keepBoth/applyToAll (+ runtime re-check), unique suffix последовательно, insideSelfMove отказ, cancel в середине → нет целевого файла, пауза-стойло-резюм, per-item failure + частичный результат, агрегированные байты, journal ring 20, journal-реверсалы успешной копии. Тесты детерминированы по времени (throttle-обёртка над InMemoryVFS; пауза/отмена по таймеру, не по событию — pump'ы detached).

### T-11. Cross-volume move/delete + resume
- **Цель:** F-5 полностью для локального.
- **Файлы:** MoveTransaction, DeleteTransaction; конфигурабельные воркеры.
- **Готово:** матрица томов из 8.3 (апфс/хфс+/exFAT образы); resume `.mc-partial`; troubles errno.
- **Уточнение (по ходу реализации T-11):** (1) `VolumeKeyProvider` — `@Sendable (URL) -> String?`, дефолт `posixVolumeKey` = statfs `f_mntfromname`; statfs на ЕЩЁ НЕ СУЩЕСТВУЮЩЕМ target-пути даёт ENOENT → провайдер поднимается к ближайшему существующему предку (том тот же по определению) — это же чинит детект cross-volume для копий (T-10 брал fcopyfile-fallback). Тесты инъекцией константных ключей («A»/«B» по префиксу пути) делают cross-volume детерминированным без реальной геометрии томов — дисковые образы hfs+/exFAT (8.3) остаются на интеграционный уровень. (2) `CopyTransaction` +4-я ветка `localChunkedBranch` (cross-volume local): FileHandle-чанки 1 MB в `.<name>.mc-partial`, F_FULLFSYNC, atomic rename; **resume по offset** — существующий partial с 0 < size < sourceSize переиспользуется (seek+truncate на offset, докачка хвостом; partial длиннее источника = повреждён → рестарт); **cancel ОСТАВЛЯЕТ partial** (8.3 требует лишь отсутствия целевого файла), retry тем же планом доукачивает. Параметр `chunkDelay` (наносекунды между чанками, транзитом через executor `chunkDelayNanoseconds`) — детерминизм pause/cancel/resume тестов по времени без ThrottledVFS. (3) `MoveTransaction.run` per top-level item → `MoveOutcome {renamed | movedCrossVolume(files,bytes)}`: same-volume (оба LocalVFS + равные ключи, `FileManager.moveItem` = rename(2), inode сохранён) — ЦЕЛИКОМ поддерево; cross-volume/non-local — рекурсия в одной транзакции: dir → mkdir-стейджинг + per-child (file → CopyTransaction + немедленное удаление source-файла; subdir → рекурсия), source-каталог удаляется после детей (deepest-first fallout рекурсии). Упрощение против чернового плана: **фазы 2 нет** — рекурсия внутри транзакции top-level item'а исключает гонки pool/зависимости и промежуточные staged-каталоги; семантика §6.2 сохранена. (4) `DeleteTransaction.run` → `DeleteOutcome {trashed(trashURL,files,bytes) | removed(files,bytes)}`: local+toTrash → один `fm.trashItem` на дерево (reversal `.restoreFromTrash(original:trashURL:)` — undo-данные F-6); local+permanent → bottom-up walk (children сначала; рекурсия удаляет поддерево ВМЕСТЕ с корнем поддерева — родительский цикл НЕ трогает directory-children повторно, иначе ENOENT; readonly-файлы удаляются, если parent writable — POSIX unlink-правила; узел-корень удаляется последним); non-local → делегирование `VFS.delete(paths, toTrash:)`. (5) Executor: init + `deleteToTrash: Bool = true` (F-5 «в корзину по умолчанию»), `chunkDelayNanoseconds`, `volumeKeyProvider`; `perform` диспетчит по plan.op (.copy/.move/.delete; .link → все items vfsUnsupported до отдельной задачи); общая `resolveConflicts` для всех op (для delete runtime re-check — ИСТОЧНИК: vanished → itemFailed, для copy/move — target: targetExists → policy); `.skip` теперь учитывает startedItems; executeMove исполняет только top-level items (descendants subsumed — rename переносит поддерево, отдельный rename потомка упал бы ENOENT; `topLevelIndices` — нет предка-каталога среди источников плана); bytesTransferred: для move = перенесённые байты, для delete = освобождённые байты. Конфликты плана без соответствующего item (insideSelfMove у planMove, sourceVanished у planDelete — план не хранит VFSItem для отсутствующих) surfaced как failed items. (6) `TransferPlanner.planMove`/`planDelete` (+ общий `planTopLevel` для copy/move; planDelete без разворота дерева — walk на рантайме; vanished → conflict `.sourceVanished`). (7) App: `.moveRenameFiles` (F6 → в противоположную панель), `.deleteFiles` (F8, trash); меню-секция Operations (menu.copyFiles/moveFiles/deleteFiles); рефакторинг `selectedSources`/`beginTransferToOppositePane(op)`. (8) Тесты (9): same-volume rename + inode сохранён + journal renameBack; cross-volume file+дерево (инъекция ключей) — content byte-wise, sources удалены; move в собственную подпапку — конфликт+failedItem, источник цел; permanent delete дерева (bottom-up, readonly 0444, bytesFreed > 0, journal БЕЗ реверсалов); trash + reversal restoreFromTrash (trashURL реально в Корзине); resume после cancel (partial 0<size<source, целевого нет; re-enqueue → byte-wise равен на НЕ-однородном паттерне — ловит баг рестарта-с-нуля, partial очищен, source удалён); move между InMemoryVFS = copy+delete; delete через fake-VFS делегирование; autoTransportKind детектит инъекцию. Урок: тест-хелпер путей строил компоненты фильтром `url.pathComponents` (даёт полный путь от «/») — компоненты должны быть ОТНОСИТЕЛЬНО корня VFS; директории-URL дают trailing slash в displayURL — сравнение VFSPath чувствительно, в ожиданиях использовать тот же конструктор, что в планере (`appending(component:)`).

### T-12. Конфликт-диалог + summary
- **Цель:** UX F-5 (конфликты, apply-to-all, отчёт).
- **Файлы:** ListViewKit/ConflictDialog.swift; FileOpsKit/ConflictModels (связка).
- **Готово:** превью-таблица; policy per-item/all; summary ok/skip/fail.
- **Уточнение (по ходу реализации T-12):** (1) Контракт §5.6 уточнён (SDD-правка раньше кода): `Conflict {source, target, kind, sourceItem: VFSItem?}` — метаданные источника для превью диалога; planners заполняют. (2) `FileOpsKit/ConflictModels.swift` — wire format planner↔диалог: `ConflictPreviewRow {conflict, sourceItem, targetItem}`; `preparePreviewRows(conflicts:source:destination:)` добирает недостающие стороны ДО открытия диалога (диалог сам не трогает VFS; carried-nil target у `.targetExists` → live fetch через destination); `buildPolicy(rows:resolutions:applyToAll:)` — «apply to all» становится policy default, расходящиеся per-row выборы остаются в map (в map попадают только `.targetExists`-строки; без apply-to-all default = `.keepBoth`, безопасно для runtime re-check'ов). (3) `ListViewKit/ConflictDialog.swift`: view-based NSTableView (name/source/target/resolution-popup per-row), кнопки «all» Overwrite/Skip/KeepBoth (ручное изменение строки сбрасывает apply-to-all), Continue/Cancel; `run(rows:)` — модальное ОКНО (`NSApp.runModal`, не sheet), возвращает `ConflictPolicy?` (nil = отмена → операция не стартует). Принцип тест-совместимости: `init(rows:)`/`applyAll`/`buildPolicy` internal — чистая логика без модального цикла. App: диалог показывается только при непустых plan.conflicts; runtime-конфликты (появившиеся ПОСЛЕ диалога) остаются на policy default. (4) `OperationReport` (Sendable value-тип, ListViewKit) — аккумулятор из event-стрима: ok/skip/fail + причины (`.itemFailed` кладёт errorDescription; `.finished` дозаполняет подсчёты из Summary); `ProgressWindow` на `.finished` показывает `summaryLine` + причины и ОСТАЁТСЯ открытым (auto-close удалён; закрытие окна по-прежнему не отменяет операцию — фон-семантика F-5). (5) Фикс гонки (пойман tree-тестом): runtime re-check целей выполняется ЕДИНЫМ проходом ДО пула воркеров (`Run.runtimeConflicts`; `resolveConflicts` берёт plan.conflicts, иначе runtimeConflicts) — иначе попутный `ensureAncestors` соседнего item'а материализует каталог-предка mid-operation, каталоговый item получает ложный «target exists» и при дефолтном `.skip` лишается исполнения; `CopyTransaction.materializeDirectory` терпит существующий каталог (тоже re-check; `InMemoryVFS.createDirectory` идемпотентен — семантика EEXIST). (6) Тесты +6 (`ConflictModelsTests` 3 + `ConflictDialogTests` 3) = 154, стабильно в 3 прогонах. Уроки: `??` с rhs `try? await` не компилируется (в операторе нет async-контекста) — разворачивать в if-let; `ConflictPreviewRow` живёт в FileOpsKit (тестам ListViewKit нужен `import FileOpsKit`); протокольные требования NSTableViewDataSource/Delegate в public-классе обязаны быть `public`.

### (Слот T-13: Journal/undo перенесён в T-20 внутри M2; нумерация сохранена для стабильности ссылок)
_(этот слот оставлен пустым намеренно: нумерация стабильнее, чем перемещение.)_

### T-13. Lister + Quick Look
- **Цель:** F-8, F-9.
- **Файлы:** ListViewKit/ListerWindow.swift; byte-stream чтение через VFS.
- **Готово:** критерии F-8/F-9 (4 GB текста — окно-стрим; QL для VFS через temp).
- **Уточнение (по ходу реализации T-13):** (1) SDD-правки раньше кода: `05` §5.5 — протокол `ByteStreamSeekable` (seek-способные адаптеры доказывают это протоколом, без него лоадер делает skip-forward добор); `06` §6.7 — контракт v1: `ListerByteSource`/`ListerLoader`/`PreviewMaterializer`/`ListerTextPage`/`ListerCodec`, стрим-окно текст 256 KB / hex 64 KB / image — целевой файл (8 MB из черновика уменьшены: файл без newline — одна «строка» размером с окно тормозит NSTextView, семантика «окно+seek» сохранена); разрешён конфликт Space F-3/F-9 (`02` F-9 и строка `07` приведены: Space в списке = выделение F-3, QL = `⌘Y`, Space/⇧Space в окне Lister = страница вперёд/назад). (2) `DomainKit/ByteStream.swift` — `ByteStreamSeekable: ByteStream { seek(to:) }`; конформансы: `LocalByteStream` (FileHandle.seek, сброс closed=false), `InMemoryByteStream` (position, clamp [0, length]). (3) `FileOpsKit/PreviewSupport.swift`: `ListerLoader.open` — каждый `read` открывает стрим заново, seek / skip-forward чанками 1 MB, clamp до EOF; размер — metadata.attributes.size, при нуле — `stream.length`; `PreviewMaterializer.prepareFileURL` — LocalVFS → прямой файл-URL, прочие адаптеры → temp-копия `TMPDIR/.mc-preview-<uuid>/<имя>` (**createFile ПЕРЕД FileHandle** — forWritingAtPath на несуществующем файле даёт nil), `purgeTempCopies()` на applicationWillTerminate (QL держит копии открытой сессии до конца сессии — по §6.7). (4) `ListViewKit/ListerWindow.swift`: авто-режим — image-расширения → image, NUL в первых 4 KB → hex, иначе text; детект кодировки — BOM → **структурная UTF-16-эвристика до strict-UTF-8** (строгий UTF-8 «привет мир» в LE валиден — управляющие код-поинты; решения: control-зона ≥ 75% одной стороны пар при ≤ 5% у другой, либо null-parity ≥ 40% → UTF-16) → strict utf8; `decodeTextPage` — BOM-strip первой страницы, скип ведущих continuation-байт, обрезка незавершённого хвостового символа, UTF-16 выравнивание по файловой чётности, хвостовой хай-суррогат ре-ридится следующей страницей; `hexPage` — 16 B/строку offset/hex/ascii (`..`/`·`); `ListerKeys.classify` — PgUp/PgDn, ⌃Home/⌃End jumps, Space/⇧Space страницы, ⌃H toggleHex; `ListerModel` — paging/jump/clamp, toggleHex хранит savedTextEncoding, internal `strideOverride` для тестов; `ListerBootstrap.open` — снифф + провайдер imageURL вызывается ТОЛЬКО в image-сниффе (провал → hex); `ListerWindowController` — reusable (`reset(to:)` при втором F3), слайдер/статус «позиция · всего · режим/кодировка». (5) `QuickLookPanel.swift` (F-9): `QuickLookItem : QLPreviewItem` c displayName (temp-копии показывают исходное имя), `QuickLookController` — data source/delegate, ↑/↓ перехват `previewPanel(_:handle:)`; `QuickLookPresenter.show` — `guard let panel = QLPreviewPanel.shared()`, ПРЯМОЕ `beginPreviewPanelControl` до `makeKeyAndOrderFront` (иначе panel вызывает accepts у responder-chain до установки dataSource), retention через статический currentController. (6) App: `PanelsCoordinator` — `.viewFile`/`.editFile`/`.quickLook`, `selectedFileItems` (файлы в видимом порядке, каталоги skip), reusable `listerWindow`, F4 через `NSWorkspace.open`, ⌘Y — cap 100 item'ов; `MenuBuilder` — **эквиваленты меню фоллбэком ищутся и в `.panelList`** (F-клавиши из профилей никогда не доходили до меню — латентный гейп T-10/T-11, F5/F6/F8 ожили попутно) + F-глифы NSF3–NSF8FunctionKey + 3 пункта в Operations; `keymap-tc.json` — quickLook ⌘Y (keyCode 16, command, global — как в macos-профиле); `MyCommanderApp` — purge temp-копий на terminate. (7) Тесты +17 = 171 (`pv` — окна/skip-forward/4 GB sparse near-end/direct URL/temp+purge; `lw` — режимы/детект/границы страниц/no-newline сшивка/UTF-16 и суррогаты/hex-грид/keys/paging+failure/bootstrap; `qk` — items/count+clamp/arrow-nav). Уроки Swift 6: метод протокола QLPreviewPanelDelegate в этом SDK — `previewPanel(_:handle:)`, НЕ `previewPanel(_:handleEvent:)` (иначе «requires override» от NSViewController-категории); `String.Encoding.utf16LittleEndianStringEncoding` в SDK НЕТ — ручные UInt16 units + `String(decoding:as:UTF16.self)`; авто-свойство NSTextView — `isAutomaticTextCompletionEnabled`; switch-expression требует явной аннотации типа (`let bom: [UInt8] = switch…`); `MainActor.assumeIsolated` падает вне main-треда — MainActor-тесты через `@MainActor @Test`; MainActor-класс к QL-протоколам — через `@preconcurrency` conformance; скобка QL `handle` с nil-панелью (тест) — `guard let event` + `panel?.` (nil-safe).

### T-14. Command bar (⌘L)
- **Цель:** F-17а.
- **Файлы:** ListViewKit/CommandBar.swift; TerminalKit/ShellSession (только exec-ветка).
- **Готово:** cd/mkdir/open/!с; плейсхолдеры %f %F %d %D %s; история.
- **Уточнение (по ходу реализации T-14):** (1) SDD раньше кода: `02` F-17а — граница v1 (cd/mkdir/open/`!` + история/плейсхолдеры; touch/du/find, Tab-автодополнение — следующая версия; PTY — F-17 M3); `06` §6.8 «Контракт v1» — ShellOutcome/ShellSession.exec + CommandBarParser/плейсхолдеры/CommandHistory, поведение: keyword маршрутизируется ДО расширения (пробелы в подстановках не рвут токен), подстанованные пути цитируются shell-вариантом при пробелах/кавычках, vfs-команды разворачивают их `unquote`, `%%` ≡ литерал, `%f`/`%F`/`%d`/`%D`/`%s` (пустое выделение → файл под курсором). (2) `Package.swift`: TerminalKit → ["DomainKit"] (spawn-ошибки мапятся в MCError.unexpected — §5.8). (3) `TerminalKit/ShellSession.swift`: exec = one-shot `/bin/sh -c`, stdin = nullDevice; stdout/stderr — pipe-readabilityHandler (накопление в @unchecked-Sendable коллекторе), финальный flush `readDataToEndOfFile` после снятия handler'а (иначе хвост теряется), exit — через terminationHandler + withCheckedContinuation (resume допустим из любого потока); non-zero exit — обычный исход, не throw. (4) `ListViewKit/CommandBar.swift`: чистая логика без AppKit/VFS — parse/expansion/unquote/CommandHistory (up от черновика → новейшая, до старейших, down → обратно к черновику; dedup ТОЛЬКО последовательных); view: промпт + однострочный input + `[^]`-сворачивание + мини-консоль ( NSTextView 130pt, авто-открытие на вывод, cap 1000 строк, ошибки красным); клавиатура через NSTextFieldDelegate `doCommandBy` — Enter=submit, Esc=onEscape, ↑/↓=история (Tab не перехватывается). (5) App: панель бар'а держит PanelsCoordinator (MainWindowController растит его ПОД splitView); драйвер: parse → Task: cd — резолв `~` / абсолют / относительный + metadata-валидация → openDirectory; mkdir — ровно одно имя (вложенность = честная ошибка) → createDirectory + reload; open — каталог → панель, файл (LocalVFS) → NSWorkspace; `!` — только LocalVFS, ShellSession.exec с cwd панели, вывод «$ cmd» → stdout/stderr → «exit N» при ≠0; Esc — clear-or-return-to-panel; промпт = активная директория. `VFSItemKind` не Equatable (associated value symlink) — kind-сравнение через pattern-match (symlink проходит для любого wanted). (6) Меню: `menu.commandBar` в секцию View; keymap-tc/macos — `focusCommandBar` ⌘L (keyCode 37, command, global). (7) Тесты +7 = 178 (`sh` — стримы+exit / cwd-доказательство через cat + pwd-component / MCError на исчезнувший cwd; `cb` — маршрутизация и ошибки, плейсхолдеры+цитирование, unquote roundtrip, история-черновик). Уроки Swift 6: `String(line[i ...])` внутри вызова ломает парсер («expected expression after operator») — писать `line[i ..< line.endIndex]`; unknown `%x` в scan должен продвигаться на ИМЕННО tokenStart (наивный `line.index(after: index)` дублирует токен); `URL.resolvingSymlinksInPath()` может НЕ резолвить симлинк /private/var — pwd-тест держать на lastPathComponent + «cat file.txt» как доказательстве cwd; `VFSItemKind ==`/`match` — только switch по парам (associated value).

### T-15. Info/properties + dirSize
- **Цель:** F-19.
- **Файлы:** ListViewKit/InfoDialog.swift; VFS directorySize (progress).
- **Готово:** карточка без блокировки UI; рекурсивный размер — фоновый подсчёт по завершении.
- **Уточнение (по ходу реализации T-15):** (1) SDD раньше кода: `06` новая §6.11 «Контракт v1 (T-15)» — `InfoField{kind,label,value}`/`InfoKind` (name/kind/size/created/modified/permissions/owner/group/tags), `InfoFieldBuilder.fields(for:)`, стабильные рендеры: `InfoBytes` (1024-база, одна десятичная, трим `.0`: «2 KB», «1.5 MB»), `InfoPermissions` («rw-r--r-- (644)», без ls-типового байта — kind-строка его несёт), `InfoDates` («YYYY-MM-DD HH:MM», фиксированное форматирование, локально-инвариантное для тестов), `InfoDisplay.compose/updatingSize`; `02` F-19 — v1-скоуп нота + фиксация acceptance-опечатки («работ1951» → «работает»); `07` — строка «⌃A / ремап | Info/свойства». (2) `CommandID.itemInfo` (ServicesKit). (3) `ListViewKit/InfoDialog.swift`: окно non-modal (titled+closable, 460×360), переиспользуемое `reset(to:)` (паттерн ListerWindow), карточка — selectable plain-text (InfoDisplay.compose), кнопка Copy → NSPasteboard plain text (acceptance «копирование списка полей»); отсутствие значений → «—». (4) App: `.itemInfo` — item ПОД КУРСОРОМ (не выделение — семантика карточки NC); каталог: фоновый `Task { vfs.directorySize(of:progress:) }` с пустым sink (v1 только финал, промежуточные счётчики не рендерятся — они всё равно не байты), завершение → `infoWindow?.update(size:)` (MainActor-хоп прямым вызовом — Task внутри @MainActor-класса, без `MainActor.assumeIsolated`); файл — «—» не ставится (attributes.size уже есть). (5) keymap-tc/macos — `itemInfo` ⌃A (keyCode 0 + control, panelList; ⌘A занят selectAll — конфликтов нет), меню `menu.itemInfo` в Operations. (6) Тесты +5 = 183 (id: file-поля с точными значениями пермишенов/дат/тегов, каталог-«—» + updatingSize, bytes-грид (0/999/1024/1536/**1024²**/1.5M/1024³/**-5 → «0 B»**), permissions/dates, compose). Уроки Swift 6: tuple-возврат из хелпера строится явно (`let f: (String)->VFSPath = …; return (id, f)` — trailing-closure на tuple-поле не валиден); `VFSItemAttributes()` — дефолтный init доступен, поля мутабельны; мёртвые утилиты из черновика вычищать сразу (услышанное «bits(0)»-stub); `await` при не-async методе = warning no-async-operations — просто убрать await; sink-копилки с захватом var из Task-замыкания Swift 6 не пропустит — пустой sink честнее (v1-решение).

### T-16. Drag & Drop обе стороны
- **Цель:** F-18.
- **Файлы:** FileListView (NSPasteboard/DnD мост) + FileOpsKit-интеграция.
- **Готово:** Finder↔панель, panel↔panel; курсор-бейджи; drop в архив — extract.
- **Уточнение (по ходу реализации T-16):** (1) SDD раньше кода: `06` §6.1 «Контракт v1 (T-16)» — транспорт NSPasteboard, `DragBridge` (тип `com.mycommander.panel-item.v1`; `entry(fileURL:path:) → NSPasteboardItem`: `.fileURL` — Finder-совместимый URL, item-тип — JSON `VFSPath`; `readURLs`/`readPaths` = readObjects(urlReadingFileURLsOnly)/per-item decode), `FileListView` — drag source/destination БЕЗ знаний о VFS (`onPasteboardWriterForRow: (Int) -> (any NSPasteboardWriting)?`, `onDropReceived(urls:paths:isInternal:wantsCopy:)`); `02` F-18 — v1-скоуп (LocalVFS; SFTP/архив-drag — M2) + фикс опечатки «symметрично»→«симметрично». (2) `ListViewKit/DragBridge.swift` — транспорт на private pasteboards (тесты не бьют general). (3) `FileListView`: источник — data-source метод `tableView(_:pasteboardWriterForRow:)` (современный; `pasteboardWriterForRowAt` — UIKit-имя, «nearly matches»-warning не пройти); destination — `registerForDraggedTypes([.fileURL, itemType])` на панель целиком + `draggingEntered/Updated/performDragOperation` override; self-drop (`draggingSource as? FileListView === self`) → NSDragOperation[]; internal → `.move` (⌥=`.copy`, модификаторы читаются из `NSApp.currentEvent` — NSDraggingInfo не отдаёт событие); Finder → `.copy`; чужой payload (ни один из двух типов) → отказ; бейджи copy/move рисует система по NSDragOperation. (4) App: `executeTransfer(op:sources:source:destinationPane:)` — вынесен общий путь из `beginTransferToOppositePane` (plan → conflicts-диалог → enqueue → showProgress); wireDragEngines строит entry только для LocalVFS-строк (`source as? LocalVFS`) — non-local row НЕ тянет; acceptDrop: paths internal мапятся 1:1, Finder-URLs → `localPath(from:)` — root НЕ `VFSPath.local(url)`, а `fileSystem.id` (specID volume UUID может различаться → LocalVFS.url(for:) precondition «path belongs to another instance»); панель/панель → верифицировать `sources.allSatisfy(root == fileSystem.id)`, чужеродный payload → честная ошибка в консоль бара. (5) Drop-target — панель целиком; после операции авто-обновление через FSEventsWatcher. (6) Тесты +6 = 189 (`db`: round trip URL+path, payload-only entry, empty → nil, foreign-item skip, multi-row 2 items, acceptedTypes-контракт). Уроки Swift 6: IUO-поля (`PanelViewController!`) в массиве превращаются в optional → per-элемент хелпер-метод; в тестах private pasteboard «db-UUID», не general (`NSPasteboard.general` протекающий между suite-run).

### T-17. FDA onboarding + Safe Mode
- **Цель:** F-20.
- **Файлы:** App/Onboarding/*; status-индикатор в панели.
- **Готово:** критерии F-20 (grant / fail / hide); работает после отказа.
- **Уточнение (по ходу реализации T-17):** (1) SDD раньше кода: `06` §6.10 «Контракт v1 (T-17)» — `VFSKit/AccessProbe.swift`: `AccessZone{desktop,documents,downloads,library}`, `AccessReport{hasFullDiskAccess, grantedZones}`, `AccessMode{full, safe(zones), restricted}`, `classify()` (total: restricted — приложение не падает никогда; ошибки листинга — через MCError/панель-ноту §5.8), `probe(home:fileManager:)` НЕ-async и параметризуемый home для тестов: FDA-проба = читаемость `~/Library/Preferences/com.apple.dock.plist` (TCC-защищённый файл), зона granted = `contentsOfDirectory` успех (пустой список тоже granted, ошибка → нет); `ServicesKit/OnboardingState.swift`: чистая модель «max 2 навязки» (shouldOfferInitially / canOfferAgain=dismissedCount<2 / afterDismiss() / hiddenPermanently); `02` F-20 — v1-скоуп (окно без графики; probe на activation; seed granted-зоны; затем только бейдж). (2) `FileListView` — `accessBadge: String?` (didSet → updateStatus) + `statusText` (публичный геттер для тестов) — бейдж добавляется в статус-строку после error-ноты. (3) App `OnboardingFlow`: non-modal окно (460×210: head/body + 3 кнопки: System Settings = `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` (keyEquivalent ⏎), «Продолжить без FDA» = afterDismiss + close, «Не показывать снова» = afterDismiss().hiddenPermanently + close); probe на каждом `NSApplicationDidBecomeActiveNotification` (granted → закрывает окно сам; denial в этой сессии НЕ пере-предлагается — только следующий запуск до 2); UserDefaults `mc.onboarding.dismissed/hidden` только в App; granted-режим полностью закрывает flow; MyCommanderApp держит сильную ссылку (иначе observer умрёт). (4) `PanelsCoordinator.applyAccessMode(_ mode:grantedZones:)` — бейджи на ОБЕ панели; `initialSeedPath` — первый granted zone при первом запуске без сессии (safe), иначе home; `.goHome` остаётся на homePath (user intent, denied→ошибка листинга, не crash). (5) Тесты +8 = 197 (`ap` 4: синтет home FDA-проба через write dock.plist, зона granted по списку, classify 3 режима, seedPath; `ob` 3: initial/dismiss-count/hide; `ab` 1: badge install/replace/nil). Уроки Swift 6: тесты не должны полагаться на реальную FDA-машину (синтет home + dock.plist); `deinit`-removeObserver в @MainActor class — ок без хопов.

### T-18. Настройки (базовые) 
- **Цель:** F-21 MVP: шрифты, подтверждения, редактор, экспорт/импорт JSON.
- **Файлы:** ServicesKit/SettingsStore.swift; App/Dialogs/Settings.
- **Готово:** применение без рестарта; schemaVersion заложена.
- **Уточнение (по ходу реализации T-18):** (1) SDD раньше кода: `06` §6.9 «Контракт v1 (T-18)» — `SettingsSchema` (schemaVersion=1; appearance: panelFontFamily/panelFontSize/useMonospacedPanelFont; deletion: confirmDelete + deleteConfirmThreshold (07 §7.3 ≥N default 5); editor: textEditorPath (пусто=системный дефолт)), `SettingsStore` @MainActor (init(url: injectable default `SettingsStore.defaultURL()`), onDidUpdate, update(mutate) apply+persist+fire, reset(section), export/import; мерж: user-JSON → optional-overrides decode поверх defaults, foreign schemaVersion или мусор → чистые defaults; persist-ошибка НЕ блокирует live-update), `02` F-21 — v1-скоуп (окна AppKit, не SwiftUI — M3). (2) Потребители: `FileListView.applyPanelFont(NSFont?)` (cells applyPanelFont в viewFor — reused cell получает face каждый render; visible-rows reloadData при смене; font строит App `NSFont.wrappedPanelFont(from:)` — ServicesKit без AppKit); `editFirstInExternalEditor` — schema.textEditorPath: непусто и (.app-бандл || isExecutableFile) → `NSWorkspace.open([url], withApplicationAt:configuration:)` (`try await`), иначе системный дефолт; `beginDeleteSelection` — `confirmDelete && sources.count >= max(1, threshold)` → NSAlert.warning (кнопки `settings.deletion.confirm.ok/cancel`), отказ — стоп без plan/enqueue. (3) App `SettingsWindowController`: non-modal reusable (⌘,), секции appearance/deletion/editor, каждая с Reset; `SettingsStepperField` (label+stepper, value-setter БЕЗ side-эффекта — нет петли update↔refresh); Export…/Import… через NSSavePanel/NSOpenPanel ([.json]); browse — `[.application]`; init: window собран до super.init, contentView — guard → build(contentView:). (4) Меню `menu.openSettings` (Go-секция), keymap-tc/macos — `openSettings` ⌘, (keyCode 43 + command, global). (5) Тесты +8 = 205 (`st` ×7: defaults-мерж, foreign-version ignore, мусор → defaults, update persist+notify по reloaded store, reset per-section, export/import round trip, failed import сохраняет состояние; `sf` — applyPanelFont через фабрику ячеек viewFor). Уроки Swift 6: default-аргумент `= Self.defaultURL()` в классе запрещён (covariant Self) — nullable param + ?? в теле; `encoder.outputFormatting([…])` — это property-присваивание, не функция; didSet на себя в struct → бесконечная рекурсия (убран); variadic `NSStackView...` + array-вызов = type mismatch — plain `[NSView]` параметр; `NSWorkspace.open(_:withApplicationAt:)` бриджится async+throws — `try await`; `.alertFirstButtonReturn` (не firstButtonReturn); тесты SettingsStore — все `@MainActor`; viewAtColumn → view(atColumn:). Доп: вычищен остаточный артефакт T-17 («appendposed») в 06 §6.10.

### T-19. M1 hardening
- **Цель:** закрыть exit-критерии M1.
- **Шаги:** perf-бюджеты в CI (8.5); memory-профили; smoke 8.4 п.1–5, 8 вручную; багфикс.
- **Готово:** все пункты M1-exit зелёные.
- **Уточнение (по ходу реализации T-19):** (1) SDD раньше кода: `08` §8.5 «Уточнение T-19 (CI-гейт v1)» — что автоматизировано, что остаётся вручную; `05` §5.9 уточнение — новый публичный хелпер `sortedIndices(by:) -> [Int]` (та же стабильная семантика сортировки, без копии items). (2) CI: добавлена job `perf` — Release-прогон бюджетов (`swift test -c release --enable-swift-testing`, fail-on-regression); Debug-прогон основного job уже несёт ассерты. Новые гейты: catalog open 10k (`VFSKit/CatalogPerfTests`, in-test ≤2.0s при честном регистре ≤0.3s P95 — запас против нагруженного параллельного прогона), lister open 4GB-sparse + первое окно 8MB ≤1.0s (`FileOpsKit/ListerPerfTests`, регистр ≤0.2s). Уже стоявшие: quick filter 50k (F-10/T-07), diff 50k/100 ≤100ms (T-06), scroll-sweep 50k (T-05). (3) Memory-профили N-2: `ListViewKit/MemoryFootprintTests` — panel 100k строк: footprint delta ≤100MB; найдено реальное раздувание: `PanelViewModel.recomputeVisibility` сортировал полную копию 100k items (29.6MB transient залипали в malloc-зонах; замер 123MB) → `rawItems.sortedIndices(by:)` ([Int] 0.8MB) → 84.3MB; стрим-окна Листера 4×8MB на 4GB sparse (delta ≤64MB — полный файл не буферизуется). (4) Инструментальный урок: footprint-замеры — в коротких вложенных Tasks (Foundation-чтения держат буферы в ObjC-пуле таска — +64MB/раунд накопления; per-task pool дренится по завершению), min-of-3 раундов + `malloc_zone_pressure_relief` до/после, снапшоты внутри таска (мс-окно против соседских параллельных аллокаций). Ловушки: `Array(self.indices)` внутри `extension Array where Element == VFSItem` резолвится в элемент-тип → `Array<Int>(…)`; `malloc_statistics_t` без `free_size`; live-диагностика через `malloc_zone_statistics(malloc_default_zone())`. (5) Остаток M1-exit — ручные пункты владельца: smoke 8.4 п.1–5/8, poison-test FDA, «2 дня пользования» — не автоматизируются; автоматизируемая часть зелёная (build чист, 209 тестов ×2 + Release-прогон, license-check).

## M2 — Архивы, SFTP, закладки

### T-20. Journal + undo (F-6)
- **Файлы:** FileOpsKit/JournalStorage.swift; ⌘Z-интеграция.
- **Готово:** критерии F-6; кольцевой буфер 20; частичные undo-диалоги.
- **Уточнение (по ходу реализации T-20):** (1) SDD раньше кода: `05` §5.6 уточнение T-20 — `TransferOpKind` +`mkdir` (journal-only), undo по последней записи: `JournalStorage.popLast()` → `UndoPlanner.plan(record, source:destination:)`; план nil → App «undo недоступен» + re-append записи; pop до исполнения = lossy при отмене в конфлике-диалоге; `06` §6.2 уточнение (UndoPlanner, `.undo` ⌘Z global, `menu.operations` → «menu.undo», mkdir-journal append-ит App); `02` F-6 v1-сноска («список 20» = ring-буфер T-10, без отдельного окна истории; частичный undo = существующие конфликты-диалоги с apply-to-all). (2) `FileOpsKit/UndoPlanner.swift`: план по НЕРАВНОМУ reversal записи; renameBack/restoreFromTrash → reverseMovePlan — план `.move` из `from` на `to` (переименование в тот же каталог planMove не умеет — план строится руками, как в F-4), конфликт `targetExists` сеется как у `TransferPlanner.expand` → App показывает обычный ConflictDialog; deleteCreated → `TransferPlanner.planDelete(sources:destination:)`. Trash-сторона: `VFSPath(root: source.id, components: `VFSPath.normalizedComponents(from: trashURL)`, displayURL: trashURL) — воркспейс root=«/» резолвит реальный trash-путь (урок T-16), `localPair` читает displayURL, а недоступную метадату подставляет stubItem (FileManager-stat по настоящему URL). (3) App wiring: `router.register(.undo)` → `undoLastJournalRecord()` (popLast → план → nil ⇒ re-append + NSAlert `undo.unavailable`; конфлики-диалог при plan.conflicts; enqueue + showProgress); mkdir-journal — в command-bar `case .mkdir`: `createDirectory` возвращает VFSPath → `JournalRecord(.mkdir, [.deleteCreated])`; executor `case .mkdir` — отказ `vfsUnsupported` (зеркало `.link`); keymap ×2 — `{command: undo, context: global, keyCode 6, command}` после openSettings (эквивалент ⌘Z в меню рисует существующий `keyEquivalent` case 6). (4) Тесты `ju` ×6 (`UndoPlannerTests`): renameBack-undo восстанавливает имя, copy→deleteCreated-undo удаляет только созданную копию, trash→restoreFromTrash-undo (реальная корзина, чистка trashURL), permanent-delete → план nil (пустой reversals), renameBack на занятую цель → конфликт `targetExists`, mkdir-план — отказ ×1 без записи в журнал. Гейты: build без warning, 215 тестов ×2 Debug + Release-прогон, license-check — зелёные.

### T-21. ArchiveVFS: чтение (zip/tar/gz/xz/bz2)
- **Файлы:** ArchiveVFS.swift, ZipReader/TarReader; реестр; открытие по Enter.
- **Готово:** критерии F-12 (read); path-traversal блок; тесты на golden-архив.
- **Уточнение (по ходу реализации T-21):** (1) зависимости N-10: NOTICE-таблица (`weichsel/ZIPFoundation` 0.9.20, `tsolomko/SWCompression` 4.9.1, транзитивный `tsolomko/BitByteData` 2.1.0 — все MIT) + Package.swift `dependencies`; уроки чекаутов: SWCompression `TarReader` eager-материалзит entry → написан СОБСТВЕННЫЙ стрим-ридер `VFSKit/TarScan.swift` по 512-байтным заголовкам поверх FileHandle (ustar name+prefix, PAX «path»/«size», GNU «L»/«K», typeflag 0·\0·7/5/2/1·3·4·6-skip, base-256 числа, «два ноль-блока» EOF, dataOffset; RAM O(1)); gz/xz/bz2 — full-Data SWCompression на mount (RAM-лимит «контейнер ≤ RAM» честно в 06 §6.4). (2) `VFSKit/ArchiveVFS.swift`: read-only capabilities (canRandomSeek=true), индекс при mount `[VFSPath-компоненты → Node]`, авто-синтез предков-dir, лениве per-entry извлечение в `…/extract/<FNV-1a specID>/` с `.mc-partial`→rename, `ArchiveByteStream` (FileHandle+lock, ByteStreamSeekable); zip — ZIPFoundation (архив-инстанс хранится; extract не thread-safe → ioLock; legacy CP866 — контейнерная опция `pathEncoding` через `entry.path(using:)`, `entry.path` всегда UTF-8/CP437); fileIdentity path:size:mtime. (3) `VFSKit/VFSRegistry.swift`: `mountArchive(reading:)` идемпотентно (повтор той же пары путь:size:mtime → тот же инстанс), VLAN-очистка extract-root при launch, FIFO ≤64 с чисткой кэша; `05` §5.3 уточнено — `instance(for:) -> (any VFS)?` (nil = не зарегистрирован), сервисные планы — те же. (4) UI-интерлюдия (06 §6.1/§6.4): `PanelViewModel.openEntryHandler: (VFSItem) async -> Bool` (consume-контракт: true = открыт) на ВСЕХ VM фабрики App + `onRootExit` (⌘↑-at-root → rebind хоста); `PanelTabList.swapActiveTabViewModel(_:)` (unwire старого VM: watch+gate+callbacks, id/lock сохранены, история заново, lastRecordedPaths reset), `PanelViewController.swapActiveTabViewModel` + refresh, `PanelTab.title` — displayURL-фолбэк для корня архива; App: `archiveRegistry = VFSRegistry()`, `openEntryAsArchive` (mount → interlude-VM → openDirectory(root с displayURL) → swap), `exitArchiveInterlude` — проверка identity `fileListView.viewModel ===` перед rebind (повторный exit — no-op); watchEngine на архив-VM — «мёртвый» пустой поток (canWatch=false). Nested-архивы (entry-in-archive) v1 не монтируются (отказ false — прежнее поведение). (5) Тесты `ArchiveVFSTests` ×16: zip-golden (ZIPFoundation create), tar-golden (TarContainer ustar), tgz (GzipArchive.archive), tar.xz/PAX/GNU golden-фикстуры (`Tests/Fixtures/` python-генерация, README-провенанс), traversal-тар («../» drop, «a/../» clamp, кэш без artifacts), single gz/bz2/xz, CP866-зип (ручная сборка CD/LFH/EOCD —(LocalHeaderOffset=0!)), read-only отказы ×5 + vfsNotFound/vfsUnsupported пустой контейнер, registry-идемпотентность. Гейты: build без warning, 231 тестов ×2 Debug + Release, license-check — зелёные. Известные v1-рамки: targ panels-session restore открывает пустую вкладку (F-2 продолжение — v1.x), 7z — v1.0 SHOULD.

### T-22. Pack zip + extract-все
- **Файлы:** Archive/ZipWriter; диалог Pack; интеграция queue.
- **Готово:** упаковка выбранных → zip (уровень/опции); прогресс; перенос в очередь.
- **Уточнение (по ходу реализации T-22):** (1) SDD раньше кода: `05` §5.6 уточнение T-22 — `TransferOpKind` +`packZip` (исполняемый case с журналом): один план = ОДИН zip-артефакт, `items[i].source` — топовые источники выделения, `items[i].target` у всех ОДИН (путь зипа), конфликт `targetExists` ровно один на план (seed = sources.first); `06` §6.2 уточнение (Pack-flow: destination LocalVFS-only v1 → `.vfsUnsupported` иначе; staging `.<name>.mc-partial` → fsync → rename idem CopyTransaction; LocalVFS-источники — `addEntry(fileURL:)` напрямую, не-локальные — материалазизация через `openRead` (1 MB чанки) во временное temp-поддерево → `addTree`; имена entry — только `VFSItem.name`; symlinks опускаются по 06 §6.4; JournalRecord `.packZip` → reversal `deleteCreated`); `02` F-12 сноска (pack = zip-only; «уровень сжатия» ZIPFoundation не выставляет — диалог честно предлагает МЕТОД store/deflate; «extract-все» = обычный copy-план F-5 из ArchiveVFS — исполняется очередью T-10); `11` layout — `ZipPack.swift`, `UndoPlanner.swift`. (2) `FileOpsKit/ZipPack.swift`: `ZipPackPlanner.planPack(sources:into:zipName:source:destination:compression:progress:)` (guard пустого выделения `noSources`; guard дерева-цели — `TransferPlannerError.targetNotADirectory`); `ZipPackTask.pack` — staging-протокол, `ConsumedBytes` (@unchecked Sendable NSLock — класс-счётчик байт, шарится с sync-фазой addTree); прогресс — ЛИШЬ на ГРАНИЦАХ entry (ZIPFoundation addEntry пишет только totalUnitCount, per-chunk callback отсутствует → честный фикс v1 в `05`); отмена — между entry (addEntry не проверяет cancel — v1 честно, staged temp удаляется); Рекурсия: addEntry НЕ рекурсирует в каталоги (свой addTree). (3) Executor: ветка `case .packZip` → `executePackZip` (без воркер-пула; resolveConflicts по items[0]; method `.store→.none`/`.deflate`; урок Sendable: замыкание прогресса захватывает `runID`-копию, НЕ `run` — `Run` не-Sendable). (4) DomainKit: `ZipPackCompression` (store/deflate, Codable) + `ZipPackSpec` в `TransferPlan.zipPack`. (5) App-интеграция: `CommandID` +`packFiles`; `MenuBuilder` `menu.packFiles` (Operations); `PanelsCoordinator.beginPackSelection()` (выделение активной панели → паковка в текущий каталог ПРОТИВОПОЛОЖНОЙ панели; guard destination не-LocalVFS → NSAlert `pack.onlyLocalDestination`; defaultName = одиночный источник — `name.zip`, иначе `pack.defaultName`; `PackDialog.run(defaultName:)` modal → `executePack` (planPack → ConflictDialog → enqueue → showProgress). (6) `ListViewKit/PackDialog.swift`: PackDialogController (name field + compression popup `pack.compression.deflate/store`, buildChoice чист) — уроки: NSWindow StyleMask `.modalPanel` отсутствует в Swift 6/AppKit → только `.titled`; `panel.fileListView.viewModel` НЕ-Optional (guard-let запрещён). (7) Тесты `ZipPackTests` ×8: round-trip (файл+дерево → zip → ArchiveVFS listDirectory/openRead), store (entry.isCompressed=false)/deflate(true), overwrite (junk заменён валидным), keepBoth (`bundle(1).zip` авто-суффикс, оригинал нетронут), skip (skippedItems=1, без суффикса), pack-из-архив-панели (материализация openRead → picked.zip с тем же контентом), pauseThenCancel (canceled=true, зипа нет), plannerRefusesFileTarget. UndoPlanner обрабатывает `.packZip` автоматически (switch по reversal `deleteCreated`, op-агностичен). (8) Гейты: build 0 warning; 239 тестов (8 новых × ZipPack) Debug ×5 прогонов зелёные (flaky 1 issue в первом прогоне — не воспроизвелся), Release прогон зелёный; license-check OK (новых зависимостей не понадобилось — ZIPFoundation уже в NOTICE с T-21). (9) v1-рамки: destination только LocalVFS, отмена на границах entry, прогресс на границах entry, без dial «уровня сжатия» — зафиксировано в `05`/`06`/`02`.

### T-23. SftpVFS: ядро
- **Файлы:** Sftp/SftpVFS.swift, SftpConnection.swift на Citadel; errno-маппинг.
- **Готово:** все 5.3-операции на живом SFTP-тест-сервере CI; resume offset; числа статов.
- **Уточнение (по ходу реализации T-23):** (1) SDD раньше кода: `06` §6.5 уточнение T-23 — lifetime (connect → auth → ОДИН SFTPClient на соединение), errno-маппинг (noSuchFile→vfsNotFound, permissionDenied→vfsAccessDenied, failure/badMessage/unknown→network, noConnection/connectionLost/connectionClosed/missingResponse→interrupted), пути = компоненты АБСОЛЮТНОГО SFTP-пути (панель стартует с `realpath(".")`), чтение offset-базовое (ByteStreamSeekable, чанк ≤32 KB — пакет-лимит swift-nio-ssh #99), запись — staging `.<name>.mc-partial` → finish → rename, delete — bottom-up рекурсией (SFTP не имеет rm -r; toTrash = прямое удаление), capabilities (canWatch=false, canRandomSeek=true, symlinkSupport=false, preservesDates=false); `05` §5.3 уточнение; `11` layout +`Sftp/SftpVFS.swift`. (2) зависимости N-10: NOTICE — Citadel 0.12.1 (MIT; **пинит форк `Wellz26/swift-nio-ssh` 0.3.x** (Apache-2.0) вместо замороженного apple/swift-nio-ssh — supply-chain риск отмечен), apple/swift-nio, swift-log, attaswift/BigInt, swift-crypto (+BoringSSL), ColorizeSwift, транзитивы swift-asn1/atomics/collections/system; Package.swift — прямые deps Citadel + swift-nio + Wellz26/swift-nio-ssh; урок: byName НЕ резолвит продукты чужих пакетов (NIOConcurrencyHelpers/NIOSSH) → `dependency(named:)` с явными `.product(name:package:)`. (3) `SftpConnection`: `SftpConnectionConfig` (auth `.password`/`.ed25519`; hostKeyValidator — policy-параметр, pinning/fingerprint-UI — T-24; reconnect `.never` — backoff — T-25); класс `@unchecked Sendable` (SSHClient Citadel не Sendable, SFTPClient — Sendable). (4) `SftpVFS`: listDirectory (фильтр «.»/«..»), metadata (stat), directorySize — рекурсия с ProgressSink, mkdir/rename/delete, openRead — `SftpByteStream` (cursor + seek через offset-read), openWrite — staging + `finish`: conflict-check через getAttributes (replace=false → `transferConflict`; replace=true → pre-remove final, т.к. SFTP_RENAME v3 не overwrite), setAttributes — type-bits mode сохраняются; copyContents — default §5.3 (server-side copy — v1.x). (5) уроки Swift 6: `NSLock.lock()` недоступен из async-контекстов → `NIOLockedValueBox` (продукт `NIOConcurrencyHelpers` swift-nio). (6) **урок Citadel-сервера: inbound-handler ГЛОТАЕТ throw-ы делегата для stat-family БЕЗ ответа** (клиент висит бесконечно; file-операции — закрывают канал) → тест-fixture для отсутствующих путей отдаёт attribute-less метадату, errno-маппинг покрыт юнит-тестом маппера (`SFTPMessage.Status` без public init → маппер сделан код-базированным public `map(_ code:path:)`); на реальных серверах (OpenSSH) статусы приходят штатно — задокументировано в `06`. (7) Live-стенд: in-process `SSHServer.host` + `enableSFTP(SFFileSystemDelegate)` поверх temp-dir (remote «/» = temp), auth password «citadel»/«test», host keys ed25519 per-test, порт BSD-probe; клиент `.trustedKeys([hostKey.publicKey])` — полный SSH/SFTP handshake по loopback TCP, без внешних зависимостей CI. (8) Тесты ×12: list/meta/mkdir+rename/delete-file+tree/openRead+length/seekable/write-publish+replace=false-conflict/replace=true/dirSize+progress/hostKey-pinning-отказ/foreign-instance-отказ/errno-маппер; итог 251 (12 новых). (9) Гейты: Debug ×2 + Release — 251 зелёные, license-check OK (13 пакетов). (10) v1-рамки: idle-KA/backoff/таймауты — T-25; pinning-UI — T-24; server-side copy — v1.x; symlink-target не резолвится (kind виден).

### T-24. ConnectionStore + Keychain + UI подключений
- **Файлы:** ServicesKit/ConnectionStore ↔ KeychainBridge; Connections-панель (SwiftUI).
- **Готово:** критерии F-13 (host-key pinning; fingerprint change → красный экран).
- **Уточнение (по ходу реализации T-24):** (1) SDD раньше кода: `06` §6.5 уточнение T-24 — HostKeyPolicy (`NIOSSHClientServerAuthenticationDelegate` через `SSHHostKeyValidator.custom` — единственная точка интеграции в Citadel), fingerprint = SHA-256 по wire-формату ключа (`NIOSSHPublicKey.write(to:)`), отображение `SHA256:<base64 nopad>`; поток: match → succeed молча, нет пина → `.firstUse` → async decision-handler (App — NSAlert accept/abort, accept → `pinHostKey`), чужой пин → `.changed(old, new)` → handler (App — красный `NSAlert.critical` MITM; decline → `HostKeyRejectedError` → handshake рвётся); fail-closed без handler'а; приватные ключи — v1 только Ed25519 в незашифрованном OpenSSH-контейнере (bcrypt-KDF/PEM → понятная `MCError.vfsUnsupported`; passphraseRef — задел v1.x). (2) `06` §6.9 уточнение: ConnectionsSnapshot schemaVersion 1 (чужая версия → файл игнорируется), секретов в JSON нет никогда — keychainRef = UUID записи; Keychain: `KeychainStoring` протокол (test seam) + `KeychainBridge` (kSecClassGenericPassword, service `MyCommander.connection.<id>`, account `secret`/`passphrase`, delete-then-add как update); CRUD: save (insert-or-update JSON)/delete (чистит оба keychain-записи)/password/passphrase/pinHostKey/clearHostKeyPin. (3) `05` §5.7 уточнение: `AuthMethod` = `.password(keychainRef)` / `.privateKey(path, passphraseRef)`, `kind` = enum с единственным `.sftp`. (4) App: ConnectionsWindowController — AppKit (НЕ SwiftUI: `NSHostingView` не нужен, стиль SettingsWindowController — NSStackView-форма: список + name/host/port/username/auth-popup/password+key-path+passphrase, Add/Delete/Save/Connect; секреты не эхо-бэкятся); меню Go → `menu.connectSftp` → `CommandID.connectSftp`; PanelsCoordinator: `connectSftp(record:)` — secret/key из store → `SftpConnection` → `SftpVFS` → registry.register → interlude-VM на активной вкладке по образцу T-21 (`swapActiveTabViewModel` + `onRootExit` ⌘↑ назад к host-VM; watch на SFTP-пути — finished stream по контракту §5.4). (5) уроки: `EventLoopFuture.get()` в swift-nio 2.104 — **async throws** (не sync); `#expect(!await f())` не парсится → `#expect(!(await f()))`; index-based removeSubrange после первой мутации невалиден (armor-парсер → переписан на фильтрацию состоянием); Ed25519-контейнер: 64-байтная private-строка = seed(32) || pub(32) (не seed==pub!); захват изменяемых локалов в @Sendable decision-handler → lock-box в тестах. (6) Package.swift урок: ОДНО ребро product на пакет — NIOSSH в moduleDependencyNames["VFSKit"] покрывает и тесты (extra = module deps + test deps); дубль module+test ссылок на один product → SPM-warning «ignoring duplicate product» (гейт = 0 warnings). (7) Тесты ×20: ConnectionStoreTests ×7 (CRUD, секрет-не-в-JSON, pin round-trip, foreign-schema, missing-file, service-name-контракт, env-gated `MC_KEYCHAIN_SMOKE=1` реальный Keychain), HostKeyPolicyTests ×9 (fingerprint формат/стабильность, policy-матрица на EmbeddedEventLoop-promise: match/нет пина+нет handler/чужой пин/firstUse accept+decline/changed carrying+decline; live pin-flow ×2: first-use accept → reconnect с пином без handler'а; stale-пин → changed → decline → connect падает), SftpPrivateKeyTests ×4 (реальный ssh-keygen-фикстур (ed25519, «mc-fixture»), чужой armor, битый body, обрезанный контейнер); fixture вынесен в `SftpTestSupport.swift` (internal, shared). (8) Гейты: Debug ×2 + Release — 271 зелёные, license-check OK. (9) v1-рамки: RSA/ECDSA-ключи клиентов и зашифрованные ключи — v1.x (issue); RSA/ECDSA host keys — пининг работает (fingerprint не зависит от алгоритма); закрытие SFTP-соединения при выходе из interlude — v1.x; восстановление SFTP-вкладок из сессии — v1.x.

### T-25. SFTP robustness
- **Цель:** reconnect/backoff, отмена, таймауты.
- **Готово:** сценарий «перерубить сеть» восстанавливается; idle-KA; panel shows «Reconnect…».
- **Уточнение (по ходу реализации T-25):** (1) SDD раньше кода: `06` §6.5 уточнение T-25 — **supervisor в SftpConnection**: idle-KA = SFTP-проба `getRealPath(".")` каждые 30 с (**Citadel 0.12.1 НЕ экспонирует SSH-level keepalive** — grep по пакету пуст); reconnect backoff 1/2/4/8 с **max 5 попыток** (расписание `[1,2,4,8,8]` — конфигурируемо в `SftpConnectionConfig` для тестов), после — `.failed` (панель: ошибка «connection lost — reconnect failed»; кнопка ручного reconnect — v1.x); состояния `.connected` / `.reconnecting(attempt:nextDelay:)` / `.failed` публикуются через `setOnStateChange` (fan-out callback, не AsyncStream); `connectTimeout` = 10 с (Citadel `SSHClient.connect`). (2) **Отмена** («мгновенный close-channel»): cooperative cancellation на границах чанков — `SftpByteStream.readChunk` / `SftpStreamWriter.write` при `Task.isCancelled` немедленно закрывают SFTP-хэндл и бросают `.canceled`; рекурсивные deleteTree/walkSize проверяют отмену на каждом узле; staged `.mc-partial` остаётся (06 §6.2). (3) Handles ушли в `NIOLockedValueBox<Handles?>` (SSHClient не-Sendable); `currentClient()` бросает `.interrupted` при закрытом соединении (вместо force-unwrap); reconnect: establish fresh → teardown старого → swap → `.connected` → снова supervise. (4) App: `PanelsCoordinator.handleSftpState` — `.reconnecting`/`.failed` → `viewModel.onError` (status line), `.connected` → `viewModel.reload()` (watch-канала у SFTP нет — callback и есть refresh). (5) **Тест-стенд T-25: TCP-прокси** (`SFProxy`, NIOPosix, `SFPipeHandler` peer-forwarding) — клиент ходит через прокси, `pullCable()` рвёт обе стороны живых пайпов, сервер жив → reconnect на тот же адрес/ключ честно моделирует обрыв сети. **Урок: `SSHServer.close()` НЕ рвёт активные клиентские сессии** (только listener) — первый вариант fixture.restart() соединение «переживало» (ловля debug-тестом с печатью состояний); SSHContext не содержит Channel — kill-switch из делегата невозможен. (6) Тесты ×6: backoff-расписание (capped), live cable-pull reconnect (`.reconnecting` → `.connected` → VFS работает), live KA-пробы (счётчик realPath на сервер-делегате), live исчерпание → `.failed`, live отмена write (gate-паттерн: child ждёт AsyncStream-gate, родитель cancel до release — детерминированно), live отмена read. EventBox переехал в SftpTestSupport (internal). (7) NIOPosix — тест-only dep (+ product-map). (8) Гейты: Debug ×2 + Release — 277 зелёные, license-check OK. (9) v1-рамки: «Reconnect» кнопка и пауза resume offset — v1.x; строки статуса — из MCError.errorDescription (DomainKit), без отдельных Localizable-ключей (каталог отсутствует — ключи проходят насквозь); KA-проба заметна серверу как обычный stat-трафик.

### T-26. LocationsStore: закладки/история/hotlist
- **Цель:** F-11.
- **Готово:** критерии F-11 (⌘D; Alt-слоты; back/forward per tab).
- **Уточнение (по ходу реализации T-26):** (1) SDD раньше кода: `06` §6.9 уточнение T-26 + `05` §5.7 — `LocationTarget` enum (`.path(VFSPath)` / `.connection(UUID)`) как реализация контракта `Either<VFSPath, ConnectionID>`; `LocationSide` (`.left`/`.right`) — без зависимости от ListViewKit; `LocationsSnapshot` schemaVersion 1 (`bookmarks` + `recentFolders`, чужая версия → файл игнорируется). (2) **LocationsStore** (`locations.json`): bookmark CRUD (`addBookmark` ⌘D — без слота), hotlist 9 слотов — эксклюзивность (новый владелец вытесняет старого), clearHotSlot, out-of-range игнорируется; недавние — `noteVisit` dedupe move-to-front, кольцо 20. (3) **Back/forward per tab** — механизм уже был (T-08 `PanelTabList.navigateBack/Forward`), T-26 добавляет команды `navigateBack`/`navigateForward` (⌘[ / ⌘]) и меню. (4) ListViewKit: `PanelTabList.onPathVisited` — срабатывает на КАЖДОЕ отображённое место (до suppress-gate истории — replay тоже визит); источник «недавних» (App вешает noteVisit на оба таб-листа). (5) Меню: секция Locations (Add Bookmark ⌘D / Locations… ⌘⇧L / Back ⌘[ / Forward ⌘] + 9 слотов с живыми именами «[N] name»); `MenuBuilder.build(router:keymap:locations:)` + `PanelsCoordinator.rebuildMenu()` (пересборка после add/assign — слоты в меню обновляются); `makeItem` вынесен из цикла. (6) **LocationsWindowController** (AppKit, стиль Connections): закладки + недавние, Go (target навигация), slot-popup (assign/clear), Delete; `.connection`-target идёт через существующий SFTP-connect-flow. (7) Keymap-дефолты (JSON-ресурсы): ⌘D/⌘[/⌘]/⌘⇧L в обоих профилях; tc — ⌥F1..F9 слоты, macos — ⌥⌘1..9 (конфликт-скан JSON — чисто); `keyEquivalent(for:)` дополнен F1/F2/F9/[/]. (8) Тесты ×7: LocationsStoreTests ×6 (CRUD, эксклюзивность слотов + clear + out-of-range, недавние dedupe/cap, персист между инстансами, foreign-schema, missing-file), PanelTabsTests +1 (onPathVisited: seed → beta → replay back = 3 визита; урок: seed-локация НЕ создаёт back-запись — история с nil→alpha пуста). (9) Гейты: Debug ×2 + Release — 284 зелёные, license-check OK. (10) v1-рамки: модиал Alt+двойная буква и опция «замок локации» — v1.x; редактирование имени закладки — v1.x (окно без rename); drag-and-drop в слоты — v1.x.

### T-27. M2 hardening
- **Готово:** smoke 8.4 п.6–7; все VFS-операции через unified queue-путь; exit M2.
- **Уточнение (по ходу реализации T-27):** (1) SDD раньше кода: `09` M2 exit п.1
  уточнение — трактовка «все VFS-операции через один queue/conflicts-путь» =
  transfer-класс (copy/move/delete/packZip/extract/undo-reversals) через ЕДИНЫЙ
  OperationExecutor; mkdir — задокументированное исключение (§5.6 T-20); `08` §8.4
  уточнение — автоматизируемые ядра п.6–7; **`05` §5.6 уточнение T-27 — КЛЮЧЕВАЯ
  правка**: `enqueue(plan, policy, source:, destination:)` — **per-run VFS-пара**
  (`nil` = init-дефолт workspace). Мотивация найдена НА ДЕЛЕ: App держит ОДИН
  executor с workspace-парой из init — copy/delete из SFTP/архивной панели
  физически исполнялись через workspace `LocalVFS` (delete → `sourceVanished` на
  SFTP-пути, copy → byteStream по чужому VFS). Единый путь работает для ЛЮБЫХ
  панелей только с per-run парой: все ветки (`executeItems`/`executeMove`/
  `executeDelete`/`executePackZip`, runtime re-check, `resolveConflicts`) читают
  пару из `Run`. (2) App: `executeTransfer`/`executePack` передают пару операции;
  delete — пару панели; undo остаётся на workspace-дефолте (реверсалы F-6 v1 —
  локальные). (3) Тесты ×4 (`UnifiedQueueIntegrationTests`, VFSKitTests +
  test-dep FileOpsKit): allTransferClassesRideOneExecutor (copy→move→delete→packZip
  одним executor'ом с per-run парами, journal = [packZip, delete, move, copy]);
  localToSftpCopyAndBackThroughExecutor (upload+copy-back, live-сервер);
  zipRoundTripThroughUnifiedPathSurvivesUnicodeNames (pack→ArchiveVFS→extract,
  «Привет мир»/«emoji 🚀»/«каталог с ёлкой» — имена и байты целы);
  sftpCopyPreservesUnicodeNames. (4) Уроки теста: два `LocalVFS(at:)` без явного
  `instanceID` получают ОДИНАКОВЫЙ specID «unknown» → same-VFS-семантика ложно
  (copy в тот же каталог → keepBoth `a(1).txt`, move в чужой каталог лёг по
  source-корню) — в тестах явные `instanceID`; `packZip` summary = 1 succeeded
  (ОДИН артефакт, не per-source); `uqTempRoot` обязан создавать каталог (планнер
  статирует цель). (5) Гейты: Debug ×2 + Release — 288 зелёных, license-check OK.
  (6) Ручной остаток smoke п.6–7 (UI-диалоги, «потушить Wi-Fi» на живом сервере) —
  владелец при выпуске M2-сборки; exit M2 фиксируется этим блоком.

## M3 — Power tools

### T-28. RenamePlanner + диалог multi-rename (F-14)
- **Готово:** RenameRule + RenamePlanner (EnginesKit), MultiRenameDialog (ListViewKit), команда ⌘M / tc ⇧F2, commit через unified queue; undo F-6.
- **Уточнение (по ходу реализации T-28):** (1) SDD раньше кода: `06` §6.6
  уточнение T-28 — RenameRule (template-токены `[N]`/`[C]`/`[E]`, counter
  start/step/pad, find/replacement/isRegex, caseStyle, extensionMode
  keep/replace/remove; расширение = суффикс после ПОСЛЕДНЕЙ точки, каталоги
  переименовываются целиком — расширения не имеют; шаблон — единственный источник
  формы нового имени), RenamePlan (pairs + conflicts: `duplicateTarget` = совпадение
  с другим результатом плана, `targetExists` = имя занято ЧУЖИМ файлом —
  «переименование в имя планируемого соседа» (swap-цепочка) конфликтом НЕ является,
  `invalidName`: пусто/`/`/`.`/`..`); unchanged-пары (new == old) в план не
  попадают; commit = ОДИН план `.move` (same-volume rename(2), journal
  `renameBack` → undo F-6 бесплатно) через per-run пару unified queue (05 §5.6
  T-27); сортировка плана стабильна по old-name — только для стабильности
  ИСПОЛНЕНИЯ, счётчик едет в порядке выделения. Бюджет: план 10k имён ≤ 1 с
  (замер 0.08 с). `11` layout: +`RenameRule.swift`. (2) Код:
  `EnginesKit/RenameRule.swift` (ручной Codable — associated value у
  extensionMode), `EnginesKit/RenamePlanner.swift` (pure, без I/O — preview
  зовётся на каждый keystroke), `ListViewKit/MultiRenameDialog.swift` (AppKit
  NSPanel по образцу PackDialog: live-preview, конфликты красным, Apply
  disabled при конфликтах/пустом плане; Cancel = отмена до commit; preview =
  сухой прогон), App `beginMultiRename` (per-run пара панели, stream
  потребляется, reload после finished), MenuBuilder `menu.multiRename`,
  keymap tc ⇧F2 / macos ⌘M (конфликт-скан чист: 64/66 entries). (3) Тесты:
  юнит ×13 (`EnginesKitTests/RenamePlannerTests.swift`: токены, pad,
  literal-duplicate, replace/case, regex, ext keep/replace/remove, каталоги,
  unchanged, targetExists-foreign, invalidName, commit-план, 10k-бюджет) +
  интеграция `multiRenameThroughUnifiedQueue` (VFSKitTests, test-dep +EnginesKit):
  план `.move` через единый executor с per-run парой, каталог после = точное
  множество новых имён. (4) Уроки: кортежи/`[(a,b)]` не Equatable в `#expect` →
  `[[String]]`; `VFSItemKind` имеет associated value (не Equatable) →
  `if case .directory`; `NSButton(checkboxWithTitle:)` требует
  target:/action: в stored property; **journal у move — PER ITEM** (одна запись
  `.move` с ОДНИМ `renameBack` на файл, не одна запись на план) — undo-приёмка
  в тестах: слить все `popLast()`-записи и сверить объединение реверсалов
  (undo bottom-up разворачивает их корректно); счётчик rename — порядок
  выделения, НЕ сортировка (в тестах детерминированный порядок выборки).
  (5) Гейты: build 0 warnings; Debug ×2 + Release — 302 зелёных; license-check OK.
### T-29. SyncReporter + dry-run UI (F-15)
- **Готово:** SyncReporter (дифф-матрица + action-script), HashCache (sqlite), SyncDialog, команда ⌘B; исполнение через unified queue.
- **Уточнение (по ходу реализации T-29):** (1) SDD раньше кода: `06` §6.6
  уточнение T-29 — SyncReporter.compare(a:at:b:at:mode:cache:) — рекурсивный
  обход обоих деревьев (стороны параллельно; хэширование — пул workers ≤ 4),
  карта по ОТНОСИТЕЛЬНОМУ пути, матрица onlyA/onlyB/differing/equal; каталоги:
  наличие с обеих сторон = equal (расхождение типа = differing); режимы
  `.metadata` (size точно, mtime с допуском 1 с; nil-mtime → только size) и
  `.content` (SHA-256 стримом только для metadata-equal файлов — differing по
  метаданным не хэшируется); HashCache — системный sqlite3, ключ
  instance+path, инваллидация по mtime/size; action-script: direction
  aToB/bToA + mirror (delete лишнего на стороне ПРИЁМНИКА), equal без
  действий, каталог в скрипте покрывает поддерево (потомки не дублируются);
  dry-run по умолчанию: таблица «действие → путь» = лог, Apply только после
  подтверждающего NSAlert; исполнение — App строит планы через
  TransferPlanner (mkdir -p уже в планере, T-11) и ведёт через unified queue
  с per-run парами панелей (05 §5.6 T-27), policy copy = .overwrite
  (sync-семантика, покрыта подтверждением). Бюджет: дифф 100k записей ≤ 3 с.
  (2) Код: `EnginesKit/SyncReporter.swift` (pure), `EnginesKit/HashCache.swift`
  (sqlite3 через системный модуль SQLite3; SQLITE_TRANSIENT не экспонируется
  оверлеем → unsafeBitCast(OpaquePointer(bitPattern: -1)) локально),
  `ListViewKit/SyncDialog.swift` (direction popup + mirror checkbox, скрипт
  пересчитывается live, delete-строки красным, Apply = NSAlert-подтверждение),
  App `beginComparePanels` (дифф off-main → диалог → копии одним планом
  per-direction, затем mirror-удаления, reload обеих панелей),
  MenuBuilder `menu.comparePanels`, keymap ⌘B в обоих профилях (конфликт-скан
  чист: 65/67 entries). Package.swift: EnginesKit linkerSettings
  `.linkedLibrary("sqlite3")` — СИСТЕМНАЯ библиотека (как и CryptoKit), НЕ
  сторонняя зависимость → NOTICE не трогается (правило N-10). (3) Тесты
  ×11 (`EnginesKitTests/SyncReporterTests.swift` + мини-фейк SyncFakeVFS):
  identical/disjoint, size+mtime (допуск 1 с), type-mismatch, content ловит
  равные метаданные/разные байты, кэш (второй проход не хэширует — счётчик
  openRead), направление скрипта, mirror-удаления (поддерево каталога не
  дублируется), потомки скопированного каталога пропускаются, инваллидация
  кэша по mtime/size, perf 100k ≤ 3 с (замер 1.87 с). (4) Уроки: switch по
  кортежам опционалов — паттерны `(.some, .none)` (binding `let a?` даёт
  warning «never used»); фейк-VFS для EnginesKitTests — 9 методов протокола
  VFS, счётчик openRead под NSLock (worker pool пишет из нескольких тасок);
  ожидания порядка скрипта = отсортированный порядок записей отчёта.
  (5) Гейты: build 0 warnings; Debug ×2 + Release — 313 зелёных;
  license-check OK.
### T-30. SearchEngine + результаты-виртуальная папка (F-16)
- **Готово:** ByteScan (content-скан), SearchEngine (фильтры + limiter + отмена), NSMetadataQueryBridge (Spotlight-first), SearchResultVFS (виртуальная папка), SearchDialog, команда ⌘F; «в панель».
- **Уточнение (по ходу реализации T-30):** (1) SDD раньше кода: `05` §5.1 —
  `VFSKind` + `searchResults`; `06` §6.6 уточнение T-30 — SearchQuery
  (nameMask/содержимое lit/regex/регистр/мин-макс размер/даты/maxFileSize
  [лимит content-скана; больше — только name]/resultLimit), SearchHit
  (contentMatches nil = только имя), обычный путь = рекурсивный обход с
  мгновенной отменой (/per-directory, /per-chunk); **Spotlight-first** —
  predicate (kMDItemFSName LIKE/kMDItemFSSize/kMDItemFSContentChangeDate),
  кандидаты ревалидируются теми же проверками; ноль кандидатов/ошибка →
  fallback обхода (корректность важнее скорости); ByteScan — СТРОЧНО по окнам
  8 MB (литеральный needle или NSRegularExpression; частичная последняя строка
  переносится в следующее окно — не рвёт совпадения); SearchResultVFS —
  read-only: listDirectory сплющивает hits в ОДИН каталог (id = [index, name] —
  имена дублируются), openRead/metadata ДЕЛЕГИРУЮТ в VFS-источник (F-3/F-5
  работают через дефолтный copyContents), запись/удаление → vfsUnsupported;
  «отправить в панель» = PanelViewModel + swap (модель T-25). (2) КЛЮЧЕВАЯ
  находка слоёв: LocalVFS в VFSKit, а VFSKit не зависит от EnginesKit в проде
  (обратное ребро запрещено 04) → seam-протокол `SpotlightSearchable`
  (EnginesKit: `url(for:)`), конформанс `extension LocalVFS: SpotlightSearchable {}`
  в App (`App/SpotlightSeam.swift`); ТОТ ЖЕ package → `@retroactive` НЕ нужен
  (с ним Swift даёт ошибку «attribute does not apply; declared in the same
  package»). (3) Код: `EnginesKit/ByteScan.swift` (+SearchEngine.swift,
  NSMetadataQueryBridge.swift), `VFSKit/SearchResultVFS.swift`,
  `ListViewKit/SearchDialog.swift` (live-hits от detached-таски, отмена
  мгновенная, «В панель»), App `beginSearchFiles` (SearchResultVFS +
  swapActiveTabViewModel), MenuBuilder `menu.searchFiles`, keymap ⌘F (обе
  профили; конфликт-скан чист 66/68). (4) Уроки: NSMetadataQuery НЕ Sendable →
  изоляция в `@unchecked Sendable` State-box (NSLock) внутри
  withCheckedContinuation; свитч по кортежам опционалов — `(.some, .none)` —
  из урока T-29 применился снова; двигательная семантика: size-фильтр = только
  файлы (каталог приходит при size-фильтре → сомнительно), каталог + непустой
  content = НЕ хит; в тестах размеры строк считать по байтам точно
  («beta payload» = 12). (5) Гейты: build 0 warnings; Debug ×2 + Release —
  328 зелёных; license-check OK.
### T-31. TerminalPane встроенный (F-17): SwiftTerm, ⌃`, auto-cd, вставка путей
- **Готово:** TerminalPane (NSView-хост SwiftTerm `LocalProcessTerminalView`,
  login-zsh, кнопки CD/Вставить в верхней полоске, path-line), TerminalPathSeeder
  (чистое POSIX-экранирование — unit), ⌃` toggle + ⌃⇧V pastePath, авто-CD
  (debounce 150 мс), MenuBuilder/keymap обеих профилей, kill-shell на
  windowWillClose.
- **Уточнение (по ходу реализации T-31):** (1) SDD раньше кода: `06` §6.8
  уточнение T-31 — pane создаётся по требованию (первый ⌃`), child
  `/bin/zsh -l` стартует В нужном cwd (`startProcess(currentDirectory:)` —
  welcome-cd не нужен), детача окна стартует его ровно раз
  (`viewDidMoveToWindow`); child переживает скрытие панели, kill при закрытии
  окна БЕЗ подтверждения (v1). TerminalKitTests покрывает ТОЛЬКО сидер —
  SwiftTerm UI headless хрупко; ручной smoke (⌃` старт < 200 мс; tmux/vim
  без артефактов; cd-follow; вставка путей) — T-34 hardening (как в T-27).
  (2) LV-хук: `onPathChanged` каждой tab-VM занят PanelTabsView (history
  вкладок) — подписка авто-CD идёт через `PanelTabList.onPathVisited` (он и
  так служит recent-записям): оба потребителя сворачиваются в ОДИН closure
  координатора; фильтр корректности — cd летит только по пути, реально
  отображённому в одной из панелей (фоновая вкладка листит свой каталог БЕЗ
  cd терминала), re-check в момент срабатывания debounce; интерлюдии
  (root.kind ≠ localDisk) пропускаются. (3) Слои: машинерия терминала в
  App (PanelsCoordinator: toggleTerminal/pastePath/shutdownTerminal,
  lazy-pane + store `lastPanelPosix`), MainWindowController — только
  layout-сегмент (высота 0 → 40 % через пару constraints zero/open,
  isHidden-защёлка), TerminalKit — только SwiftTerm-хост + сидер (PTY
  получает строки ИСКЛЮЧИТЕЛЬНО из TerminalPathSeeder). pastePath: курсорный
  элемент активной панели, LocalVFS-only — честная ошибка в консоль для
  не-локальных источников. (4) **ld-ворнинги от dep-манифеста:** SwiftTerm
  заявляет сам `.macOS(.v11)` — его объекты драгают эффективный минимум
  финальных бинарников до 11.0, ld сверяет с системными swift-dylib (13.0)
  → «building for macOS-11.0, but linking … newer version 13.0» ×8 на
  КАЖДУЮ холодную релинковку. Решение: linkerSettings таргета TerminalKit —
  `.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos",
  "-Xlinker", "14.0", "-Xlinker", "14.0"])` (наш floor — Package platforms
  = .macOS(.v14)); linker-сеттинги таргета применяются к КАЖДОЙ линковке
  его consumers (executable + tests-runner). Склейка `-Wl,…` SwiftPM в
  unsafeFlags не пропускает — только `-Xlinker`-пары. (5) Транзитивные
  зависимости SwiftTerm (swift-argument-parser, swift-png, h — все
  Apache-2.0) ловятся license-check'ом при первом прогоне → NOTICE-строки
  сразу по образцу транзитивных NIO-dep'ов. (6) Перф-гейты T-06/T-07
  флейкят при параллельном прогоне под внешней нагрузкой (load ≥ 6 от
  посторонних процессов; 0.071–0.139 s против бюджетов 0.05/0.1 s); соло
  каждый проходит с ~3× запасом — гейт проходится ретрай-циклом с паузой.
- **Гейты:** build 0 warnings (верифицировано двумя холодными
  релинковками executable и tests-runner); Debug ×2 + Release — 335 зелёных
  (+7 TerminalPathSeederTests); license-check OK.
### T-32. Настройки полные + custom columns + thumbnails (F-21, F-4)
- **Готово:** SettingsSchema v1 additive-поля (`columns: [ColumnID]`,
  `filterStyleRaw`, `archiveAutoMount`, `terminalAutoCd`) + секции
  view/archive/terminal (reset по секциям); окно Settings — JSON-пресет
  колонок + filterStyle-popup; LV — 4 режима (⌃1 full / ⌃2 brief / ⌃3
  columns / ⌃4 thumbnails), custom-column рендер
  (dateCreated/permissions-octal/owner/tags/kind через MetaCell-статики),
  `applyColumnPreset` live из `onDidUpdate` (обе панели, name-first +
  gitStatus-отрезание до F-27), rowHeight 22/56; ThumbnailStore
  (QLThumbnailGenerator, lazy на видимых строках, NSCache ≤ 1000,
  fakeGenerator — тест-плацдарм, onThumbnailUpdated → reload строки по
  cacheKey); ThumbnailCell 40×40 в 56-строке + renderedKey-guard; App —
  router `.viewColumns/.viewThumbnails`, фильтр-стиль живёт в каждой VM
  вкладки (фабрика вкладок наследует из settings), openEntryAsArchive
  guard `archiveAutoMount`, followTerminalPath guard `terminalAutoCd`;
  LocalVFS заполняет `attributes.owner` из stat
  (`NSFileOwnerAccountName`); keymap ×2 (+4 entries: ⌃3/⌃4 global+panelList),
  меню View (+2), SettingsWindow (+3 секции, высота 540).
- **Уточнение (по ходу реализации T-32):** (1) **URLResourceValues НЕ несёт
  ownerAccountName** в этом SDK (только NSFileAttributeKey из FileManager-stat)
  — план «free owner из values» был неверен: owner читается тем же stat, что
  и posixPermissions (один атрибутыOfItem на элемент, как и раньше). (2)
  **NSTableCellView владеет `imageView`/`textField`** — private-хранилище с
  тем же именем в ячейке = «overriding property must be as accessible»; ячейка
  хранит `thumbView`. (3) NSWorkspace `localizedDescription(forFile:)` удалён
  из SDK (deprecation → UTType.localizedDescription) — kindText берётся из
  UTType(filenameExtension:), папки — по ключу. (4) Reorder колонок —
  `moveColumn(_:toColumn:)` (Int-индексы), identifiers через
  `column(withIdentifier:)`; порядок фиксируется в 3 шага: удалить лишние →
  добавить отсутствующие → дожать move на целевые позиции (все колонки
  pre-built, перестройка отсутствует). (5) **thumbnail identifier = строка
  «thumbnail»** — НЕ кейс ColumnID (settings-пресеты его не перечисляют ever);
  appearance/disappearance решает сам режим ⌃4. (6) Мьютация item-копии в
  тесте НЕ проходит в VM (value-типы) — сначала setItems с мутнутым экземпляром,
  потом setViewMode + render (и не забывать сортировку: курсорная строка
  меняется). (7) `cacheKey` — pure → `nonisolated` (@MainActor-класс делает
  статики изолированными по умолчанию; тест вне актора падал с
  ActorIsolatedCall). (8) ThumbnailStore fake синхронен: первый вызов
  `thumbnail(...)` стартует и завершает генерацию ДО возвращ nil — кэш уже
  горячий на следующем вызове; `cancelPending` чистит pending без отмены
  Task'и — поздний completion попадает в кэш и глушится mode-guard'ом
  слушателя; QL-pipeline (≥ 1000 медиа-файлов, неблокирующий UI) — T-34
  ручной smoke по прецеденту T-27/T-31. (9) Скоуп-фиксы: `showThumbnails`
  из схемы УБРАНО (⌃4 самодостаточен), «сброс» охватывает новые секции,
  settings Store разбирает невалидный filterStyleRaw в App (substring default)
  — хранится сырой.
- **Гейты:** build 0 warnings; Debug + Release — 349 зелёных (+14: st*6 + clt*8
  [SettingsStoreTests дополнения, FileListViewColumnsTests]); license-check OK
  (новых dep нет — QuickLookThumbnailing системный).
### T-33. Темы (F-23 частично): light/dark/NC-blue, шрифты_(каждая задача: файлы из соответствующих модулей по карте `11`, критерии приёмки — из карточек фич `02`; тесты — unit + integration; пункт «Готово» = все acceptance критерии фичи.)_
- **Готово:** SettingsSchema `themeRaw` («system»/«light»/«dark»/«ncBlue»,
  additive, schemaVersion 1, reset(.appearance) накрывает); App —
  `applyTheme(raw)`: light/dark через `NSApp.appearance` (.aqua/.darkAqua/
  nil = system), ncBlue → `PanelTheme.ncBlueClassic` → `FileListView.applyTheme`
  (обе панели, live по `onDidUpdate`); LV — `PanelTheme`
  (rowBackground/rowAlternate?/rowText/rowSecondaryText, Equatable +
  @unchecked Sendable — NSColor без аннотации), applyTheme красит
  backgroundColor + ряды через delegate `didAdd` (NSTableView НЕ умеет
  перекрасить системную альтернацию напрямую), nil восстанавливает
  дефолт (захвачен при build); ячейки получают токен в viewFor (NameCell —
  stash-токен, рендер учитывает hidden→secondary; MetaCell — direct color);
  окно настроек: theme-popup (4 пункта) + NSComboBox font-family (editable,
  пусто = системное лицо, live через существующий applyPanelFont);
  Localizable-ключи — сырые (каталог T-35).
- **Уточнение (по ходу реализации T-33):** (1) **NSTableView не имеет
  пер-таблицного custom-alternating API в этом SDK** — только
  `usesAlternatingRowBackgroundColors: BOOL`; кастомные цвета рядов
  подставляются в delegate `tableView(_:didAdd:forRowAt:)` через
  `NSTableRowView.backgroundColor` (даже/нечётные). (2) Порядок в `viewFor`
  критичен: `themeCall(cell)` ДО render — свежесозданная ячейка первый раз
  красится из токена; post-render `applyThemeColors` переКрасил бы только
  переиспользованные. (3) `static let` preset на не-Sendable struct =
  MutableGlobalVariable-ошибка; NSColor не Sendable → `@unchecked Sendable`
  на immutable-структуре (легально и для struct). (4) `NSColor ==` между
  catalog-цветом (labelColor) и sRGB-константой НЕ равны — тесты сравнивают
  только наши же токены/захваченный дефолт. (5) NSComboBox: `completes` +
  editable, `stringValue` читается в action (Enter/Tab-commit) — паттерн
  NSTextField-полей. (6) Скиning-границы v1 согласно §6.9 T-33: ncBlue
  красит ТОЛЬКО списки панелей (tab-chrome/диалоги/Lister/терминал —
  системные, расширение v1.x); light/dark меняют только NSApp.appearance —
  системные цвета сами, тесты UI-нейтральны.
- **Гейты:** build 0 warnings; Debug + Release — 355 зелёных
  (+6: thm*4 + stT33*2); license-check OK (новых dep нет).

### T-34. M3 hardening: smoke 8.4 п.8–9; перф-регрессии; ADR-догма обновлений.

- **Уточнение (по ходу реализации T-34):** (1) smoke 8.4 п.8 легировано
  автоматикой (уточнение вписано в `08` §8.4): quick filter = FilterEngine
  + PanelViewModelFilterSelection, quick search = SearchEngine +
  SearchResultVFS, multi-rename = RenamePlanner + **новый
  `MultiRenameDialogTests` ×4** (preview 100 имён; конфликт-фикстура
  «doc_N.txt» → Apply disabled и ровно 5 красных строк «new»-колонки;
  baseline «[N]» без смен → Apply disabled; dry-run apply → `.move`-план
  без записи) + multiRenameThroughUnifiedQueue; ручной остаток п.8 —
  глазная Москва-проверка панелей, п.9 — vim/tmux и подтверждение закрытия
  окна с активной задачей (прецедент T-27/T-31). (2) Тест-шов диалога:
  rule-поля MultiRenameDialogController widened private→internal (+
  applyClicked/cancelClicked) — диалог = UI-клей над чистым планнером;
  headless вызов applyClicked/cancelClicked безопасен вне модальной петли
  (NSApp.stopModal() — no-op). (3) Урок планнера: template без [E] всё
  равно сохраняет оригинальное расширение (.keep) — «doc_[C]» даёт
  «doc_1.txt»: конфликт-фикстура обязана занимать имена С суффиксом
  (задвоенный первый прогон тестов поймал, поправлено). (4) ADR-дрейф:
  строка ADR-1 в `01` §1.6 уточнена («AppKit для панелей, настроек и
  диалогов»; SwiftUI отсеян к M3 по опыту T-18/T-32: headless-тестируемость
  и настраиваемая таблица) + M3-сверка догмы под таблицей (ADR-2
  Sparkle=T-37, ADR-4/7 подтверждены реализацией, ADR-5/8 — v1.x). (5)
  Урок тулчейна: под load ≥ 6 хвостовые сводки «Test run with N…» в
  redirect-логах затираются (кластер ~3.956 MB — PTY-буфер харнеса);
  истина гейта = exit-код прогона + `--list-tests` (маленький вывод:
  **359 строк = 355+4**) + счётчик «recorded an issue»=0. Ретрай-политика
  §8.5 (новое уточнение в SDD) не понадобилась: все прогоны зелёные с
  первой попытки. (6) Гейты: build 0 warnings; Debug ×3 (parallel ×2 +
  serial --no-parallel) exit=0; Release exit=0 (0 failed/issue);
  license-check OK (новых dep нет).

## v1.0
### T-35. Локализация EN/RU (F-22, String Catalogs, lint-правило)

- **Уточнение (по ходу реализации T-35):** (1) Инвентарь: 281 ключ
  (223 прямых + 3 новых формат-ключа + 2 тернарных select/deselect + 38
  меню-тайтлов + 5 секций + 6 колонок conflict/search); ru-каталог —
  полный parity. (2) **Пробанка решает форму каталога:** CLI-SwiftPM
  (swift 6.3.2) НЕ компилирует `.xcstrings` — файл копируется в бандл
  как есть и `String(localized:)` его не резолвит → мастер-каталог в
  классике `App/Resources/{en,ru}.lproj/Localizable.strings`; `.process`
  складывает lproj в бандл (проверено на
  `MyCommander_MyCommander.bundle/en.lproj/…`); пакеты резолвят через
  Bundle.main (= app-bundle), код ЭКСТЕНСИОНАЛЬНО не тронут.
  `defaultLocalization: "en"` — параметр ПАКЕТА (не target!) и ОБЯЗАН
  стоять ПЕРЕД `platforms`. (3) DMG/`.app`-фаза (T-37): при ручной
  сборке app-bundle перенести оба lproj в `Contents/Resources/` —
  smoke 8.4 п.10 проверит RU-подстановку живьём. (4) Формат-ключи =
  спецификаторы на МЕСТЕ вызова: Int → `%lld`, String/enum/Bool → `%@`
  (порядок аргументов неприкосновенен); Int32 неоднозначен
  (`ShellSession.exitCode`) → сайт переписан на `Int(...)`; форматные
  `String(format:)`-сайты — PLAIN ключ с форматами в VALUE
  (`menu.hotSlotBookmark` = «[%ld] %@»). (5) Косвенные ключи — четыре
  пути в сканере: `titleKey`-спеки MenuBuilder (38 пунктов + 5 секций),
  кортежи `(CommandID…)`/`(ColumnID…)` с `LocalizationValue` (колонки
  conflict/search), тернарник `String(localized: deselecting ? …`
  (сбор литералов ±2 строки). (6) Lint `Tools/localization-check.sh`:
  15 UI-паттернов, буква в литерале (`isalpha`) = fail; inline-исключение
  `// l10n-allow` (использован для шаблона `[N]`); первые прогоны поймали
  фантомы (SF-символы `lock.fill`, a11y-идентификаторы `mc.*`) — скан
  сужен до line-based контрактов вместо file-wide key-shaped.
  (7) Интегрити-тест `LocalizationStringsTests` ×2 (`loc` name-space):
  en/ru parity + двустороння сверка ключей + формат-префикс ↔
  интерполяция; урок парсера: symlink-сайт роняет хвост `)` в префикс —
  нормализация `[\s)]+$` в обоих чекерах. (8) Локализованы хардкодные
  сайты: `"\(record.name): …"` → `progress.failureDetail`; строка
  счётчиков sync → `sync.countFormat`; hot-slot меню →
  `menu.hotSlotBookmark`; `commandBar.console.exitCode` Int32 → Int.
  (9) Гейты: build 0 warnings; Debug ×2 — exit 0 / 0 issues; Release —
  ретрай-политика §8.5 сработала впервые (как в T-34): попытка 1 — 8
  перф-slip (load 6.7+), попытка 2 — 3 (load 6.6), попытка 3 — 0 → GREEN;
  license-check OK; localization-check OK (281 ключей, 0 hardcoded).

### T-36. Темы довести до релиза (F-23), полиш диалогов/badges

- **Скоуп (по инспекции T-36; границы v1 — 06 §6.9, скин-extension НЕ
  входит):** (1) Реальный полиш-пойнт — бейджи ячеек (symlink/hidden/locked):
  они красились константным `.secondaryLabelColor` один раз в init NameCell
  и НЕ следовали токенам — под ncBlue тёмный бейдж на синем фоне. Фикс =
  бейдж красится из `rowSecondaryText` (тот же токен, что скрытые
  имена/мета-колонки), restore = системный `.secondaryLabelColor`.
  (2) Стартовое применение темы ВЕРИФИЦИРОВАНО по коду без правок:
  `PanelsCoordinator.init` создаёт панели ещё до `wireSettingsConsumers()` —
  `applyPanelSetting(settings)` с applyTheme вызывается безусловно при
  старте; новые табы не требуют обогащения (fileListView один на панель,
  табы меняют VM внутри; ⌘U adoptTabList тоже реюз). (3) Диалоги: полиш по
  осмотру проблем не нашёл — все четыре диалога имеют кнопки Return/Esc,
  числовые поля MultiRename толерируют мусор через `Int(...) ?? дефолт`.

- **Уточнение (по ходу реализации T-36):** (1) Фикс бейджей: токен веха
  в `applyThemeColors(text:secondary:)` NameCell — под ncBlue бейдж
  следует `rowSecondaryText`, restore = `.secondaryLabelColor`; тест-шов —
  `badgeText`/`badgeTextColor` accessors (headless-тесты не копаются в
  приватных полях). Новый тест `thmBadgeFollowsTheThemeToken` — 5-й в
  `PanelThemeTests`. (2) Урок headless-тестов ячеек: `PanelViewModel`
  СОРТИРУЕТ имя-ASC — индексы строк теста обязаны следовать сортировке
  (a.txt → 0, h2.txt → 1, r.txt → 2), а `viewFor` в headless создаёт
  НОВЫЕ ячейки: захваченная инстанс-переменная НЕ перерисовывается
  `applyTheme(nil)` (нет visible-строк — `reloadVisibleRows` no-op);
  рестор-ассерт = re-fetch через `viewFor` ПОСЛЕ applyTheme(nil).
  (3) Урок тулчейна (уточнение §8.5): полный параллельный Debug-прогон
  напечатал 3 «failed after» при exit=0 — квирк раннера; истина гейта =
  СЧЁТЧИК «failed after"/"recorded an issue» (= 0) в полном прогоне +
  зелёный изолированный ретрай сомнительных тестов (§8.5), exit-код сам
  по себе ненадёжен (T-34-легенда «exit-код = истина» уточнена).
  (4) Стартовое применение темы верифицировано по коду, код не троган;
  fileListView один на панель — токены переживают табы/⌘U бесплатно.
  (5) Гейты: build 0 warnings; Debug #1 — 3 перф-флейка (нагрузка 6.5,
  §8.5-изолированный ретрай зелёный), Debug #2 serial — 0; Release —
  зелёный с первой попытки (354 passed, 0 failed); license-check OK;
  localization-check OK (281 ключей, 0 hardcoded).

### T-37. Релиз-инженерия: Sparkle, DMG+notarization, GitHub Releases, README/help, NOTICE-проверка, beta-канал
### T-38. Бета-цикл: сбор фидбек, краш-фиксы, замер crash-free ≥ 99.5 %

## v1.x (бэклог — спецификации пишутся при входе)
- T-40 Git column provider (F-24, dogfood F-27)
- T-41 SMB (F-25, AMSMB2)
- T-42 S3 (F-26) · T-43 Plugin contract + SDK (F-27) · T-44 FTP (F-28) · T-45 Дубликаты (F-29) · T-46 Split/combine/checksums (F-30)
