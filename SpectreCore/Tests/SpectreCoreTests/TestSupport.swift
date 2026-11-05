import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SpectreCore

enum Repo {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

final class TestClock: @unchecked Sendable {
    private var offset: TimeInterval = 0
    private let lock = NSLock()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date().addingTimeInterval(offset) }
    func advance(_ s: TimeInterval) { lock.lock(); offset += s; lock.unlock() }
}

/// Deterministic synthetic "video" bytes (fictional data only).
func syntheticBytes(_ n: Int, seed: UInt32 = 1) -> Data {
    var x = seed
    var d = Data(count: n)
    d.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
        for i in 0..<n { x = x &* 1664525 &+ 1013904223; p[i] = UInt8(x >> 24) }
    }
    return d
}

func tempDir(_ name: String = "spectre") -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// Launches backend/mock-stack/server.mjs (real Apps Script code + MockDrive).
final class MockStack {
    let base: URL
    let webApp: URL
    private let process: Process
    private let stdinPipe: Pipe

    static func nodePath() -> String? {
        if let p = ProcessInfo.processInfo.environment["SPECTRE_NODE"] { return p }
        for c in ["/opt/node22/bin/node", "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"] where FileManager.default.isExecutableFile(atPath: c) { return c }
        return nil
    }

    init() throws {
        guard let node = Self.nodePath() else { throw XCTSkip("node not found: mock stack unavailable (set SPECTRE_NODE)") }
        process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [Repo.root.appendingPathComponent("backend/mock-stack/server.mjs").path, "--port=0"]
        let out = Pipe(); stdinPipe = Pipe()
        process.standardOutput = out
        process.standardInput = stdinPipe
        try process.run()
        var buffer = ""
        let deadline = Date().addingTimeInterval(15)
        while !buffer.contains("\n") && Date() < deadline {
            let d = out.fileHandleForReading.availableData
            if d.isEmpty { usleep(20_000); continue }
            buffer += String(decoding: d, as: UTF8.self)
        }
        guard let line = buffer.split(separator: "\n").first(where: { $0.hasPrefix("MOCK_STACK_READY ") }),
              let u = URL(string: String(line.dropFirst("MOCK_STACK_READY ".count))) else {
            process.terminate()
            throw NSError(domain: "MockStack", code: 1, userInfo: [NSLocalizedDescriptionKey: "mock stack did not start: \(buffer)"])
        }
        base = u
        webApp = u.appendingPathComponent("macros/s/MOCK/exec")
    }

    func stop() {
        try? stdinPipe.fileHandleForWriting.close()
        process.terminate()
        process.waitUntilExit()
    }

    private func request(_ path: String, method: String = "GET", json: Any? = nil) async throws -> Any {
        let t = URLSessionTransport()
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let r = try await t.send(SpectreHTTPRequest(method: method, url: URL(string: base.absoluteString + path)!, body: body))
        return try JSONSerialization.jsonObject(with: r.body)
    }

    func control(_ c: [String: Any]) async throws { _ = try await request("/__control", method: "POST", json: c) }
    func inviteLink(label: String = "membre-test") async throws -> String {
        (try await request("/__admin/invite?label=\(label)") as! [String: Any])["link"] as! String
    }
    func revoke(_ deviceId: String) async throws { _ = try await request("/__admin/revoke?deviceId=\(deviceId)") }
    func ownerFiles() async throws -> [[String: Any]] {
        (try await request("/__owner/files") as! [String: Any])["files"] as! [[String: Any]]
    }
    func ownerDownload(_ id: String) async throws -> Data {
        try await URLSessionTransport().send(SpectreHTTPRequest(method: "GET", url: URL(string: base.absoluteString + "/__owner/content?id=\(id)")!)).body
    }
    func dropsDone() async throws -> Int {
        (try await request("/__owner/files") as! [String: Any])["dropsDone"] as! Int
    }
    func backendLogs() async throws -> [String] {
        (try await request("/__admin/logs") as! [String: Any])["logs"] as! [String]
    }
    func rawHTTP(_ method: String, _ url: URL, headers: [String: String] = [:]) async throws -> Int {
        try await URLSessionTransport().send(SpectreHTTPRequest(method: method, url: url, headers: headers)).status
    }
}

/// Stand-in for the Tella vault entry (encrypted container + DB row) used in tests.
final class FakeVault: LocalCopyHandler, @unchecked Sendable {
    let kind = LocalCopyKind.vaultEntry
    let dir: URL
    var failDeletes = false
    init(dir: URL) { self.dir = dir; try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    func add(_ id: String, _ data: Data) { try! data.write(to: dir.appendingPathComponent(id)) }
    func delete(_ ref: LocalCopyRef) throws {
        if failDeletes { throw NSError(domain: "FakeVault", code: 1) }
        try FileManager.default.removeItem(at: dir.appendingPathComponent(ref.reference))
    }
    func exists(_ ref: LocalCopyRef) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(ref.reference).path) }
}

/// One simulated phone: stores, outbox, engine wired to a backend.
struct Phone {
    let root: URL
    let secrets: SecretStore
    let store: FileQueueStore
    let outbox: EncryptedOutbox
    let vault: FakeVault
    let engine: DepositEngine
    let logs: MemoryLogSink
    let clock: TestClock

    static func make(root: URL = tempDir("phone"), backend: DepositBackend? = nil, transport: SpectreHTTPTransport = URLSessionTransport(timeout: 20),
                     chunk: Int = 512 * 1024, verifier: ReceiptVerifier = ReceiptVerifier(),
                     retry: RetryPolicy = RetryPolicy(baseDelay: 0, maxDelay: 0, maxAutomaticAttempts: 6, maxPendingChecks: 10)) throws -> Phone {
        let secrets = try FileSecretStoreForTests(directory: root.appendingPathComponent("keychain"))
        let store = try FileQueueStore(directory: root.appendingPathComponent("queue"))
        let outbox = try EncryptedOutbox(directory: root.appendingPathComponent("outbox"), secrets: secrets, segmentSize: 64 * 1024)
        let vault = FakeVault(dir: root.appendingPathComponent("vault"))
        let logs = MemoryLogSink()
        let clock = TestClock()
        let deletion = DeletionCoordinator(handlers: [
            OutboxCopyHandler(outbox: outbox), vault,
            FileCopyHandler(kind: .plaintextTemp, allowedRoot: root.appendingPathComponent("tmp")),
            FileCopyHandler(kind: .cameraOriginalTemp, allowedRoot: root.appendingPathComponent("tmp")),
        ])
        let engine = DepositEngine(store: store, outbox: outbox, secrets: secrets,
                                   backend: backend ?? HTTPDepositBackend(transport: transport),
                                   uploader: ResumableUploader(transport: transport, chunkSize: chunk),
                                   verifier: verifier, deletion: deletion, retry: retry,
                                   clock: { clock.now() }, log: SpectreLog(sink: logs))
        return Phone(root: root, secrets: secrets, store: store, outbox: outbox, vault: vault, engine: engine, logs: logs, clock: clock)
    }

    /// Simulates "stop recording": camera temp file + vault entry + durable task + outbox.
    func capture(_ bytes: Data, captureId: String = UUID().uuidString.lowercased()) async throws -> String {
        let tmp = root.appendingPathComponent("tmp"); try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let cam = tmp.appendingPathComponent("movie-\(captureId).mov")
        try bytes.write(to: cam)
        vault.add("vault-\(captureId)", Data("ENCRYPTED-BY-TELLA".utf8) + bytes.prefix(16))
        try await engine.register(captureId: captureId, mimeType: "video/quicktime", fileExtension: "mov", localCopies: [
            LocalCopyRef(kind: .vaultEntry, reference: "vault-\(captureId)"),
            LocalCopyRef(kind: .cameraOriginalTemp, reference: cam.path),
        ])
        _ = try await engine.prepare(captureId: captureId, plaintextURL: cam, expectedSHA256: SpectreCrypto.sha256Hex(bytes))
        return captureId
    }

    func enroll(_ stack: MockStack, transport: SpectreHTTPTransport = URLSessionTransport()) async throws -> DeviceCredentials {
        let invite = try EnrollmentParser.parse(try await stack.inviteLink(), allowInsecureLocalhost: true)
        return try await CredentialVault(secrets: secrets).enroll(using: invite, backend: HTTPDepositBackend(transport: transport))
    }

    /// Drives the engine until a terminal/halted state (bounded).
    @discardableResult
    func run(_ id: String, maxPasses: Int = 40, until: ((CaptureRecord) -> Bool)? = nil) async -> CaptureRecord {
        var last: CaptureRecord?
        for _ in 0..<maxPasses {
            last = await engine.process(id)
            guard let r = last else { break }
            if let u = until, u(r) { break }
            if [.completed, .blocked].contains(r.stage) { break }
            if let f = r.failure, f.nextAttemptAt == nil { break }   // halted: needs a human / enrolment
            if r.failure?.kind == .network { usleep(500_000) }       // let the simulated network come back
            clock.advance(120)
        }
        return last!
    }
}
