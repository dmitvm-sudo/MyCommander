# 05. Модель данных и контракты (DomainKit)

Целевые интерфейсы. Имена типов/методов в реализации могут отличаться, но семантика контрактов — точная.

## 5.1 Идентичность и пути

```swift
/// Источник данных. Стабильный ID одного открытого «диска» (том, архив, SFTP-сессия…).
struct VFSInstanceID: Hashable, Codable, Sendable {
    var kind: VFSKind          // .localDisk / .archive / .sftp / (.smb, .s3 — v1.x)
    var credentialRef: UUID?   // для Connections (Keychain-привязка)
    var specID: String         // локальный: volume UUID; архив: file identity; sftp: connection id
}

/// Путь внутри источника. Не URL: компоненты — работает и для архивов/SFTP.
struct VFSPath: Hashable, Sendable {
    var root: VFSInstanceID
    var components: [String]   // нормализованные сегменты без ".."; "/" от root
    var displayURL: URL?       // nil для виртуальных источников (для QL/Finder-действий)
    static func local(_ url: URL) -> VFSPath
}
```

## 5.2 Элементы файловой системы

```swift
enum VFSItemKind: Sendable { case directory, file, symlink(target: VFSPath?), special }

struct VFSItemAttributes: Sendable {
    var size: Int64?                    // nil для директорий до подсчёта
    var created: Date?; var modified: Date?
    var posixPermissions: Int16?
    var owner: String?; var group: String?
    var isHidden: Bool; var isReadOnly: Bool
    var tags: [String]                  // macOS-тэги (только LocalVFS)
    var urlResourceMeta: [String: String] // опциональные доп. поля (custom columns)
}

struct VFSItem: Identifiable, Sendable {
    var id: VFSPath                     // стабильный на глубину сессии
    var instance: VFSInstanceID
    var name: String                    // displayName
    var kind: VFSItemKind
    var attributes: VFSItemAttributes
    var revision: UInt64                // ревизия снапшота каталога при получении
}
```

`VFSItem` — value-тип (Sendable), восстанавливается из кэша без disk hit; «расчётные» поля (folder size) идут отдельным асинхронным запросом и хранятся в `ItemExtraCache` панели.

## 5.3 Главный протокол

```swift
protocol VFS: AnyObject, Sendable {
    var id: VFSInstanceID { get }
    var capabilities: VFSCapabilities { get }

    func listDirectory(at path: VFSPath) async throws -> [VFSItem]
    func metadata(of path: VFSPath) async throws -> VFSItem
    func directorySize(of path: VFSPath, progress: ProgressSink?) async throws -> Int64

    func createDirectory(_ name: String, in parent: VFSPath) async throws -> VFSPath
    func rename(_ path: VFSPath, to name: String) async throws -> VFSPath
    func delete(_ paths: [VFSPath], toTrash: Bool) async throws
    func copyContents(from: VFSPath, to: VFS, target: VFSPath) async throws  // server-side copy, если умеет

    func openRead(_ path: VFSPath) async throws -> ByteStream
    func openWrite(_ path: VFSPath, replace: Bool) async throws -> ByteStreamWriter
    func setAttributes(_ path: VFSPath, mutate: (inout VFSItemAttributes) -> Void) async throws
}

struct VFSCapabilities: Sendable {
    var canWrite, canDelete, canRename: Bool
    var canWatch, canRandomSeek: Bool
    var preservesDates, symlinkSupport: Bool
    var maxPathLength: Int?
}
```

Реализации (VFSKit): `LocalVFS`, `ArchiveVFS`, `SftpVFS`; фейк `InMemoryVFS` — для тестов. Фабрика:

```swift
protocol VFSRegistryProtocol: Sendable {
    func instance(for root: VFSInstanceID) -> VFS
    func register(_ vfs: VFS) async
    func mountedVolumes() async -> [VFSInstanceID]   // для «дисков»/volume picker
}
```

## 5.4 Наблюдение

```swift
protocol FileWatchEngineProtocol: Sendable {
    func watch(_ path: VFSPath, options: WatchOptions) -> AsyncStream<WatchEvent>
}
enum WatchEvent: Sendable {
    case itemsChanged(diff: DirectoryDiff)   // наборы added/removed/updated
    case volumeEvent(volume: VFSInstanceID, mounted: Bool)
}
```
`LocalVFS` → FSEvents (coalescing 300 мс, suspend при собственных операциях, чтобы не «себя пинг-понжить»); non-watchable VFS возвращают пустой stream, UI делает prefetch-обновление при возвращении майинта панели.

## 5.5 Потоки ввода/вывода

```swift
protocol ByteStream: Sendable {
    var length: Int64 { get async throws }
    func readChunk(max: Int) async throws -> Data?  // завершает nil
}
protocol ByteStreamWriter: Sendable {
    func write(_ data: Data) async throws
    func finish(committingTo finalTarget: VFSPath) async throws  // temp→rename
}
```
Используются: Lister (читает стрим-окно), FileOpsKit (копирует чанками 1–4 MB), QL-export из архивов.

## 5.6 Движок операций (FileOpsKit)

```swift
enum TransferOpKind: Sendable { case copy, move, delete, link }
struct TransferItem: Sendable { var source: VFSPath; var target: VFSPath; var item: VFSItem }

struct TransferPlan: Sendable {
    var op: TransferOpKind
    var items: [TransferItem]
    var conflicts: [Conflict]              // предрасчёт на момент планирования
}

enum ConflictResolution: Sendable {
    case overwrite, skip, keepBoth, cancel
    case applyToAll(ConflictResolution)    // «для всех»
}

struct TransferEvent: Sendable {
    enum Phase: Sendable { case started, itemProgress(file: Double), itemDone, itemFailed(MCError), paused, resumed, finished(Summary) }
    var phase: Phase; var queuePosition: Int; var completedBytes: Int64; var totalBytes: Int64
}

actor OperationExecutorProtocol {
    func enqueue(_ plan: TransferPlan, policy: ConflictPolicy) -> AsyncStream<TransferEvent>
    func pause(_ id: OperationID) / resume / cancel
}
```

**Journal (undo):**
```swift
struct JournalRecord: Codable, Sendable {
    var timestamp: Date; var op: TransferOpKind
    var reversals: [Reversal]   // для каждого файла: что вернуть (rename back, восстановить из корзины по пути, удалить созданный temp)
}
```
Undo поддерживается только reversal-операциями выше (см. F-6); всё остальное — «undo недоступен».

## 5.7 Настройки и персистентность (ServicesKit)

```swift
struct Settings: Codable { // секции: general, panels, operations, themes, terminal, advanced
    var confirmOnDelete: Bool = true
    var defaultTargetBehindPanels: Bool = true // F5 идёт в противоположную панель
    var quickSearchMode: .substring / .fuzzy / .prefix
    var editorExternalPath: String? = nil
    var viewerFont: NSFontDescriptor?; var panelFont: ...
    var theme: ThemeID
    var forcedLocale: String? // nil = системный
}

struct KeymapEntry: Codable, Hashable { var combo: KeyCombo; var command: CommandID; var context: CommandContext }
struct ConnectionRecord: Codable, Identifiable {
    var id: UUID; var name: String; var kind: .sftp
    var host: String; var port: Int = 22; var username: String
    var auth: AuthMethod                    // .password(keychainRef) / .privateKey(path, passphraseRef)
    var hostKeyFingerprint: String?         // pinning на первый accept
}
struct LocationBookmark: Codable { var name: String; var target: Either<VFSPath, ConnectionID>; var panelHint: PanelSide?; var hotSlot: Int? }
```

Хранение: `~/Library/Application Support/MyCommander/` — `settings.json`, `keymap.json`, `locations.json`, `connections.json` (секреты — Keychain), `sessions.json` (открытые табы). Schema versioning: число `schemaVersion` + миграции в `ServicesKit/Migrations/`.

## 5.8 Ошибки

```swift
enum MCError: Error, LocalizedError {
    case vfsAccessDenied(VFSPath, underlying: Error?)
    case vfsNotFound(VFSPath)
    case vfsUnsupported(VFSInstanceID, String)
    case transferConflict(source: VFSPath, target: VFSPath)
    case interrupted(reason: String)
    case network(VFSInstanceID, code: String)     // sftp/smb/...
    case canceled
    case unexpected(underlying: Error)            // с контекстом для логов
}
```
Каждый case — локализуемое сообщение + «детали» (errno/оригинал). Диалоги translated в `ListViewKit/Dialogs`.

## 5.9 Пресеты и сортировка

```swift
struct SortCriteria: Sendable { var key: SortKey; var order: SortOrder; var dirsFirst: Bool = true }
enum SortKey: Sendable { case name, extension, size, modified, created, kind }
struct ViewPreset: Codable { var columns: [ColumnID]; var widths: [Int: CGFloat]; var sort: SortCriteria }
enum ColumnID: String, Codable, CaseIterable { // name, size, dateModified, dateCreated, kind, tags, permissions, owner, gitStatus(provider v1.x), custom(string from provider)
}
```
