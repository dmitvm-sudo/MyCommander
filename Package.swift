// swift-tools-version:6.3
import PackageDescription

/// SPM-граф (docs/SDD/11-Project-Layout.md): 7 библиотек-модулей + исполняемый таргет-скелет.
/// Сторонние зависимости добавляются только после записи в NOTICE.md (гейт N-10).
/// Внешние пакеты (T-21: NOTICE-таблица): ZIPFoundation — zip read/write,
/// SWCompression — gz/xz/bz2-read контейнеры (связаны с VFSKit, F-12).
let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    .package(url: "https://github.com/tsolomko/SWCompression", from: "4.5.0"),
    // T-23 (F-13): SSH/SFTP client; NOTICE-таблица (MIT) — до подключения (N-10).
    .package(url: "https://github.com/orlandos-nl/Citadel", from: "0.12.1"),
    // T-23: NIOConcurrencyHelpers (NIOLockedValueBox) для async-safe примитивов
    // SftpVFS; прямая dep, т.к. продукты транзитивного swift-nio не импортируются.
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
    // T-23: NIOSSH (тест-стенд: SSHServer host keys + auth delegate) — продукт
    // форка, на который пинится Citadel 0.12.1 (NOTICE: Apache-2.0).
    .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", from: "0.3.4"),
]

let modules: [(name: String, path: String)] = [
    ("DomainKit", "Packages/DomainKit"),
    ("VFSKit", "Packages/VFSKit"),
    ("FileOpsKit", "Packages/FileOpsKit"),
    ("EnginesKit", "Packages/EnginesKit"),
    ("ListViewKit", "Packages/ListViewKit"),
    ("TerminalKit", "Packages/TerminalKit"),
    ("ServicesKit", "Packages/ServicesKit"),
]

/// Межмодульные зависимости (docs/SDD/11). Дополняются по мере реализации модулей.
let moduleDependencyNames: [String: [String]] = [
    "VFSKit": ["DomainKit", "ZIPFoundation", "SWCompression", "Citadel", "NIOSSH", "NIOConcurrencyHelpers"],   // T-21: ArchiveVFS (zip read — ZIPFoundation; gz/xz/bz2 — SWCompression); InMemoryVFS конформит VFS; T-23: SftpVFS/SftpConnection (Citadel + NIOConcurrencyHelpers); T-24: HostKeyPolicy (NIOSSH delegate)
    "EnginesKit": ["DomainKit"],   // T-07: FilterEngine оперирует DomainKit-типами (FileMask)
    "ListViewKit": ["DomainKit", "EnginesKit", "FileOpsKit"],   // T-05 UI + T-07 фильтр + T-10 ProgressWindow (слои 04)
    "ServicesKit": ["DomainKit"],   // T-08: SessionStore сериализует VFSPath (§5.1 Codable)
    "FileOpsKit": ["DomainKit", "VFSKit", "ZIPFoundation"],   // T-10: планы/executor над VFS; локальные ветки через LocalVFS (слои 04); T-22: pack-flow zip (ZIPFoundation)
    "TerminalKit": ["DomainKit"],   // T-14: ShellSession exec-ветка мапит ошибки в MCError (§5.8)
]

/// Зависимости, нужные ТОЛЬКО тест-таргетам (fake-адаптеры VFSKit в UI-тестах:
/// реальный листинг через LocalVFS/InMemoryVFS без подключения VFSKit к библиотеке).
let testDependencyNames: [String: [String]] = [
    "ListViewKit": ["VFSKit"],
    "VFSKit": ["NIOEmbedded"],   // T-24: EmbeddedEventLoop для promise-тестов политики
]   // NIOSSH VFSKitTests получает через moduleDependencyNames["VFSKit"] (одно ребро — иначе SPM duplicate-product warning)

/// T-23: byName-зависимость «NIOConcurrencyHelpers» (продукт транзитивного до
/// сих пор swift-nio) не резолвится — нужна явная product-ссылка.
func dependency(named name: String) -> Target.Dependency {
    if name == "NIOConcurrencyHelpers" {
        return .product(name: "NIOConcurrencyHelpers", package: "swift-nio")
    }
    if name == "NIOSSH" {
        // byName не резолвит (см. T-23 урок) — только явная product-ссылка.
        return .product(name: "NIOSSH", package: "swift-nio-ssh")
    }
    if name == "NIOEmbedded" {
        return .product(name: "NIOEmbedded", package: "swift-nio")
    }
    return Target.Dependency.byName(name: name)
}

let libraries: [Target] = modules.map { module in
    let dependencies = (moduleDependencyNames[module.name] ?? []).map(dependency(named:))
    return Target.target(name: module.name, dependencies: dependencies, path: "\(module.path)/Sources/\(module.name)")
}

let testTargets: [Target] = modules.map { module in
    let extra = (moduleDependencyNames[module.name] ?? []).map(dependency(named:))
        + (testDependencyNames[module.name] ?? []).map(dependency(named:))
    // T-21: golden archive containers live in the VFSKit test bundle (Fixtures/).
    let resources: [Resource] = module.name == "VFSKit" ? [.copy("Fixtures")] : []
    return Target.testTarget(
        name: "\(module.name)Tests",
        dependencies: [.byName(name: module.name)] + extra,
        path: "\(module.path)/Tests/\(module.name)Tests",
        resources: resources
    )
}

let executable: Target = .executableTarget(
    name: "MyCommander",
    dependencies: modules.map { .byName(name: $0.name) },
    path: "App",
    resources: [.process("Resources")]   // T-09: keymap-*.json (docs/SDD/11)
)

let package = Package(
    name: "MyCommander",
    platforms: [.macOS(.v14)],
    dependencies: dependencies,
    targets: libraries + [executable] + testTargets
)
