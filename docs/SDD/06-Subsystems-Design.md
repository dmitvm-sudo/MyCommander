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

*Уточнение T-21 (архив-интерлюдия, F-12):* `PanelViewModel` получает два `@MainActor`-hook'а, ставимые App в фабрике вкладок: `openEntryHandler: (VFSItem) async -> Bool` (consume-контракт: true — entry открыт обработчиком VM-навигации; false/nil — прежний no-op для file/special) и `onRootExit: () async -> Void` (goUp-at-root; локальные панели без него ведут себя как прежде). `PanelTabList` получает `swapActiveTabViewModel(_ newViewModel:) -> PanelViewModel?` — swap в активной вкладке: unwire старого VM (callback+watch), wire нового, id/lock сохраняются; возврат — тем же API (watch/callbacks прицепляются заново).

*Уточнение T-32 (режимы отображения F-4 v1):* `PanelViewModel.ViewMode` — 4 кейса: **full** (⌃1, фиксированный набор name+size+dateModified), **brief** (⌃2, только имена), **columns** (⌃3, full-таблица с настроенным набором+порядком колонок из settings), **thumbnails** (⌃4, name+thumbnail-колонка, высота строки 56). Переключение локальное: клавиши входят в keymap (‡07), классификатор PanelKeys отдаёт `.viewFull/.viewBrief/.viewColumns/.viewThumbnails`, команда применима КО любой панели (`CommandRouter`). Колонки pre-built и attach/detach-аются (`applyColumnPreset([ColumnID])` — live из SettingsStore.onDidUpdate); `name` всегда первая (контракт §5.9). Данные колонок из `VFSItem.attributes` (data контракт уже полон — §5.1): size/dateCreated/dateModified (форматирование MetaCell), permissions (posix-октал), owner, tags (join «, »), kind (`NSWorkspace.localizedDescription`). **Thumbnails** — `ThumbnailStore` в LV: QLThumbnailGenerator.generateBestRepresentation асинхронно на VISIBLE строках (lazy, cell-request → cache → reload строки по готовности с identity/mode-guard), NSCache ≤ 1000 (path-key), источник URL = `item.id.displayURL` (LocalVFS-списки несут → иконка fallback для остальных/VFS). Блокировок UI нет (генерация в фоне; acceptance «≥ 1000 медиа-файлов»).

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

**Journal:** каждое совершившееся изменение (`renameBackPath`, `createdPath`, `trashMoveRecord`) пишется в `JournalStorage` (кольцевой буфер, 20 записей). Undo — реверс-план исполняется тем же `OperationExecutor` (конфликты задают те же диалоги). *Уточнение T-20 (v1):* план строит `UndoPlanner` (FileOpsKit) по `JournalRecord.popLast`; команда `.undo` (⌘Z, global, меню «menu.undo» в Operations); mkdir-записи append-ит App при успехе `createDirectory`.

**Pack-flow (zip) — уточнение T-22 (F-12):** оболочка `FileOpsKit/ZipPack.swift` над
`ZIPFoundation`: `ZipPackSpec` — параметры в `TransferPlan.zipPack` (DomainKit:
`ZipPackCompression.store/.deflate`; «уровень» сжатия ZIPFoundation не выставляет —
диалог Pack честно показывает именно «метод»), `ZipPackPlanner.planPack(sources:into:) →
TransferPlan(op: .packZip, items: N источников, target = destination/zipName для всех,
conflicts: targetExists на zip)`. Executor-ветка `.packZip`: destination обязан быть
`LocalVFS` (v1: зип пишется локально; иначе `.vfsUnsupported`); публикация — staging
`.<name>.mc-partial` в ЦЕЛЕВОМ каталоге → rename (единый протокол 06 §6.2,
idem CopyTransaction); источники — LocalVFS → `addEntry(fileURL:)` напрямую,
ArchiveVFS/др. → материалазизация через `openRead` во временные файлы →
`addEntry(fileURL:)`, temp удаляется; имена entry — только из `VFSItem.name` (не из
имён temp); пауза/отмена — `OperationGate` на границах entry. Прогресс — по байтам
источников на границах entry (ZIPFoundation update total-only при записи — per-chunk
невозможно; честный фикс v1, зафиксировано в 05 §5.6 уточнение). JournalRecord
`.packZip` → reversal `deleteCreated(zipPath)`. Download-сноска: «extract-все» в v1 —
это обычный copy-план F-5 из ArchiveVFS в LocalVFS (исполняется очередью T-10 через
`openRead`; сноска в 02 F-12).

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

*Уточнение T-21 (read v1):* архив-панель — «интерлюдия»: `ArchiveVFS(reading:)` монтируется в
`VFSRegistry` (VFSKit, §5.3; `mountArchive(reading:)` — идемпотентно, id `kind: .archive`,
specID = путь:size:mtime → повторная «установка» того же файла возвращает тот же инстанс;
регистр вытесняет по FIFO при >64). «Открытие по Enter» перехватывает `PanelViewModel.openEntryHandler`
(App ставит его в фабрике вкладок; consume-контракт: true = entry открыт), панель перебиндивается
на новый `PanelViewModel(source: ArchiveVFS)` через `PanelTabList.swapActiveTabViewModel(_:)`
(id/lock вкладки сохраняются, история — заново; выход — goUp-at-root через `PanelViewModel.onRootExit`
→ rebind предыдущего VM; локальные панели ведут себя как раньше). Read: zip — ZIPFoundation
(центральный каталог, стрим-извлечение; не-UTF8-имена → CP866-fallback через `pathEncoding`);
tar — свой стрим-ридер по 512-байтовым заголовкам поверх FileHandle (ustar-имя+prefix, PAX «path»/«size»,
GNU «L»/«K», typeflag 0·\0 (файл), 5 (dir), 2 (symlink → item, данные никогда не следуют), 1·3·4·6 —
заголовок пропускается; RAM — O(1) на entry, требует хвостовые токена «два нуля-блока» лояльнее спеки);
gz/xz/bz2 — единичные инстансы, декод контейнера SWCompression-полностью в RAM **при доступе**
(v1-лимит честно: сжатый контейнер ≤ RAM; zip/tar — честные >4 GB); распакованный tar-потом
стримится из кэш-файла. Индекс строится при открытии (headers only); extract-entry — лениво,
в `…/extract/<spec>/` с атомарным rename, кэш-жизнь — процесс + чистка при выходе (24 ч — v1.x).
Path-traversal блок: имена связываются архивной нормализацией VFSPath-семантики («..» при корневом
выходе выбрасывает entry, вложенные «..» клампятся внутри архива); symlink-entries НЕ создаются
на диске и НЕ открываются (vfsUnsupported) — extract/openRead физически не выходят за кэш-каталог.

## 6.5 SftpVFS (Citadel)

- `ConnectionStore` создаёт `SftpVFS` по `ConnectionRecord`: Citadel `SSHClient` → `openSFTP()`.
- Маппинг операций: listDirectory/packages → parse attrs → `[VFSItem]`; read/write — stream по offset (поддержка resume); rename/mkdir/rm прямые; dirSize — рекурсивной структурой.
- Жизненный цикл: idle-KA каждые 30 с; reconnect backoff 1/2/4/8 с (max 5), после — ошибка в панели с «Reconnect» кнопкой; отмена операций пользователя — мгновенный close-channel.
- Хост-ключ: первый accept с fingerprint-диалогом; pinning в `ConnectionRecord`; изменение — красный экран-подтверждение (mitm-защита).
- Переносы файлов: прогресс per-file (offset-based); пауза может стоить буферизации (документированный предел).

*Уточнение T-23 (ядро; robustness KA/backoff/таймауты — T-25):* пакет Citadel 0.12.1
(MIT; note: Citadel пинит форк `Wellz26/swift-nio-ssh` версий 0.3.x вместо замороженного
`apple/swift-nio-ssh` — Apache-2.0, риск зафиксирован в NOTICE). **SftpConnection**
(`VFSKit/Sftp/SftpConnection.swift`): `SftpConnectionConfig` (host/port/username/`auth`:
`.password` | `.ed25519(OpenSSH-key string)`; hostKeyValidator как policy-параметр —
pinning/fingerprint-UI приходит с T-24/ConnectionStore); lifetime: `SSHClient.connect`
(reconnectMode `.never` последовательность T-25) → `openSFTP()` единожды — ОДИН
`SFTPClient` на соединение (Sendable, request/response корреляция по id). **errno-маппинг
на границе адаптера (05 §5.8)**: SFTP `noSuchFile` → `vfsNotFound`; `permissionDenied` →
`vfsAccessDenied`; `eof` на read → пустой чанк (нормальный конец файла); `failure` /
`badMessage` / `unknown(code)` → `.network(id, code: debugDescription)`;
`connectionLost`/`missingResponse`/`connectionClosed` → `.interrupted`.
**Пути**: components `VFSPath` = сегменты абсолютного SFTP-пути; базовая точка панели —
`realpath(".")` сервера (кэш `homePath`), traversal-guard — только normalize-пути
(`VFSPath` уже выкидывает `..`). **Чтение**: `SftpByteStream` — один `SFTPFile` (flags
`.read`) + локальный cursor; `readChunk(max:)` = `SFTPFile.read(from:length:)`
(верх чанка 32 KB — сервер-лимит пакета, swift-nio-ssh #99); `length` — из fstat-размера;
`seek(to:)` через offset-read → `ByteStreamSeekable` (canRandomSeek = true).
**Запись (staging, 06 §6.2)**: `SftpByteStreamWriter` — open temp `.<name>.mc-partial` в
родителе цели (`.write/.create/.truncate`), write чанками (`SFTPFile.write(at:)`),
`finish(committingTo:)` → close → (replace && final есть → pre-remove final — SFTP_RENAME
v3 не гарантирует overwrite) → `rename` temp → final.
**Delete**: деревьев разбираются bottom-up рекурсией listDirectory (SFTP не имеет rm -r);
trash на сервере не существует → `toTrash: true` = прямое удаление (06 §6.2: подтверждение
в UI). **Каталоги и размеры**: dirSize — рекурсией listDirectory; **copyContents** — default
extension §5.3 (server-side copy — v1.x), **setAttributes** — permissions/mtime через
`SFTPFileAttributes`. **capabilities**: canWrite/canDelete/canRename = true; canWatch =
false (панель обновляет prefetch-ом при возврате фокуса — 05 §5.4); canRandomSeek = true;
preservesDates = false (v1 не гоняет mtime при transfer — T-25 опция); symlinkSupport =
false (symlink виден как `kind = .symlink`, но не materialize).
**Live-тесты**: in-process Citadel `SSHServer.host` (полный SSH/SFTP handshake по
loopback TCP, host keys генерятся в тесте) + `SFTPDelegate` поверх FileManager
temp-каталога = «живой SFTP-тест-сервер» без внешних зависимостей CI (серверный стек
Citadel так и работает в своих собственных тестах); отдельный внешний сервер
(env SSH_HOST…) не требуется — тест-стенд поднимается в самом тест-процессе.

*Уточнение T-24 (host-key policy + ключи):* **HostKeyPolicy**
(`VFSKit/Sftp/HostKeyPolicy.swift`) — `NIOSSHClientServerAuthenticationDelegate`,
подключается к Citadel через `SSHHostKeyValidator.custom(policy)` (Citadel не даёт
другой точки интеграции). **Fingerprint**: SHA-256 по wire-формату ключа
(`NIOSSHPublicKey.write(to:)` — публичный writer формата ssh-string), отображение
OpenSSH-стиль `SHA256:<base64 без padding>`. **Поток**: fingerprint совпал с пином →
succeed молча; пина нет → `.firstUse(fp)` → async decision-handler
(`(HostKeyEvent) async -> Bool`; App показывает NSAlert «accept/abort», при accept
ConnectionStore пинит fp); пин есть, fp другой → `.changed(old, new)` → handler
(App — красный `NSAlert.critical` MITM-warning; decline → promise.fail → handshake
рвётся). VFSKit остаётся без AppKit — решения принимает App через handler.
**Приватные ключи** (`VFSKit/Sftp/SftpPrivateKey.swift`): v1 — только Ed25519,
незашифрованный OpenSSH-контейнер (`openssh-key-v1`, cipher `none`); зашифрованные
(bcrypt-KDF) и PEM/классические форматы → понятная `MCError.unsupported`-ошибка при
connect (passphrase хранится в Keychain по контракту, но v1 её не применяет —
задокументированная рамка, issue на v1.x). RSA/ECDSA-ключи серверных хостов — через
wire-format fingerprint работают без ограничений (пининг не зависит от алгоритма).

*Уточнение T-25 (robustness — 06 §6.5 «Жизненный цикл»):* **SftpConnection —
supervisor**: idle-KA = SFTP-проба `realPath(".")` каждые 30 с (Citadel 0.12.1 не
экспонирует SSH-level keepalive); probe-отказ → reconnect-цикл. **Reconnect
backoff 1/2/4/8 с, max 5 попыток** (расписание `[1,2,4,8,8]` — конфигурируемо в
`SftpConnectionConfig` для тестов); после исчерпания — состояние `.failed`
(панель показывает ошибку с «Reconnect…»; кнопка ручного reconnect — v1.x).
**Состояния**: `.connected` / `.reconnecting(attempt:nextDelay:)` /
`.failed`; `onStateChange: (@Sendable (SftpConnectionState) -> Void)?` — App
вешает статус-строку и авто-reload панели на `.connected` (watch-канала у SFTP
нет — 05 §5.4). **Таймауты**: `connectTimeout` (Citadel `SSHClient.connect`,
v1 = 10 с). **Отмена операций** («мгновенный close-channel»): cooperative
cancellation на границах чанков — `SftpByteStream.readChunk`/
`SftpStreamWriter.write` и рекурсивные deleteTree/walkSize проверяют
`Task.isCancelled`, при отмене немедленно закрывают SFTP-хэндл и бросают
`.canceled` (staged `.mc-partial` остаётся до явного retry — 06 §6.2).

## 6.6 EnginesKit

- **FilterEngine** (quick filter F-10): подстрока/fuzzy (скорл-Damerau-подобная, но простая prefix-matching по умолчанию substring), обработка ≤ 50 мс на 50k (по Int-index, без создания строк повторно; мемоизация префикса ввода).
- **SearchEngine** (F-16): первый проход — Spotlight-first: `NSMetadataQuery` (если том индексируем): predicate по маске/дате/размеру; content-search: streaming read → bytescan (строчно, по 8 MB), ограничение размера файла (настройка), отмена мгновенная. Результат — виртуальный `SearchResultVFS` (реестр результатов + фильтр-пересборка снимка любого набора).

  *Уточнение T-30 (F-16 v1):* **SearchQuery** — `nameMask: FileMask?`,
  `content: String` (пусто = только по имени), `contentIsRegex: Bool`,
  `caseSensitive: Bool`, `minSize/maxSize: Int64?`,
  `modifiedAfter/modifiedBefore: Date?`, `maxFileSize: Int64` (лимит content-
  скана одного файла, настройка; больше — только name-совпадение),
  `resultLimit: Int` (лимит результатов; достигнут → поиск останавливается,
  результат помечается `truncated: true`). **SearchHit** = `item: VFSItem` +
  `contentMatches: Int?` (nil = совпал только именем/фильтрами).
  **SearchEngine.search(in:at:query:progress:) async throws ->
  SearchResult** (`hits` + `truncated`): обычный путь — рекурсивный обход
  (`listDirectory` вниз, обход обеих «ветвей» через task-cancellation — отмена
  мгновенная, checked per-directory и per-chunk); фильтры имён/размера/дат —
  до content-скана; content — `ByteScan` (окна 8 MB, строчно: литеральная
  подстрока с опцией регистра или `NSRegularExpression` по декодированной
  строке окна, частичная последняя строка переносится в следующее окно).
  **Spotlight-first** (`NSMetadataQueryBridge`, EnginesKit): при наличии
  name/date/size фильтров строится `NSPredicate` (kMDItemFSName LIKE,
  kMDItemFSSize, kMDItemFSContentChangeDate); кандидаты ревалидируются теми
  же проверками (маска/размер/дата + content) — результат идентичен обходу;
  ноль кандидатов/ошибка запроса → fallback на рекурсивный обход
  (корректность важнее скорости). Seam: протокол `SpotlightSearchable`
  (EnginesKit: `url(for:)`), конформанс `LocalVFS: @retroactive` — в App
  (обратное ребро VFSKit→EnginesKit запрещено слоями 04). Каталоги
  content-скану не подлежат.
  **SearchResultVFS** (VFSKit, `VFSKind.searchResults`): иммутабельный снимок
  hits; `listDirectory` возвращает их одним «каталогом» (id компонента =
  [index, name] — имена могут дублироваться), `openRead`/`metadata`
  ДЕЛЕГИРУЮТ в VFS-источник hit'а (F-3 просмотр и F-5 копирование из
  результатов работают через дефолтный `copyContents`), запись/удаление/
  переименование → `vfsUnsupported` (read-only). «Отправить в панель» = новый
  `PanelViewModel(source:)` + swap (модель SFTP-подключения, T-25). Диалог
  `ListViewKit/SearchDialog.swift`: маска/содержимое/regex/регистр/размер/
  даты/лимит, прогресс и отмена (⌘.) во время поиска, таблица результатов,
  кнопка «в панель». Команда `CommandID.searchFiles` — ⌘F (07 карта).
- **RenamePlanner** (F-14): вход — блок правил (маска-шаблон `[N]`, `[C]`, `[E]`, counter start/step/pad, replace/regex, регистр), выход — таблица old→new + conflicts (дубликаты новых имён, существующие целя); commit — batch через OperationExecutor (sort для стабильности).

  *Уточнение T-28 (F-14 v1):* **RenameRule** — `template: String` с токенами
  `[N]` (обработанное старое имя), `[C]` (счётчик: start/step/pad-ширина),
  `[E]` (расширение); `find`/`replacement`/`isRegex` (replace-блок по
  `NSRegularExpression` при regex); `caseStyle: .unchanged/.lowercase/.uppercase`;
  `extensionMode: .keep/.replace(String)/.remove` (переопределяет `[E]`).
  Семантика: расширение = суффикс после ПОСЛЕДНЕЙ точки (у каталогов и имён без
  точки расширения нет); токены, не указанные в шаблоне, НЕ добавляются
  (шаблон — единственный источник формы нового имени; `[C]` без pad = как есть).
  **RenamePlanner.plan(items: [VFSItem], rule: RenameRule) -> RenamePlan**:
  `pairs: [(old: VFSItem, newName: String)]` + `conflicts: [(index,
  kind: .duplicateTarget(newName) | .targetExists(newName))]` — конфликт
  `duplicateTarget` = результат совпал с другим результатом плана,
  `targetExists` = имя занято в каталоге (список имён каталога приходит от
  вызывающего — у панели он уже есть; переименование в то же имя у самого
  файла не конфликт); `unchanged` пары (new == old) в план не попадают.
  Invalid-результат (пусто, `/`, `.`/`..`) → конфликт `.invalidName(newName)`.
  **Commit**: `RenamePlanner.buildTransferPlan(pairs, in: parent) -> TransferPlan`
  — ОДИН план `.move` (same-volume rename(2), journal `renameBack` → undo F-6
  бесплатно) через per-run пару unified queue (05 §5.6 уточнение T-27); сортировка
  пар стабильна по old-name. Бюджет: план 10 000 имён ≤ 1 с (F-14 acceptance,
  perf-тест). **Диалог** (`ListViewKit/MultiRenameDialog.swift`, AppKit NSPanel
  по образцу PackDialog): поля правил + live-preview таблица old→new (конфликты
  — красным), Apply отключён при наличии конфликтов, Cancel = отмена до commit;
  сухой прогон = preview без Apply. Команда `CommandID.multiRename` — ⌘M
  (07 карта), tc-профиль ⇧F2.
- **SyncReporter** (F-15): сравнение двух деревьев по (name, size, mtime) или hash (parallel workers ≤ 4, sqlite-кэш hash) → матрица only-A/only-B/diff/equal → action-script (copy L→R / R→L / mirror (delete) с dry-run по умолчанию) → исполнение через TransferQueue.

  *Уточнение T-29 (F-15 v1):* **SyncReporter.compare(a:at:b:at:mode:cache:)**
  — рекурсивный обход ОБОИХ деревьев (`listDirectory` вниз от корней, стороны
  параллельно; хэширование — пул workers ≤ 4) → карта по ОТНОСИТЕЛЬНОМУ пути
  (slash-join компонентов) → матрица `onlyA / onlyB / differing / equal`:
  для каталогов достаточно наличия с обеих сторон (state = equal; содержимое
  считается по их файлам), расхождение типа (каталог vs файл) = `differing`.
  Режимы: `.metadata` — size точно, mtime с допуском 1 с (cross-filesystem
  точность), при `nil`-mtime — только size; `.content` — дополнительно
  SHA-256 стримом по `ByteStream` для файлов, РАВНЫХ по метаданным (по
  метаданным differing не хэшируется). **HashCache** — системный sqlite3
  (без сторонних зависимостей), ключ `instanceID.specID + "/" + path`,
  инваллидация: не совпали mtime/size → пересчёт и перезапись. **Action
  script**: `direction: .aToB / .bToA` + `mirror: Bool`; copy = onlyX +
  differing (каталог целиком — потомки в скрипт не дублируются), mirror
  добавляет delete лишнего на стороне приёмника (`deleteInB` при aToB,
  `deleteInA` при bToA); equal — без действий. Dry-run по умолчанию:
  диалог показывает матрицу и скрипт (таблица «действие → путь» = лог,
  F-15 acceptance); Apply — только после подтверждающего NSAlert.
  Исполнение: App строит планы через `TransferPlanner` (mkdir -p уже в
  планере, T-11) и ведёт через unified queue с per-run парами панелей
  (05 §5.6 уточнение T-27); policy copy = `.overwrite` (sync-семантика,
  покрыта подтверждением). Бюджет: дифф 100k записей ≤ 3 с (perf-тест на
  фейковом VFS). Диалог `ListViewKit/SyncDialog.swift`; команда
  `CommandID.comparePanels` — ⌘B (07 карта).

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

  *Уточнение T-31 (F-17 v1):* **TerminalPane** (`TerminalKit/TerminalPane.swift`,
  NSView) — хост `LocalProcessTerminalView` (`/bin/zsh -l`, cwd = путь активной
  панели; после смены панели — cwd последней сменившей путь панели; child
  переживает скрытие панели, v1 kill при закрытии окна — WindowController
  уничтожает вместе с собой). **TerminalPathSeeder** (`TerminalKit/
  TerminalPathSeeder.swift`, чистая логика): `posixQuoted(String)` —
  single-quotes, `'` → `'\''` (безопасно для пробелов/кавычек/`$`/`;`/unicode);
  `cdTo(URL)` — `cd -- <quoted>\n` (выполнение); `insertSequence(URL)` —
  quoted БЕЗ `\n` (вставка в набираемую команду). Auto-CD подписка: App
  сразу по событию `PanelViewModel.onPathChanged` (обе панели; сменившая
  путь панель = активная по факту движения), debounce 150 мс — без серии
  cd при быстрых навигациях. **⌃⇧V** — команда `CommandID.pastePath` (07
  map): App берёт курсорный/выделенный элемент активной панели (posix-путь
  LocalVFS; не-локальная панель — честная ошибка «вставка доступна только
  для локальных путей») и вызывает `TerminalPane.insert(path:)`; вставка
  и copy — SwiftTerm built-in. Резайз — AppKit (vertical stack-сегмент
  40 % высоты окна, 07 layout). Команда `CommandID.toggleTerminal` — ⌃`
  (keyCode 50, U+0060), обе профили keymap.

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
- **Контракт v1 (T-18 — F-21 MVP: шрифт панели, подтверждения удаления, внешний редактор, экспорт/импорт):**
```swift
enum SettingsSection: String, CaseIterable { case appearance, deletion, editor }
struct SettingsSchema: Codable, Sendable, Equatable {
    static let schemaVersion = 1
    var schemaVersion: Int
    // appearance: шрифт панели (family пуст = системный; mono-flag; size 9…24, default 13)
    var panelFontFamily: String; var panelFontSize: Double; var useMonospacedPanelFont: Bool
    // deletion: подтверждение при счёте ≥ threshold (default 5, 07 §7.3)
    var confirmDelete: Bool; var deleteConfirmThreshold: Int
    // editor: F-4; пусто = системный дефолт (NSWorkspace.open)
    var textEditorPath: String
}
@MainActor final class SettingsStore {
    init(url: URL = AppSupport «settings.json»)   // user-JSON мерж поверх defaults
    var onDidUpdate: (@MainActor (SettingsSchema) -> Void)?
    func update(_ mutate: (inout SettingsSchema) -> Void)   // apply + persist + fire
    func reset(_ section: SettingsSection)                  // defaults поля секции
    func export(to: URL) throws / func import(from: URL) throws
}
```
- Мерж: user JSON декодится в overridable поля (все optional) поверх defaults; schemaVersion ≠ 1 — user-файл игнорируется целиком (миграция — Migrations.swift будущая).
- Потребители (App): шрифт → `FileListView.applyPanelFont(NSFont?)` (NSFont строится в App — ServicesKit без AppKit); threshold/confirm → `beginDeleteSelection`; textEditorPath → `editFile` (`NSWorkspace.open(_:withApplicationAt:)`); кнопки окна настроек → Save/Import через NSSavePanel/NSOpenPanel. Ключи/тема/колонки/network-профили — M3.

  *Уточнение T-32 (F-21 «полные» v1):* секции → `appearance, deletion, editor,
  view, archive, terminal`; schemaVersion остаётся 1 (добавления — additive:
  новый user-JSON без новых ключей декодится дефолтами через optional-мердж).
  Новые поля: `columns: [ColumnID]` (DomainKit-enum, порядок = отображение в
  columns-режиме; `name` всегда первая — контракт §5.9; default
  `[name, size, dateModified]` = редактор full-набора; рендер-набор отрезает
  gitStatus до F-27), `filterStyle: String`
  («substring»/«fuzzy» → EnginesKit.FilterStyle в App; невалид → substring),
  `archiveAutoMount: Bool` (true = Enter на архиве респектирует §6.1
  openEntryHandler; false = App-драйвер не ставит handler → архив открывается
  VFS-ом или системным приложением), `terminalAutoCd: Bool` (06 §6.8
  «опция off» — App-фильтр followTerminalPath). Reset — «reset section»
  расширяется на новые секции. Скоуп-границы: **тема — T-33** (F-23);
  **редактор keymap — v1.x** (§5.7 API готов, UI — отдельная задача);
  **network-профили** — окно Connections (F-13), в схему настроек не входят.
  Перформанс-поверх сканирования нет: columns-настройка подаётся через
  существующий `onDidUpdate`, панели применяют диффом колонок.

- **KeymapStore**: профили (default TC-style / macOS-style / user), запись — `KeyCombo` (keyCode + modifiers), конфликты forbidden при сохранении;
- **LocationsStore** (закладки/Hotlist/история per-tab; hot-Slots 9);
- **ConnectionStore** + Keychain (kSecClassGenericPassword, service `MyCommander.connection.<id>`) — никогда не в JSON;
- **SessionStore**: перенастраиваемый список табов к моменту выхода (restore on launch).

*Уточнение T-24 (ConnectionStore — F-13, 05 §5.7):*
- `ConnectionsSnapshot` (`connections.json`, schemaVersion 1): `records: [ConnectionRecord]`.
  schemaVersion ≠ 1 → файл игнорируется целиком (по образцу SettingsStore); секретов в JSON
  нет никогда — только `keychainRef` (имя записи: UUID строки).
- **Keychain**: `KeychainStoring` протокол (`save/read/delete(service:account:) -> Data?`) +
  `KeychainBridge` (SecItem Add/CopyMatching/Update/Delete, kSecClassGenericPassword,
  service `MyCommander.connection.<id>`, account `secret` — пароль; `passphrase` — парольная
  фраза ключа). Протокол — seam для тестов (in-memory fake); реальный Keychain —
  env-gated smoke (`MC_KEYCHAIN_SMOKE=1`).
- **CRUD**: `create(record:secret:)` / `update(record:secret:)` / `delete(id)` (чистит
  keychain-записи) / `records()`; `secret(for:)` / `setSecret(_:for:)`;
  `pinHostKey(id:fingerprint:)` / `clearHostKeyPin(id)`. Атомарная запись JSON
  (`.atomic`), каталог `~/Library/Application Support/MyCommander/`.
- Подключение: `SftpConnection(config:)` строит App (ServicesKit не знает Citadel);
  при первом accept HostKeyPolicy возвращает fingerprint → `pinHostKey` persist.

*Уточнение T-26 (LocationsStore — F-11, 05 §5.7):*
- `LocationsSnapshot` (`locations.json`, schemaVersion 1): `bookmarks: [LocationBookmark]`,
  `recentFolders: [VFSPath]`. Чужая schemaVersion → файл игнорируется целиком.
- **Закладки**: CRUD (`addBookmark(name:target:panelHint:hotSlot:)` — ⌘D создаёт
  закладку активного каталога без слота; `update`/`remove`).
- **Hotlist — 9 слотов** (`assignHotSlot(_:for:)` / `clearHotSlot(_:)` /
  `hotSlot(_:)`): «двойная адресация» — навигация панели из `panelHint` (если задан),
  иначе активной панели; target `.connection(id)` → открыть подключение из
  ConnectionStore.
- **Недавние папки** (`noteVisit(_:)` / `recentFolders()`): dedupe (перемещение в
  начало), кольцо глубины 20; источник вызовов — `PanelTabList.onPathVisited`
  (ListViewKit), срабатывает на каждое отображённое место.
- **Back/forward per tab** — механизм из T-08 (`PanelTabList.navigateBack/Forward`);
  T-26 добавляет команды `navigateBack`/`navigateForward` (⌘[ / ⌘]) и пункты меню.

## 6.10 App target

- `MainWindowController`: layout (панели/терминал/командная строка/fullScreenModel), запоминает геометрию.
- `CommandRouter`: таблица CommandID → действие; remap — KeymapStore; все команды реализуются методами coordinator-классов (тестируемость).
- **OnboardingFlow (F-20)**: экран FDA → кнопка «Открыть System Settings» → процесс возврата (проверка по probe) → Safe Mode banner если отказано. Повторная навязка — max 2 раса, потом только банер.

- **Контракт v1 (T-17 — onboarding/AccessProbe F-20):**
- `VFSKit/AccessProbe.swift`: `AccessZone` (desktop/documents/downloads/library), `AccessReport { hasFullDiskAccess: Bool, grantedZones: [AccessZone] }`, `AccessMode { full, safe(zones: [AccessZone]), restricted }`; `classify(report)` — чистая логика (full → full, иначе safe по зонам, пусто → restricted — app не падает никогда); `probe(home:)` не-async, параметризуемый home для тестов: FDA-проба — читаемость `~/Library/Preferences/com.apple.dock.plist` (TCC-защищённый файл; чтение без FDA проваливается), зона — успешное `contentsOfDirectory` (ошибка → не granted, пустой список → granted).
- `ServicesKit/OnboardingState.swift`: чистая модель правила «max 2 навязки» (§6.10): `shouldOfferInitial` (не hidden && presented==0), `canOfferAgain` (не hidden && presented<2), `afterPresentation()`, `hidden permanently`; персист в UserDefaults — только App ( ключи `mc.onboarding.*`).
- App `OnboardingFlow` (non-modal окно): пояснение FDA + «Открыть System Settings» (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`) + «Продолжить без Full Disk Access» + «Не показывать снова»; probe-обновление на каждом `NSApplicationDidBecomeActive` (granted → окно закрывается, mode → full). Статус: `FileListView.accessBadge: String?` (App пишет локализованную строку «FDA» / «SAFE …» — включается в статус-строку). Safe-первый запуск без сессии: seed панели — первая granted-зона (иначе home).
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
