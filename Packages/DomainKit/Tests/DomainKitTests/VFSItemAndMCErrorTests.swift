// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import DomainKit

private let instance = VFSInstanceID(kind: .archive, specID: "test.zip")

@Test func itemCarriesContractFields() {
    let path = VFSPath(root: instance, components: ["report.pdf"], displayURL: nil)
    let item = VFSItem(
        id: path,
        instance: instance,
        name: "report.pdf",
        kind: .file,
        attributes: VFSItemAttributes(size: 2048, modified: Date(timeIntervalSince1970: 0)),
        revision: 7
    )
    #expect(item.id == path)
    #expect(item.name == "report.pdf")
    #expect(item.attributes.size == 2048)
    #expect(item.revision == 7)
    #expect(item.isDirectory == false)
}

@Test func mcErrorProducesReadableMessages() {
    let path = VFSPath(root: instance, components: ["secrets.txt"])
    let denied = MCError.vfsAccessDenied(path, underlying: nil)
    #expect(denied.errorDescription == "Access denied: \"secrets.txt\"")

    let conflict = MCError.transferConflict(
        source: VFSPath(root: instance, components: ["a.txt"]),
        target: VFSPath(root: instance, components: ["b.txt"])
    )
    #expect(conflict.errorDescription?.contains("b.txt") == true)

    let canceled = MCError.canceled
    #expect(canceled.errorDescription?.contains("canceled") == true)
}

@Test func mcErrorKeepsUnderlyingContext() {
    let cause = NSError(domain: "MCErrorTests", code: 42)
    let wrapped = MCError.unexpected(underlying: cause)
    #expect((wrapped.underlyingError as? NSError)?.code == 42)

    let denied = MCError.vfsAccessDenied(
        VFSPath(root: instance, components: ["x"]),
        underlying: cause
    )
    #expect((denied.underlyingError as? NSError)?.domain == "MCErrorTests")
    #expect(MCError.canceled.underlyingError == nil)
}

private func requireSendable<T: Sendable>(_ value: T) { _ = value }

@Test func contractValueTypesAreSendable() {
    let base = VFSPath.local(URL(fileURLWithPath: "/tmp/mc"))
    requireSendable(base)
    requireSendable(base.root)
    requireSendable(VFSKind.archive)
    requireSendable(VFSInstanceID(kind: .sftp, credentialRef: nil, specID: "c1"))
    requireSendable(VFSItemKind.symlink(target: base))
    requireSendable(VFSItemAttributes(tags: ["Work"]))
    requireSendable(VFSItem(
        id: base,
        instance: base.root,
        name: "test.zip",
        kind: .file,
        attributes: VFSItemAttributes(size: 1),
        revision: 3
    ))
    requireSendable(SortCriteria(key: .name, order: .ascending, dirsFirst: true))
    requireSendable(ColumnID.gitStatus)
    requireSendable(ViewPreset(columns: [.name], widths: [0: 100], sort: SortCriteria(key: .name)))
    requireSendable(GlobMask("*.swift", caseSensitive: false))
    requireSendable(FileMask(["*.swift", "*.m"]))
    requireSendable(ByteSizeFormat.Style.binary)
}
