// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation
import Testing
@testable import EnginesKit

// T-28 acceptance (F-14, docs/SDD/12): the multi-rename planner — template
// tokens ([N]/[C]/[E]), counter start/step/pad, replace (plain + regex),
// case styles, extension modes, directory stems, conflict detection and the
// one-`.move`-plan commit; the 10 000-name preview budget ≤ 1 s.

private func renameItem(_ name: String, isDirectory: Bool = false) -> VFSItem {
    let root = VFSInstanceID(kind: .localDisk, specID: "rename-tests")
    let path = VFSPath(root: root, components: name.isEmpty ? [] : [name])
    return VFSItem(
        id: path,
        instance: root,
        name: name,
        kind: isDirectory ? .directory : .file,
        attributes: VFSItemAttributes(
            size: 10, created: nil, modified: nil, posixPermissions: nil,
            owner: nil, group: nil, isHidden: false, isReadOnly: false, tags: [], urlResourceMeta: [:]
        )
    )
}

private func plannedNames(_ plan: RenamePlan) -> [[String]] {
    plan.pairs.map { [$0.item.name, $0.newName] }
}

@Suite("RenamePlanner (F-14, T-28)")
struct RenamePlannerTests {

    // MARK: template tokens

    @Test func templateTokensStemCounterExtension() {
        let rule = RenameRule(template: "[N]_[C].[E]", counterStart: 5, counterStep: 2)
        let plan = RenamePlanner.plan(
            items: [renameItem("photo.jpg"), renameItem("photo.png")],
            rule: rule,
            occupiedNames: ["photo.jpg", "photo.png"]
        )
        #expect(plan.isValid)
        #expect(plannedNames(plan) == [["photo.jpg", "photo_5.jpg"], ["photo.png", "photo_7.png"]])
    }

    @Test func counterPadPadsWithZeros() {
        let rule = RenameRule(template: "img_[C]", counterStart: 1, counterStep: 1, counterPad: 4)
        let plan = RenamePlanner.plan(
            items: [renameItem("a"), renameItem("b")],
            rule: rule,
            occupiedNames: ["a", "b"]
        )
        #expect(plannedNames(plan) == [["a", "img_0001"], ["b", "img_0002"]])
    }

    @Test func templateWithoutTokensIsLiteralDuplicate() {
        // The template is the ONLY source of the shape: no tokens = the same
        // literal for everyone → duplicate conflict (red in the dialog).
        let plan = RenamePlanner.plan(
            items: [renameItem("a"), renameItem("b")],
            rule: RenameRule(template: "same-name"),
            occupiedNames: ["a", "b"]
        )
        #expect(!plan.isValid)
        #expect(plan.conflicts.allSatisfy { if case .duplicateTarget = $0.kind { return true }; return false })
    }

    // MARK: replace / regex / case

    @Test func plainReplaceAndCaseStyles() {
        var rule = RenameRule(template: "[N]", find: "IMG", replacement: "pic")
        #expect(plannedNames(RenamePlanner.plan(items: [renameItem("IMG_0001")], rule: rule, occupiedNames: [])) == [["IMG_0001", "pic_0001"]])

        rule.caseStyle = .uppercase
        #expect(plannedNames(RenamePlanner.plan(items: [renameItem("report")], rule: rule, occupiedNames: [])) == [["report", "REPORT"]])
        rule.caseStyle = .lowercase
        #expect(plannedNames(RenamePlanner.plan(items: [renameItem("REPORT")], rule: rule, occupiedNames: [])) == [["REPORT", "report"]])
    }

    @Test func regexReplaceUsesNSRegularExpression() {
        let rule = RenameRule(template: "[N]", find: "^(\\d{4})-(\\d{2})-", replacement: "$2.$1.", isRegex: true)
        let plan = RenamePlanner.plan(
            items: [renameItem("2024-03-report")],
            rule: rule,
            occupiedNames: []
        )
        #expect(plannedNames(plan) == [["2024-03-report", "03.2024.report"]])
    }

    // MARK: extension semantics

    @Test func extensionKeepSurvivesTheSuffix() {
        // «a.tar.gz»: stem «a.tar», ext «gz» — a stem-only change keeps .gz.
        let plan = RenamePlanner.plan(
            items: [renameItem("a.tar.gz")],
            rule: RenameRule(template: "[N]_copy"),
            occupiedNames: ["a.tar.gz"]
        )
        #expect(plannedNames(plan) == [["a.tar.gz", "a.tar_copy.gz"]])
    }

    @Test func extensionReplaceAndRemoveModes() {
        let replace = RenameRule(template: "[N]", extensionMode: .replace("txt"))
        #expect(plannedNames(RenamePlanner.plan(items: [renameItem("photo.raw")], rule: replace, occupiedNames: ["photo.raw"])) == [["photo.raw", "photo.txt"]])

        let remove = RenameRule(template: "[N]", extensionMode: .remove)
        #expect(plannedNames(RenamePlanner.plan(items: [renameItem("photo.raw")], rule: remove, occupiedNames: ["photo.raw"])) == [["photo.raw", "photo"]])
    }

    @Test func directoriesRenameWholeWithoutExtension() {
        // A directory «v1.2» has NO extension — the ext mode must not graft
        // a suffix onto it.
        let plan = RenamePlanner.plan(
            items: [renameItem("v1.2", isDirectory: true)],
            rule: RenameRule(template: "[N]_v2", extensionMode: .replace("txt")),
            occupiedNames: ["v1.2"]
        )
        #expect(plannedNames(plan) == [["v1.2", "v1.2_v2"]])
    }

    // MARK: conflicts

    @Test func unchangedNamesAreNotPlanned() {
        let plan = RenamePlanner.plan(
            items: [renameItem("photo.jpg")],
            rule: RenameRule(template: "[N]"),
            occupiedNames: ["photo.jpg"]
        )
        #expect(plan.pairs.isEmpty && plan.conflicts.isEmpty)
    }

    @Test func targetExistsOnlyForForeignNames() {
        let conflict = RenamePlanner.plan(
            items: [renameItem("x")],
            rule: RenameRule(template: "renamed_[C]"),
            occupiedNames: ["x", "renamed_1"]
        )
        #expect(!conflict.isValid)
        #expect(conflict.conflicts.first?.kind == .targetExists(newName: "renamed_1"))
    }

    @Test func invalidNamesConflict() {
        let slash = RenamePlanner.plan(
            items: [renameItem("a")],
            rule: RenameRule(template: "dir/[N]"),
            occupiedNames: ["a"]
        )
        #expect(slash.conflicts.first?.kind == .invalidName(newName: "dir/a"))

        let empty = RenamePlanner.plan(
            items: [renameItem("x")],
            rule: RenameRule(template: "", extensionMode: .remove),
            occupiedNames: ["x"]
        )
        #expect(empty.conflicts.first?.kind == .invalidName(newName: ""))
    }

    // MARK: commit plan

    @Test func buildTransferPlanSortsAndTargetsParent() {
        let items = [renameItem("b.txt"), renameItem("a.txt"), renameItem("c.txt")]
        let plan = RenamePlanner.plan(
            items: items,
            rule: RenameRule(template: "file_[C]", counterStart: 1),
            occupiedNames: ["b.txt", "a.txt", "c.txt"]
        )
        #expect(plan.isValid)
        let parent = VFSPath(root: VFSInstanceID(kind: .localDisk, specID: "root"), components: ["docs"])
        let transfer = RenamePlanner.buildTransferPlan(pairs: plan.pairs, in: parent)
        #expect(transfer.op == .move)
        #expect(transfer.conflicts.isEmpty)
        // Counters follow the SELECTION order (b, a, c → 1, 2, 3); the plan is
        // sorted stable by old name only for execution stability (06 §6.6).
        #expect(transfer.items[0].source.components == ["a.txt"])
        #expect(transfer.items[0].target.components == ["docs", "file_2.txt"])
        #expect(transfer.items[1].source.components == ["b.txt"])
        #expect(transfer.items[1].target.components == ["docs", "file_1.txt"])
        #expect(transfer.items[2].target.components == ["docs", "file_3.txt"])
    }

    // MARK: budget (F-14 acceptance: 10 000 names ≤ 1 s)

    @Test func tenThousandNamesPlanUnderASecond() {
        let items = (0 ..< 10_000).map { renameItem("file-\($0).txt") }
        let rule = RenameRule(template: "batch_[C].[E]", counterStart: 1, counterStep: 1, counterPad: 5)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = RenamePlanner.plan(items: items, rule: rule, occupiedNames: Set(items.map(\.name)))
        }
        #expect(elapsed < .seconds(1))
        let dryRun = RenamePlanner.plan(items: items, rule: rule, occupiedNames: Set(items.map(\.name)))
        #expect(dryRun.pairs.count == 10_000)
    }
}
