// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation
import Security

// Contract: docs/SDD/06 §6.9 (уточнение T-24) + 05 §5.7 (ConnectionRecord) —
// F-13 connection management. `connections.json` holds NO secrets — only
// `keychainRef` names; passwords/passphrases live in the Keychain
// (kSecClassGenericPassword, service `MyCommander.connection.<id>`). The
// `KeychainStoring` protocol is the test seam (in-memory fake); the real
// bridge is exercised by an env-gated smoke test. A foreign schemaVersion
// makes the file ignored entirely (по образцу SettingsStore; Migrations.swift
// governs future bumps).

// MARK: model

public enum ConnectionKind: String, Codable, Sendable, CaseIterable {
    case sftp
}

/// 05 §5.7: `.password(keychainRef)` / `.privateKey(path, passphraseRef)`.
public enum ConnectionAuthMethod: Codable, Sendable, Equatable {
    case password(keychainRef: String)
    case privateKey(path: String, passphraseRef: String?)
}

public struct ConnectionRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: ConnectionKind
    public var host: String
    public var port: Int
    public var username: String
    public var auth: ConnectionAuthMethod
    public var hostKeyFingerprint: String?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ConnectionKind = .sftp,
        host: String,
        port: Int = 22,
        username: String,
        auth: ConnectionAuthMethod = .password(keychainRef: ""),
        hostKeyFingerprint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.hostKeyFingerprint = hostKeyFingerprint
    }
}

public struct ConnectionsSnapshot: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var records: [ConnectionRecord]

    public init(records: [ConnectionRecord] = []) {
        self.schemaVersion = Self.schemaVersion
        self.records = records
    }
}

// MARK: keychain seam

public protocol KeychainStoring: Sendable {
    /// Inserts or replaces the secret; throws `MCError.unexpected` on a
    /// Security-layer failure (05 §5.8: errors are MCError at the boundary).
    func save(_ secret: Data, service: String, account: String) throws
    func read(service: String, account: String) -> Data?
    func delete(service: String, account: String)
}

/// The real Keychain wrapper (SecItem, generic password class).
public final class KeychainBridge: KeychainStoring, Sendable {
    public init() {}

    public func save(_ secret: Data, service: String, account: String) throws {
        delete(service: service, account: account)   // delete-then-add = update
        var query = Self.baseQuery(service: service, account: account)
        query[kSecValueData as String] = secret
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MCError.unexpected(underlying: Self.error(status))
        }
    }

    public func read(service: String, account: String) -> Data? {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    public func delete(service: String, account: String) {
        SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func error(_ status: OSStatus) -> Error {
        NSError(domain: "MyCommander.Keychain", code: Int(status))
    }
}

// MARK: store

/// File-backed connection store + Keychain secret plumbing (06 §6.9).
/// Thread-safe by construction: the storage URL is immutable, JSON writes are
/// atomic, and the keychain is the system's own synchronization point.
public final class ConnectionStore: @unchecked Sendable {
    public static let keychainServicePrefix = "MyCommander.connection."

    private let storageURL: URL
    private let keychain: any KeychainStoring

    public static func defaultStorageURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("MyCommander", isDirectory: true)
            .appendingPathComponent("connections.json")
    }

    public init(storageURL: URL = ConnectionStore.defaultStorageURL(), keychain: any KeychainStoring = KeychainBridge()) {
        self.storageURL = storageURL
        self.keychain = keychain
    }

    // MARK: JSON records

    /// Empty on a missing/corrupted/foreign-version file (06 §6.9).
    public func records() -> [ConnectionRecord] {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let snapshot = try? JSONDecoder().decode(ConnectionsSnapshot.self, from: data),
              snapshot.schemaVersion == ConnectionsSnapshot.schemaVersion
        else { return [] }
        return snapshot.records
    }

    public func record(id: UUID) -> ConnectionRecord? {
        records().first { $0.id == id }
    }

    /// Insert-or-update of the JSON record (secrets untouched — use
    /// `setPassword`/`setPassphrase` explicitly).
    public func save(_ record: ConnectionRecord) {
        var records = records()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        persist(ConnectionsSnapshot(records: records))
    }

    /// Removes the record AND both of its keychain entries.
    public func delete(id: UUID) {
        persist(ConnectionsSnapshot(records: records().filter { $0.id != id }))
        keychain.delete(service: Self.serviceName(for: id), account: Self.Account.password)
        keychain.delete(service: Self.serviceName(for: id), account: Self.Account.passphrase)
    }

    // MARK: secrets

    public enum Account {
        public static let password = "secret"
        public static let passphrase = "passphrase"
    }

    public static func serviceName(for id: UUID) -> String {
        keychainServicePrefix + id.uuidString
    }

    public func password(for id: UUID) -> String? {
        keychain.read(service: Self.serviceName(for: id), account: Account.password)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setPassword(_ password: String?, for id: UUID) {
        setSecret(password.flatMap { Data($0.utf8) }, account: Account.password, id: id)
    }

    public func passphrase(for id: UUID) -> String? {
        keychain.read(service: Self.serviceName(for: id), account: Account.passphrase)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setPassphrase(_ passphrase: String?, for id: UUID) {
        setSecret(passphrase.flatMap { Data($0.utf8) }, account: Account.passphrase, id: id)
    }

    private func setSecret(_ data: Data?, account: String, id: UUID) {
        let service = Self.serviceName(for: id)
        if let data {
            try? keychain.save(data, service: service, account: account)
        } else {
            keychain.delete(service: service, account: account)
        }
    }

    // MARK: host-key pinning (F-13)

    /// Pins the accepted fingerprint on first use / after explicit re-trust.
    public func pinHostKey(id: UUID, fingerprint: String) {
        guard var record = record(id: id) else { return }
        record.hostKeyFingerprint = fingerprint
        save(record)
    }

    public func clearHostKeyPin(id: UUID) {
        guard var record = record(id: id) else { return }
        record.hostKeyFingerprint = nil
        save(record)
    }

    // MARK: persistence

    private func persist(_ snapshot: ConnectionsSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let directory = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: .atomic)
    }
}
