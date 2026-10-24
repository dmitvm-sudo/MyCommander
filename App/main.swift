// Точка входа (заглушка T-01). UI собирается в T-05+ (docs/SDD/09-Milestones-Roadmap.md).
// Пока исполнимая цель нужна только для smoke-проверки графа: линкует все модули.
import DomainKit
import EnginesKit
import FileOpsKit
import ListViewKit
import ServicesKit
import TerminalKit
import VFSKit

let modules = [
    DomainKitBuildInfo.moduleName,
    VFSKitBuildInfo.moduleName,
    FileOpsKitBuildInfo.moduleName,
    EnginesKitBuildInfo.moduleName,
    ListViewKitBuildInfo.moduleName,
    TerminalKitBuildInfo.moduleName,
    ServicesKitBuildInfo.moduleName,
]

print("MyCommander skeleton (M0). Modules linked: \(modules.joined(separator: ", "))")
