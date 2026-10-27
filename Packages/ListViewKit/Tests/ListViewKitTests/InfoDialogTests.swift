// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import DomainKit
@testable import ListViewKit

// T-15: the info card (F-19, 06 §6.11 v1) — pure field building, stable
// rendering of sizes/permissions/dates, the compose text and the background
// size replacement. Helpers use the `id` name-space (the test module compiles
// neighbouring files together).

private func idLocalRoot(
    kind: VFSKind = .localDisk,
    specID: String = "unknown"
) -> (id: VFSInstanceID, path: (String) -> VFSPath) {
    let id = VFSInstanceID(kind: kind, specID: specID)
    let path: (String) -> VFSPath = { name in VFSPath(root: id, components: [name]) }
    return (id, path)
}

private func idAttributes(
    size: Int64? = nil,
    created: Date? = nil,
    modified: Date? = nil,
    permissions: Int16? = nil,
    owner: String? = nil,
    group: String? = nil,
    tags: [String] = []
) -> VFSItemAttributes {
    var attributes = VFSItemAttributes()
    attributes.size = size
    attributes.created = created
    attributes.modified = modified
    attributes.posixPermissions = permissions
    attributes.owner = owner
    attributes.group = group
    attributes.tags = tags
    return attributes
}

/// Fixed calendar piece (no DST traps at this clock).
private func idDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: components)!
}

@Test func idBuilderFileFields() {
    let root = idLocalRoot()
    let item = VFSItem(
        id: root.path("notes.md"),
        instance: root.id,
        name: "notes.md",
        kind: .file,
        attributes: idAttributes(
            size: 2048,
            created: idDate(year: 2024, month: 2, day: 29, hour: 13, minute: 44),
            modified: idDate(year: 2026, month: 10, day: 25, hour: 9, minute: 5),
            permissions: 420,   // 0o644
            owner: "dmit",
            group: "staff",
            tags: ["Work", "Review"]
        )
    )
    let fields = InfoFieldBuilder.fields(for: item)
    #expect(InfoDisplay.compose(fields).contains("notes.md"))
    #expect(fields.first?.kind == .name)
    // The size row (2048 B) — «2 KB»; the tag row joins with «, »; the rest
    // exact values from the stable formatters.
    #expect(fields.first(where: { $0.kind == .size })?.value == "2 KB")
    #expect(fields.first(where: { $0.kind == .permissions })?.value == "rw-r--r-- (644)")
    #expect(fields.first(where: { $0.kind == .owner })?.value == "dmit")
    #expect(fields.first(where: { $0.kind == .tags })?.value == "Work, Review")
    #expect(fields.first(where: { $0.kind == .modified })?.value == "2026-10-25 09:05")
}

@Test func idBuilderDirectoryFieldsRenderDashes() {
    let root = idLocalRoot()
    let item = VFSItem(
        id: root.path("Docs"),
        instance: root.id,
        name: "Docs",
        kind: .directory,
        attributes: idAttributes()   // no size/dates/perms/owner — directory walk fills later
    )
    let fields = InfoFieldBuilder.fields(for: item)
    #expect(fields.first(where: { $0.kind == .size })?.value == "—")
    #expect(fields.first(where: { $0.kind == .created })?.value == "—")
    #expect(fields.first(where: { $0.kind == .permissions })?.value == "—")
    #expect(fields.first(where: { $0.kind == .tags })?.value == "—")

    // The background pass replaces the size row (06 §6.11).
    let updated = InfoDisplay.updatingSize(fields, size: 1_500_000)
    #expect(updated.first(where: { $0.kind == .size })?.value == "1.4 MB")
    #expect(updated.first(where: { $0.kind == .kind })?.value ==
        fields.first(where: { $0.kind == .kind })?.value)   // untouched
}

@Test func idBytesFormatStable() {
    #expect(InfoBytes.format(0) == "0 B")
    #expect(InfoBytes.format(999) == "999.0 B" || InfoBytes.format(999) == "999 B")
    #expect(InfoBytes.format(1024) == "1 KB")
    #expect(InfoBytes.format(1536) == "1.5 KB")
    #expect(InfoBytes.format(99) == "99 B")
    #expect(InfoBytes.format(1024 * 1024) == "1 MB")
    #expect(InfoBytes.format(1_500_000) == "1.4 MB")
    #expect(InfoBytes.format(1024 * 1024 * 1024) == "1 GB")
    #expect(InfoBytes.format(-5) == "0 B")
}

@Test func idPermissionsAndDatesFormat() {
    #expect(InfoPermissions.format(0o644) == "rw-r--r-- (644)")
    #expect(InfoPermissions.format(0o755) == "rwxr-xr-x (755)")
    #expect(InfoPermissions.format(0o600) == "rw------- (600)")
    #expect(InfoPermissions.format(0o000) == "--------- (0)")

    #expect(InfoDates.format(nil) == "—")
    #expect(InfoDates.format(idDate(year: 2026, month: 3, day: 7, hour: 8, minute: 9)) == "2026-03-07 08:09")
}

@Test func idDisplayComposeJoinsRows() {
    let fields = [
        InfoField(kind: .name, label: "name", value: "readme.txt"),
        InfoField(kind: .size, label: "size", value: "12 B")
    ]
    #expect(InfoDisplay.compose(fields) == "name: readme.txt\nsize: 12 B")
}
