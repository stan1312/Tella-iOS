//  SPECTRE Capture — SpectreCore
//  Persistence abstractions. On iOS the SecretStore is backed by the Keychain
//  (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, never synchronised) and the
//  queue directory lives in Application Support, excluded from backups.

import Foundation

/// Small secrets: device credential, per-capture outbox keys, resumable session URLs.
public protocol SecretStore: AnyObject, Sendable {
    func set(_ data: Data, for key: String) throws
    func get(_ key: String) throws -> Data?
    func delete(_ key: String) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func set(_ data: Data, for key: String) throws { lock.lock(); items[key] = data; lock.unlock() }
    public func get(_ key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return items[key] }
    public func delete(_ key: String) throws { lock.lock(); items[key] = nil; lock.unlock() }
    public var allKeys: [String] { lock.lock(); defer { lock.unlock() }; return Array(items.keys) }
}

/// File-backed secret store used ONLY by tests to simulate an app restart.
public final class FileSecretStoreForTests: SecretStore, @unchecked Sendable {
    private let dir: URL
    public init(directory: URL) throws {
        dir = directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    private func url(_ key: String) -> URL { dir.appendingPathComponent(SpectreCrypto.sha256Hex(Data(key.utf8))) }
    public func set(_ data: Data, for key: String) throws { try data.write(to: url(key), options: .atomic) }
    public func get(_ key: String) throws -> Data? { try? Data(contentsOf: url(key)) }
    public func delete(_ key: String) throws {
        let u = url(key)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
    }
}

public enum SecretKeys {
    public static let deviceCredentials = "spectre.device.credentials"
    public static func outboxKey(_ id: CaptureID) -> String { "spectre.outbox.key.\(id)" }
    public static func session(_ id: CaptureID) -> String { "spectre.upload.session.\(id)" }
}

/// Durable queue of capture records (one JSON file per capture, atomic writes).
public protocol QueueStore: Sendable {
    func load(_ id: CaptureID) throws -> CaptureRecord?
    func save(_ record: CaptureRecord) throws
    func all() throws -> [CaptureRecord]
    func remove(_ id: CaptureID) throws
}

public final class FileQueueStore: QueueStore, @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// Hook so the iOS layer can apply NSFileProtection / backup exclusion.
    public var didWriteFile: ((URL) -> Void)?

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    private func url(_ id: CaptureID) -> URL {
        // captureId is a lowercase UUID; refuse anything else (path traversal).
        directory.appendingPathComponent("capture-\(id).json")
    }

    public func load(_ id: CaptureID) throws -> CaptureRecord? {
        guard Validation.isUUID(id) else { return nil }
        lock.lock(); defer { lock.unlock() }
        let u = url(id)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try decoder.decode(CaptureRecord.self, from: Data(contentsOf: u))
    }

    public func save(_ record: CaptureRecord) throws {
        guard Validation.isUUID(record.captureId) else { throw SpectreError.invalidCaptureId }
        lock.lock(); defer { lock.unlock() }
        let u = url(record.captureId)
        try encoder.encode(record).write(to: u, options: .atomic)
        didWriteFile?(u)
    }

    public func all() throws -> [CaptureRecord] {
        lock.lock(); defer { lock.unlock() }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names.filter { $0.hasPrefix("capture-") && $0.hasSuffix(".json") }
            .compactMap { try? decoder.decode(CaptureRecord.self, from: Data(contentsOf: directory.appendingPathComponent($0))) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func remove(_ id: CaptureID) throws {
        guard Validation.isUUID(id) else { return }
        lock.lock(); defer { lock.unlock() }
        let u = url(id)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
    }
}

public enum Validation {
    public static func isUUID(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return s.allSatisfy { $0 == "-" || ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
    public static func isSHA256Hex(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

public enum SpectreError: Error, Equatable {
    case invalidCaptureId
    case outboxCorrupted
    case outboxKeyMissing
    case outboxRange
    case notEnrolled
    case invalidEnrollmentPayload(String)
    case backend(code: String, message: String)
    case transport(String)
    case http(status: Int)
    case sessionExpired
    case protocolViolation(String)
}
