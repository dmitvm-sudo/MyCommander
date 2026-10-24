// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics
import Testing
@testable import DomainKit

private let instance = VFSInstanceID(kind: .localDisk, specID: "sort-test")

private func makeItem(
    _ name: String,
    kind: VFSItemKind = .file,
    size: Int64? = 1,
    modified: Date? = nil
) -> VFSItem {
    VFSItem(
        id: VFSPath(root: instance, components: [name]),
        instance: instance,
        name: name,
        kind: kind,
        attributes: VFSItemAttributes(size: size, modified: modified)
    )
}

@Test func namesCompareLocaleAwareWithNumberOrdering() {
    let items = [makeItem("file10.txt"), makeItem("file2.txt"), makeItem("File1.txt")]
    let sorted = items.sortedItems(by: [SortCriteria(key: .name)])
    #expect(sorted.map(\.name) == ["File1.txt", "file2.txt", "file10.txt"])
}

@Test func directoriesFirstRegardlessOfOrderAndKey() {
    let items = [
        makeItem("b.txt"),
        makeItem("dirA", kind: .directory, size: 5),
        makeItem("a.txt"),
        makeItem("dirB", kind: .directory, size: 9),
    ]
    let byNameDescending = items.sortedItems(by: [SortCriteria(key: .name, order: .descending)])
    #expect(byNameDescending.map(\.name) == ["dirB", "dirA", "b.txt", "a.txt"])

    let bySizeDescending = items.sortedItems(by: [SortCriteria(key: .size, order: .descending)])
    #expect(bySizeDescending.map(\.name).prefix(2) == ["dirB", "dirA"])
}

@Test func sizeWithoutMeasurementSortsAsMinusOne() {
    let unmeasured = makeItem("pending.txt", kind: .file, size: nil)
    let empty = makeItem("empty.txt", size: 0)
    let big = makeItem("big.txt", size: 1_000)
    let sorted = [big, empty, unmeasured].sortedItems(by: [SortCriteria(key: .size, dirsFirst: false)])
    #expect(sorted.map(\.name) == ["pending.txt", "empty.txt", "big.txt"])
}

@Test func extensionCriterionSortsByExtension() {
    let items = [makeItem("a.zip"), makeItem("b.txt"), makeItem("c.txt"), makeItem("d.gz")]
    let sorted = items.sortedItems(by: [SortCriteria(key: .`extension`)])
    let extensions = sorted.compactMap { vfsFileExtension(of: $0.name) }
    #expect(extensions == ["gz", "txt", "txt", "zip"])
}

@Test func fileExtensionHelperFollowsClassicSemantics() {
    #expect(vfsFileExtension(of: "makefile") == nil)
    #expect(vfsFileExtension(of: ".hidden") == nil)
    #expect(vfsFileExtension(of: "a.tar.gz") == "gz")
    #expect(vfsFileExtension(of: "readme.") == nil)
}

@Test func viewPresetPersistsThroughJSON() throws {
    let preset = ViewPreset(
        columns: [.name, .size, .dateModified],
        widths: [0: 240, 1: 96],
        sort: SortCriteria(key: .modified, order: .descending)
    )
    let encoded = try JSONEncoder().encode(preset)
    let decoded = try JSONDecoder().decode(ViewPreset.self, from: encoded)
    #expect(decoded.columns == preset.columns)
    #expect(decoded.widths == preset.widths)
    #expect(decoded.sort.key == preset.sort.key)
    #expect(decoded.sort.order == preset.sort.order)
    #expect(decoded.sort.dirsFirst == preset.sort.dirsFirst)
}
