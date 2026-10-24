// SPDX-License-Identifier: GPL-3.0-or-later

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
    "DomainKit",
    "VFSKit",
    "FileOpsKit",
    "EnginesKit",
    "ListViewKit",
    "TerminalKit",
    "ServicesKit",
]

// T-07: EnginesKit is a real module now (FilterEngine) — smoke-check its surface.
print(
    "MyCommander skeleton (M0). Modules linked: \(modules.joined(separator: ", "))"
    + " · FilterEngine matches: \(FilterEngine.matches(name: "a.txt", query: "A", style: .substring))"
)
