# 06. Дизайн подсистем

Ссылки на контракты — `05-DataModel-VFS.md`; потоки — `04-Architecture.md`.

## 6.1 Панель файла (ListViewKit)

- **Контракт v1 (T-16 — DnD мост F-18):** транспорт NSPasteboard, чистая логика в `DragBridge` (tests): тип `com.mycommander.panel-item.v1`, запись через `entry(fileURL:path:) → NSPasteboardItem` (`.fileURL` — URL, item-тип — JSON `VFSPath`), чтение `readURLs` / `readPaths` (per-item compactMap + `JSONDecoder`). `displayURL` уже в §5.1.
- `FileListView` — drag source/destination без знаний о VFS: `onPasteboardWriterForRow: (Int) -> (any NSPasteboardWriting)?` (App строит item; non-local → nil, drag не начинается), `onDropReceived: (urls:, paths:, isInternal:, wantsCopy:) -> Void`. Destination-точки: `registerForDraggedTypes([.fileURL, itemType])`, `draggingUpdated` — self-source (`draggingSource as? FileListView === self`) → отказ; внешний источник (Finder) → `.copy`; внутренний — `.move` (⌥ → `.copy`); бейджи copy/move курсора рисуются системой по возвращённой NSDragOperation.
- **Семантика (App-драйвер):** Finder→панель — copy (план поверх `TransferPlanner.planCopy` + `OperationExecutor.enqueue`, конфликты через `ConflictDialog`); panel↔panel — move по умолчанию, ⌥ = copy; самодроп — отказ; non-local drag-out — не тянет (v1 — только LocalVFS; архив/SFTP drag — следующая версия); «drop в архив — extract» — после ArchiveVFS (M2). Drop-target — панель целиком (F-18 «домашняя панель — дефолт-цель»); после операции панель обновляется watcher'ом.

**Структура:**
- `PanelViewController` (NSViewController) держит `PanelViewModel`, `FileListView: NSTableView` (cell-based, с переиспользуемыми ячейками), страницу табов (`NSStackView` + кастомные tab cells), статус-строку (путь, запись «n of m selected», фильтр-индикатор, режим доступа Safe/FDA).
- `PanelViewModel` (MainActor):
  - хранит: `path`, `rawItems: [VFSItem]`, `visibleIndices: [Int]` (после sort+filter), `selection: Set<VFSPath>`, `cursor: Int`, `viewMode`, `sortCriteria`, `revision`;
  - апдейтирует таблицу диффом: вычисляет `SetDiff(oldVisible, newVisible)` и делает батч `beginUpdates / remove / insert / reload / endUpdates` — это критично для N-1;
  - folder-size кэш: `ItemExtraCache` (key: path) — фоновый подсчёт по Space/cursor-idle.

**Ячейки:** `NameCell` (иконка + имя + бейджи: symlink/hidden/locked), `MetaCell` (размер/дата/права), колонки по `ViewPreset`. Иконки — `NSWorkspace.icon(forFile:)` с LRU-кэшем (N ≤ 500).

**Only-cell-reuse + rowHeight фикс:** панели не используют autoreizing rows (перформация дорогая); высота строк константна.

**Фокус-модель:** `FocusController` знает activePanel; команды (`CommandRouter`) всегда получают `activePanel` + `otherPanel` контекст. Tab-переключение — `⌃Tab`/клик; фокус возвращается в список.

## 6.2 Движок операций (FileOpsKit)

**Трехслойность:**
1. `Planner` — по запросу UI строит `TransferPlan`: разворачивает деревья (listDirectory рекурсивно, отчёт по глубине/размеру — потоковый `ProgressSink`), предрасчёт конфликтов (target stat), детект same-volume (clone-возможность) и edge cases (перенос панели в собственную подпапку → запрет, сообщение).
2. `ConflictResolver` — UI-диалог по списку конфликтов: превью (иконки, размеры, даты), policy-выбор per-item/all.
3. `OperationExecutor` (actor): воркер-пул N=4; каждый `TransferItem` — транзакция:
   - same-volume + APFS: `clonefile()` fallback rename;
   - cross-volume: `openWrite` в temp (`.<name>.mc-partial`) → копирование чанками через `ByteStream` → fsync → `rename` в целевое имя;
   - resume-файл: `.mc-partial` переиспользуется по offset;
   - прогресс per-item + агрегированный; пауза — синхронный семафор в copy loop; cancel — `Task.cancel` + cleanup temp.
   - delete: tree-walk bottom-up; toTrash через `FileManager.trashItem` (локальный); для VFS без trash — прямое удаление с подтверждением.

**Journal:** каждое совершившееся изменение (`renameBackPath`, `createdPath`, `trashMoveRecord`) пишется в `JournalStorage` (кольцевой буфер, 20 записей). Undo — реверс-план исполняется тем же `OperationExecutor` (конфликты задают те же диалоги).

**Персистентность очереди:** в рамках сессии (crash → восстановить список незавершённых вопросом «добить?»).

## 6.3 Watcher (LocalVFS)

- `FSEventsWatcher`: один `FSEventStream` на все watched dirs (latency 0.5, `kFSEventStreamCreateFlagNone`), coalescing 300 мс в очередь диффов.
- **Self-suppression:** FileOpsKit публикует `suppress(paths: [VFSPath], until: deadline)` — watcher игнорирует свои события (иначе гонка «операция → событие → лишний diff»).
- Дифф = `lstat` сравнение snapshot vs новый список (listDirectory повторно) → `DirectoryDiff`.
- Volume-события: `NSWorkspace.shared.notificationCenter` (mount/unmount) → закрытие панелей, указывающих на unmounted volume (диалог «источник недоступен»).

## 6.4 ArchiveVFS

- Открывается по клику на архив в любой панели (`ArchiveVFS(reading: fileURL)`), регистрируется в реестре; «извлечь всё» = copy из нескольких путей.
- Форматы: **read** — zip (ZIPFoundation), tar·gz·xz·bz2 (SWCompression), 7z (v1.0 SHOULD); **write** — zip (ZIPFoundation, уровень/пароль — базовые опции в диалоге Pack).
- Read-cache: индексируем entries при открытии (отложенно к атрибутам для больших архивов); per-file extract — через temp-dir под `~/Library/Caches/MyCommander/extract/`, истечение 24 ч или при выходе.
- Ограничения честно отражены в `capabilities` (canWrite = false вне zip; canWatch = false).

## 6.5 SftpVFS (Citadel)

- `ConnectionStore` создаёт `SftpVFS` по `ConnectionRecord`: Citadel `SSHClient` → `openSFTP()`.
- Маппинг операций: listDirectory/packages → parse attrs → `[VFSItem]`; read/write — stream по offset (поддержка resume); rename/mkdir/rm прямые; dirSize — рекурсивной структурой.
- Жизненный цикл: idle-KA каждые 30 с; reconnect backoff 1/2/4/8 с (max 5), после — ошибка в панели с «Reconnect» кнопкой; отмена операций пользователя — мгновенный close-channel.
- Хост-ключ: первый accept с fingerprint-диалогом; pinning в `ConnectionRecord`; изменение — красный экран-подтверждение (mitm-защита).
- Переносы файлов: прогресс per-file (offset-based); пауза может стоить буферизации (документированный предел).

## 6.6 EnginesKit

- **FilterEngine** (quick filter F-10): подстрока/fuzzy (скорл-Damerau-подобная, но простая prefix-matching по умолчанию substring), обработка ≤ 50 мс на 50k (по Int-index, без создания строк повторно; мемоизация префикса ввода).
- **SearchEngine** (F-16): первый проход — Spotlight-first: `NSMetadataQuery` (если том индексируем): predicate по маске/дате/размеру; content-search: streaming read → bytescan (строчно, по 8 MB), ограничение размера файла (настройка), отмена мгновенная. Результат — виртуальный `SearchResultVFS` (реестр результатов + фильтр-пересборка снимка любого набора).
- **RenamePlanner** (F-14): вход — блок правил (маска-шаблон `[N]`, `[C]`, `[E]`, counter start/step/pad, replace/regex, регистр), выход — таблица old→new + conflicts (дубликаты новых имён, существующие целя); commit — batch через OperationExecutor (sort для стабильности).
- **SyncReporter** (F-15): сравнение двух деревьев по (name, size, mtime) или hash (parallel workers ≤ 4, sqlite-кэш hash) → матрица only-A/only-B/diff/equal → action-script (copy L→R / R→L / mirror (delete) с dry-run по умолчанию) → исполнение через TransferQueue.

## 6.7 Lister (F-8)

- Окно `ListerWindow`: non-blocking (можно листать панель? main); открытый файл — `ByteStream` окно 8 MB + seek.
- Режимы: text (кодировка авто: UTF-8/16, разрыв строк CRLF/LF/CR), hex (`⌃H` — колонки offset/hex/ascii), image (локальные: ImageIO; VFS: temp-экстракт).
- Навигация: PageDown/Up, `⌃End` jump; «пустая» прокрутка за count (лениво окно); статус: позиц/кодировка; поиск внутри (F7): подсветка стрим-окон.
- F4 «Edit во внешнем редакторе»: temp-коpия, файл мониторится (если задано) — «вернуть изменения» диалог при возврате.

- **Контракт v1 (T-13):** слой просмотра строится на стрим-источниках FileOpsKit (ListViewKit не знает VFS-адаптеров —(layers 04)):
```swift
struct ListerByteSource: Sendable {              // окно-чтение F-8 (06 §6.7)
    var totalSize: Int64
    var read: @Sendable (_ offset: Int64, _ length: Int64) async throws
        -> (offset: Int64, data: Data)           // seek по ByteStreamSeekable, иначе добор пропуском чанков
}
enum ListerLoader { static func open(path: VFSPath, in: any VFS) async -> ListerByteSource? }
enum PreviewMaterializer {                        // URL для QL F-9 / F4-редактора
    static func prepareFileURL(path: VFSPath, in: any VFS) async -> URL?  // LocalVFS → файл, иначе temp-копия (purge на terminate)
    static func purgeTempCopies()
}
struct ListerTextPage { var text: String; var nextOffset: Int64 }  // граница символа, след страницы
enum ListerCodec { decodeTextPage / hexPage / … }  // ListViewKit, чистая логика (детект UTF-8/16, hex 16 B/строку)
```
- Стрим-окно v1: текст 256 KB, hex 64 KB, image — целевой файл через `PreviewMaterializer` (8 MB из §6.7 — ориентир; меньше окно из-за файлов-без-newline: одна «строка» размером с окно тормозит NSTextView, семантика «окно+seek» сохранена). Авто-режим: image-расширения → image; NUL в первых 4 KB → hex; иначе text. Поиск внутри (F7)/«вернуть изменения» — следующие версии (не в acceptance F-8).
- **Разрешение Space-конфликта F-3/F-9 (уточнение T-13):** Space в списке остаётся выделением (F-3, MUST, классика NC/TC); QL — `⌘Y` (02 F-9 «или ⌘Y», 07 «⌘Y / Space на невыделенном» — строка 07 приведена к «⌘Y»; назначить Space может пользователь ремапом, когда появится перебиндивание таблицы). В окне Lister Space/⇧Space — страница вперёд/назад (07, таблица «В просмотрщике»).

## 6.8 Terminal (TerminalKit)

- SwiftTerm `LocalProcessTerminalView` — PTY child-process (~LOGIN_SHELL), env устанавливает `workdir = активная панель`.
- `⌃\`` toggle нижней partiti (split: терминал 40 % высоты); авто-CD следит за панелью (debounced, опция off); выбор текста/копипаст/вставка path панели по `⌃⇧V`.
- Политика процессов: child живёт, когда панель скрыта; kill при закрытии окна с подтверждением (если есть запущенные задачи).

- **Контракт v1 (T-14 — командная строка F-17а, exec-ветка):**
```swift
struct ShellOutcome: Sendable, Equatable {      // один выстрел, НЕ PTY (PTY — F-17, M3)
    var exitCode: Int32
    var standardOutput: String
    var standardError: String
}
enum ShellSession {
    // /bin/sh -c «command»; collect через pipe-readability + termination-continuation.
    static func exec(command: String, workingDirectory: URL?,
                     environment: [String: String]? = nil) async throws -> ShellOutcome
}
```
- `CommandBar` (ListViewKit, внизу главного окна — 07 §7.2): чистая логика без AppKit и VFS — `CommandBarParser.parse` → `.cd/.mkdir/.open/.shell`/`.invalid` (первое слово — до расширения плейсхолдеров, иначе пробелы в путях рвут токен); плейсхолдеры `%f` (имя под курсором), `%F` (полный путь), `%d`/`%D` (каталоги активной/противоположной панелей), `%s` (список выделенных, при пустом выделении — файл под курсором); подстанованный путь цитируется shell-вариантом при пробелах/кавычках (для vfs-команд значения разворачиваются `unquote`), `%%` ≡ литерал `%`, неизвестные `%x` остаются как есть; `CommandHistory` — append-only, dedup последовательных, ↑/↓ c черновиком: ↑ от черновика → последняя, дальше к старым, ↓ вниз до черновика. Мини-консоль вывода — под строкой ввода (сворачиваемая `[^]`).
- Исполнение — в App (ListViewKit не знает VFS): `cd`/`open` — резолв кандидатов (`~`, абсолют, относительный) + `metadata`, каталог → `openDirectory`, файл (LocalVFS) → `NSWorkspace.open`; `mkdir` — `VFS.createDirectory` (v1 одно имя, вложенность — честная ошибка); `!` — `ShellSession.exec` с cwd активной панели (только LocalVFS, иначе понятная ошибка); вывод/ошибки — в мини-консоль. Tab-автодополнение путей и `touch`/`du`/`find` — следующая версия.

## 6.9 ServicesKit

- **SettingsStore**: default-мерж с user JSON; применение мгновенное (pub-всем модулям по `DidUpdate` каналу);
- **KeymapStore**: профили (default TC-style / macOS-style / user), запись — `KeyCombo` (keyCode + modifiers), конфликты forbidden при сохранении;
- **LocationsStore** (закладки/Hotlist/история per-tab; hot-Slots 9);
- **ConnectionStore** + Keychain (kSecClassGenericPassword, service `MyCommander.connection.<id>`) — никогда не в JSON;
- **SessionStore**: перенастраиваемый список табов к моменту выхода (restore on launch).

## 6.10 App target

- `MainWindowController`: layout (панели/терминал/командная строка/fullScreenModel), запоминает геометрию.
- `CommandRouter`: таблица CommandID → действие; remap — KeymapStore; все команды реализуются методами coordinator-классов (тестируемость).
- **OnboardingFlow (F-20)**: экран FDA → кнопка «Открыть System Settings» → процесс возврата (проверка по probe) → Safe Mode banner если отказано. Повторная навязка — max 2 раса, потом только банер.

- **Контракт v1 (T-17 — onboarding/AccessProbe F-20):**
- `VFSKit/AccessProbe.swift`: `AccessZone` (desktop/documents/downloads/library), `AccessReport { hasFullDiskAccess: Bool, grantedZones: [AccessZone] }`, `AccessMode { full, safe(zones: [AccessZone]), restricted }`; `classify(report)` — чистая логика (full → full, иначе safe по зонам, пусто → restricted — app не падает никогда); `probe(home:)` не-async, параметризуемый home для тестов: FDA-проба — читаемость `~/Library/Preferences/com.apple.dock.plist` (TCC-защищённый файл; чтение без FDA проваливается), зона — успешное `contentsOfDirectory` (ошибка → не granted, пустой список → granted).
- `ServicesKit/OnboardingState.swift`: чистая модель правила «max 2 навязки» (§6.10): `shouldOfferInitial` (не hidden && presented==0), `canOfferAgain` (не hidden && presented<2), `afterPresentation()`, `hidden permanently`; персист в UserDefaults — только App ( ключи `mc.onboarding.*`).
- App `OnboardingFlow` (non-modal окно): пояснение FDA + «Открыть System Settings» (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`) + «Продолжить без Full Disk Access» + «Не показывать снова»; probe-обновление на каждом `NSApplicationDidBecomeActive` (granted → окно закрывается, mode → full). Статус: `FileListView.accessBadge: String?` (App пишет локализованную строку «FDA» / «SAFE …» — appendposed в статус-строку). Safe-первый запуск без сессии: seed панели — первая granted-зона (иначе home).
- Menu bar: полная эквивалентность клавиш (пользователь меню видит хоткеи реального профиля).

## 6.11 Info dialog (F-19)

- Карточка non-modal (07 §7.2 «карточка без блокировки»): одно reusable-окно, повторный вызов перезаписывает содержимое; закрытие не прерывает фоновый подсчёт (диалог обновляется, когда жив; результат отбрасывается иначе).
- **Контракт v1 (T-15):** ListViewKit строит карточку из `VFSItem` (адаптеров не знает — слои):
```swift
struct InfoField: Sendable { var kind: InfoKind; var label: String; var value: String }  // label — String(localized:)
enum InfoKind { case name, kind, size, created, modified, permissions, owner, group, tags }
enum InfoFieldBuilder { static func fields(for item: VFSItem) -> [InfoField] }
enum InfoBytes     { static func format(_ bytes: Int64) -> String }      // 1024-база: «0 B», «1.5 MB»
enum InfoPermissions { static func format(_ posix: Int16) -> String }    // 0o644 → «-rw-r--r-- (644)»
@MainActor final class InfoWindowController: NSWindowController {
    init(item: VFSItem); func update(size: Int64); func copyToClipboard(); func activate(); func reset(to: VFSItem)
}
```
- Рекурсивный размер каталога — фоново (App-драйвер): `VFS.directorySize(of:progress:)` с `ProgressSink`-счётчиком → поле size показывает «scanning…», итог через `update(size:)` (MainActor-хоп из sink-задачи). Даты — стабильный формат «YYYY-MM-DD HH:MM» (без локалевых вариаций). v1: LocalVFS/InMemory — метаданные других адаптеров идут через тот же `VFSItem`; xattr — следующая версия (не в `VFSItemAttributes`).
