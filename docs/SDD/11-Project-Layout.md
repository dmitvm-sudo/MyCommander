# 11. Карта репозитория (файлы и ответственность)

Один файл = одна главная история ответственности, где возможно. Тесты — colocated: `Packages/<X>/Tests/<X>Tests/`.

```
MyCommander/
├── LICENSE                          # GPL-3.0-or-later
├── NOTICE.md                        # полный список third-party + их лицензии
├── README.md                        # что это, сборка, скриншоты, contributing
├── AGENTS.md                        # правила для AI-агентов: читать docs/SDD/README.md
├── .github/workflows/
│   ├── ci.yml                       # build + test (macOS) + lint + license-check + perf-budget
│   └── release.yml                  # подпись, notarization, DMG, Sparkle-appcast
├── .swiftlint.yml / .swiftformat
├── docs/SDD/                        # эта спецификация (12 файлов + README)
├── research/                        # фактура исследования Фаз 1–2
│
├── App/                             # главный target (без бизнес-логики)
│   ├── MyCommanderApp.swift         # entry, lifecycle
│   ├── MainWindowController.swift   # layout окна, геометрия, split
│   ├── PanelsCoordinator.swift      # активная/противоположная панели, диспетчер операций
│   ├── CommandRouter.swift          # CommandID → действие (единственный dispatch)
│   ├── MenuBuilder.swift            # главное меню = отражение keymap-профиля
│   ├── Onboarding/OnboardingFlow.swift        # FDA-онбординг F-20
│   ├── Onboarding/AccessProbe.swift           # мягкая проба доступа
│   ├── Dialogs/                     # SwiftUI-обёртки: Settings, About, Go-to-folder
│   └── Resources/                   # Assets, MainMenu.xib, keymap-tc.json,
│                                    # keymap-macos.json, theme-ncblue.json,
│                                    # en.lproj/ + ru.lproj/Localizable.strings (F-22,
│                                    # T-35: ЕДИНЫЙ мастер-каталог всего UI; пакеты
│                                    # резолвят через Bundle.main = app-bundle)
│
├── Packages/DomainKit/              # чистая модель (0 UI-зависимостей)
│   ├── Sources/DomainKit/
│   │   ├── VFSItem.swift            # VFSItemKind, VFSItemAttributes, VFSItem
│   │   ├── VFSPath.swift            # VFSInstanceID, VFSPath, нормализация
│   │   ├── VFS.swift                # протокол VFS + VFSRegistryProtocol
│   │   ├── VFSCapabilities.swift
│   │   ├── ByteStream.swift         # ByteStream / ByteStreamWriter
│   │   ├── WatchEvents.swift        # FileWatchEngineProtocol, WatchEvent, DirectoryDiff
│   │   ├── TransferModels.swift     # TransferPlan, Conflict*, TransferEvent, JournalRecord
│   │   ├── MCError.swift
│   │   ├── SortCriteria.swift       # сортировка/колонки/ViewPreset
│   │   └── Masks.swift              # глоб-маски, размеры (200 кБ «1,2 MB»)
│   └── Tests/DomainKitTests/
│
├── Packages/VFSKit/
│   ├── LocalVFS.swift               # POSIX-адаптер (list/stat/copyContents/rm…)
│   ├── LocalVFS+Attributes.swift    # xattr/тэги/FinderInfo
│   ├── VolumeMonitor.swift          # mount/unmount → VFSInstanceID
│   ├── FSEventsWatcher.swift        # FSEvents → DirectoryDiff, self-suppression
│   ├── ArchiveVFS.swift             # оболочка VFS над читателями
│   ├── Archive/ZipReader.swift      # ZIPFoundation
│   ├── Archive/TarReader.swift      # SWCompression (tar/gz/xz/bz2)
│   ├── Archive/ZipWriter.swift      # ZIPFoundation: Pack-профиля
│   ├── Archive/SevenZipReader.swift # SWCompression (v1.0 SHOULD)
│   ├── Sftp/SftpConnection.swift    # T-23: lifetime/connect/errno-маппинг
│   ├── Sftp/HostKeyPolicy.swift     # T-24: fingerprint + pinning-policy (custom delegate)
│   ├── Sftp/SftpPrivateKey.swift    # T-24: OpenSSH Ed25519 (незашифр.) парсер
│   ├── Sftp/SftpVFS.swift           # T-23: SFTP-адаптер (5.3-операции, seekable, staging)
│   ├── SearchResultVFS.swift        # виртуальная папка результатов поиска
│   ├── VFSRegistry.swift            # инстансы, mountedVolumes()
│   └── InMemoryVFS.swift            # тестовый fake + errno-инжекция
│
├── Packages/FileOpsKit/
│   ├── TransferPlanner.swift        # план: деревья, конфликты, same-volume/clone
│   ├── ConflictModels.swift         # policy struct
│   ├── OperationExecutor.swift      # actor, воркер-пул (4), транзакции
│   ├── Transactions/CopyTransaction.swift   # clonefile / fcopyfile + temp+rename
│   ├── Transactions/MoveTransaction.swift   # rename(2) vs cross-volume
│   ├── Transactions/DeleteTransaction.swift # tree-walk, trash
│   ├── JournalStorage.swift         # кольцевой буфер undo-записей
│   ├── UndoPlanner.swift            # T-20: реверс-план по JournalRecord
│   ├── ZipPack.swift                 # T-22: pack-flow zip (ZipPackSpec/Planner/Task)
│   └── TransferEvents.swift         # public AsyncStream-канал прогресса
│
├── Packages/EnginesKit/
│   ├── FilterEngine.swift           # F-10
│   ├── SearchEngine.swift           # F-16
│   ├── NSMetadataQueryBridge.swift  # Spotlight-first путь
│   ├── ByteScan.swift               # content-скан стримом
│   ├── RenamePlanner.swift          # F-14
│   ├── RenameRule.swift             # T-28: правило multi-rename (маска/replace/регистр/расширение)
│   ├── SyncReporter.swift           # F-15 (diff-матрица, mirror)
│   └── HashCache.swift              # sqlite-кэш хэшей для sync
│
├── Packages/ListViewKit/
│   ├── PanelViewModel.swift         # @MainActor: список/фильтр/сортировка/selection
│   ├── FileListView.swift           # NSTableView cell-based, diff-батчи
│   ├── ListItemCells.swift          # NameCell/MetaCell, бейджи
│   ├── ItemCache.swift              # иконки LRU, folder-size
│   ├── DiffUpdate.swift             # вычисление батчей для таблицы
│   ├── PanelTabsView.swift          # таб frac A/B
│   ├── FocusController.swift        # единая модель фокуса
│   ├── ProgressWindow.swift         # очередь операций UI
│   ├── ConflictDialog.swift         # конфликты F-5
│   ├── ListerWindow.swift           # text/hex/image стрим
│   ├── InfoDialog.swift             # F-19
│   ├── CommandBar.swift             # ⌘L, автодополнение
│   └── Theme.swift                  # темы, шрифты, accent
│
├── Packages/TerminalKit/
│   ├── TerminalPane.swift           # SwiftTerm host, ⌃`
│   └── ShellSession.swift           # PTY lifecycle, auto-cd
│
├── Packages/ServicesKit/
│   ├── SettingsStore.swift          # default-merge, JSON, apply-live
│   ├── KeymapStore.swift            # профили, конфликты
│   ├── LocationsStore.swift         # закладки/hotlist/история F-11
│   ├── ConnectionStore.swift        # Connections F-13 (без секретов)
│   ├── KeychainBridge.swift         # kSecGenericPassword обёртка
│   ├── SessionStore.swift           # restore-сессия табов
│   ├── Migrations.swift             # schemaVersion
│   └── LogScrubber.swift            # маскирование путей в экспорте лога
│
├── Tools/fixture-generator/         # SPM-утилита генерации деревьев/файлов
├── Tools/license-check.sh           # N-10: NOTICE ↔ Package.resolved
├── Tools/localization-check.sh      # F-22 lint: UI-литералы без букв, ключи ↔ .strings
├── Tools/release/                   # T-37 релиз-конвейерка (03 N-9):
│   ├── Info.plist.in                #   шаблон CFBundle*/SUFeedURL/EdDSA-ключ
│   ├── build-app.sh                 #   .app: бинарный + ресурсы + Sparkle + подпись
│   ├── make-dmg.sh                  #   UDZO-образ (+ symlink /Applications)
│   ├── notarize.sh                  #   notarytool submit --wait + stapler
│   └── update-appcast.sh            #   appcast.xml items (beta-канал по ‑betaN)
└── Tests/SharedFixtures/            # golden-архивы, ключи ssh (CI), образы-скрипты
```

Зависимости сторонние (Package.resolved контролирует CI): ZIPFoundation, SWCompression, swift-nio-ssh, Citadel, SwiftTerm, (позже AMSMB2, aws-sdk-swift, Sparkle). Все — пермиссивные, совместимые с GPL-3.0 (N-10).
