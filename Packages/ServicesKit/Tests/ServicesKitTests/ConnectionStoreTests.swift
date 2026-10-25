// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation
import Testing
@testable import ServicesKit

// T-24 acceptance (F-13, docs/SDD/12): the connection store keeps secrets in
// the Keychain ONLY — the JSON carries keychainRef names; CRUD round-trips,
// pin bookkeeping, deletion cleaning and the foreign-schema guard are covered
// with an in-memory keychain fake. The REAL KeychainBridge runs env-gated
// (`MC_KEYCHAIN_SMOKE=1`) so CI never touches the user's login keychain.

/// Dictionary-backed `KeychainStoring` (the test seam from 06 §6.9).
private final class FakeKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    private func key(_ service: String, _ account: String) -> String {
        "\(service)#\(account)"
    }

    func save(_ secret: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key(service, account)] = secret
    }

    func read(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key(service, account)]
    }

    func delete(service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key(service, account))
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}

private func tempStoreURL(_ label: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("connstore-\(label)-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("connections.json")
}

@Suite("ConnectionStore (F-13, T-24)")
struct ConnectionStoreTests {

    @Test func crudRoundTrip() {
        let keychain = FakeKeychain()
        let store = ConnectionStore(storageURL: tempStoreURL("crud"), keychain: keychain)
        let record = ConnectionRecord(name: "server", host: "example.org", username: "root")

        store.save(record)
        store.setPassword("s3cret", for: record.id)
        #expect(store.records().count == 1)
        #expect(store.record(id: record.id)?.host == "example.org")

        var updated = record
        updated.port = 2_202
        store.save(updated)
        #expect(store.records().count == 1)   // insert-or-update, not append
        #expect(store.record(id: record.id)?.port == 2_202)
        #expect(store.password(for: record.id) == "s3cret")

        store.delete(id: record.id)
        #expect(store.records().isEmpty)
        #expect(store.password(for: record.id) == nil)
        #expect(keychain.count == 0)   // both keychain entries cleaned
    }

    @Test func secretsNeverPersistInJSON() throws {
        let keychain = FakeKeychain()
        let url = tempStoreURL("nojson")
        let store = ConnectionStore(storageURL: url, keychain: keychain)
        let id = UUID()
        let record = ConnectionRecord(
            id: id,
            name: "secretive",
            host: "example.org",
            username: "root",
            auth: .password(keychainRef: id.uuidString)
        )
        store.save(record)
        store.setPassword("super-secret-password", for: record.id)

        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(!json.contains("super-secret-password"))
        #expect(json.contains("keychainRef"))   // the ref name IS persisted
        #expect(store.password(for: record.id) == "super-secret-password")
    }

    @Test func pinRoundTrip() {
        let store = ConnectionStore(storageURL: tempStoreURL("pin"), keychain: FakeKeychain())
        let record = ConnectionRecord(name: "pinned", host: "example.org", username: "root")
        store.save(record)
        #expect(record.hostKeyFingerprint == nil)

        store.pinHostKey(id: record.id, fingerprint: "SHA256:abc")
        #expect(store.record(id: record.id)?.hostKeyFingerprint == "SHA256:abc")

        store.clearHostKeyPin(id: record.id)
        #expect(store.record(id: record.id)?.hostKeyFingerprint == nil)
        #expect(store.record(id: record.id)?.host == "example.org")   // other fields intact
    }

    @Test func foreignSchemaVersionIsIgnored() throws {
        let url = tempStoreURL("schema")
        let store = ConnectionStore(storageURL: url, keychain: FakeKeychain())
        store.save(ConnectionRecord(name: "old", host: "example.org", username: "root"))
        #expect(store.records().count == 1)

        // A foreign version makes the whole file ignored (06 §6.9).
        let raw = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        try raw.write(to: url, atomically: true, encoding: .utf8)
        #expect(store.records().isEmpty)
    }

    @Test func missingFileStartsEmpty() {
        let store = ConnectionStore(storageURL: tempStoreURL("empty"), keychain: FakeKeychain())
        #expect(store.records().isEmpty)
        #expect(store.record(id: UUID()) == nil)
    }

    @Test func serviceNameContract() {
        let id = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000000")!
        #expect(ConnectionStore.serviceName(for: id) == "MyCommander.connection.\(id.uuidString)")
    }

    /// The REAL keychain — manual smoke only (`MC_KEYCHAIN_SMOKE=1`).
    @Test func realKeychainSmoke() throws {
        guard ProcessInfo.processInfo.environment["MC_KEYCHAIN_SMOKE"] == "1" else {
            return
        }
        let bridge = KeychainBridge()
        let service = "MyCommander.connection.smoke-\(UUID().uuidString)"
        try bridge.save(Data("smoke-secret".utf8), service: service, account: "secret")
        #expect(bridge.read(service: service, account: "secret") == Data("smoke-secret".utf8))
        try bridge.save(Data("rotated".utf8), service: service, account: "secret")
        #expect(bridge.read(service: service, account: "secret") == Data("rotated".utf8))
        bridge.delete(service: service, account: "secret")
        #expect(bridge.read(service: service, account: "secret") == nil)
    }
}
