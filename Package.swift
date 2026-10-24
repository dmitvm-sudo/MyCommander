// swift-tools-version:6.3
import PackageDescription

/// SPM-граф (docs/SDD/11-Project-Layout.md): 7 библиотек-модулей + исполняемый таргет-скелет.
/// Сторонние зависимости добавляются только после записи в NOTICE.md (гейт N-10).
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
    "VFSKit": ["DomainKit"],   // T-03: InMemoryVFS конформит VFS из DomainKit
    "EnginesKit": ["DomainKit"],   // T-07: FilterEngine оперирует DomainKit-типами (FileMask)
    "ListViewKit": ["DomainKit", "EnginesKit"],   // T-05 UI + T-07 панель фильтрует через FilterEngine (слой 04)
    "ServicesKit": ["DomainKit"],   // T-08: SessionStore сериализует VFSPath (§5.1 Codable)
]

/// Зависимости, нужные ТОЛЬКО тест-таргетам (fake-адаптеры VFSKit в UI-тестах:
/// реальный листинг через LocalVFS/InMemoryVFS без подключения VFSKit к библиотеке).
let testDependencyNames: [String: [String]] = [
    "ListViewKit": ["VFSKit"],
]

let libraries: [Target] = modules.map { module in
    let dependencies = (moduleDependencyNames[module.name] ?? []).map { Target.Dependency.byName(name: $0) }
    return Target.target(name: module.name, dependencies: dependencies, path: "\(module.path)/Sources/\(module.name)")
}

let testTargets: [Target] = modules.map { module in
    let extra = (moduleDependencyNames[module.name] ?? []).map { Target.Dependency.byName(name: $0) }
        + (testDependencyNames[module.name] ?? []).map { Target.Dependency.byName(name: $0) }
    return Target.testTarget(
        name: "\(module.name)Tests",
        dependencies: [.byName(name: module.name)] + extra,
        path: "\(module.path)/Tests/\(module.name)Tests"
    )
}

let executable: Target = .executableTarget(
    name: "MyCommander",
    dependencies: modules.map { .byName(name: $0.name) },
    path: "App"
)

let package = Package(
    name: "MyCommander",
    platforms: [.macOS(.v14)],
    targets: libraries + [executable] + testTargets
)
