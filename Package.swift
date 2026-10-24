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

let libraries: [Target] = modules.map { module in
    Target.target(name: module.name, path: "\(module.path)/Sources/\(module.name)")
}

let testTargets: [Target] = modules.map { module in
    Target.testTarget(
        name: "\(module.name)Tests",
        dependencies: [.byName(name: module.name)],
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
