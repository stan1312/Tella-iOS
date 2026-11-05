// End-to-end scenarios T01–T15 (mandate §7) on synthetic data:
// Swift client (SpectreCore) ⇄ real Apps Script code (Node vm) ⇄ MockDrive.
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SpectreCore

final class ScenarioTests: XCTestCase {
    var stack: MockStack!

    override func setUp() async throws { stack = try MockStack() }
    override func tearDown() async throws { stack?.stop() }

    private func allLocalCopiesGone(_ p: Phone, _ id: String) throws -> Bool {
        let r = try XCTUnwrap(try p.store.load(id))
        let fileGone = r.localCopies.filter { $0.kind == .cameraOriginalTemp }.allSatisfy { !FileManager.default.fileExists(atPath: $0.reference) }
        return !p.outbox.exists(id) && !p.outbox.hasKey(id) && !p.vault.exists(LocalCopyRef(kind: .vaultEntry, reference: "vault-\(id)")) && fileGone
    }

    // T01 + T13
    func testT01_shortVideoStableNetwork_verifiedThenAllCopiesDeleted() async throws {
        let p = try Phone.make()
        _ = try await p.enroll(stack)
        let bytes = syntheticBytes(1_900_000, seed: 1)
        let id = try await p.capture(bytes)
        let r = await p.run(id)
        XCTAssertEqual(r.stage, .completed, "\(String(describing: r.failure))")
        XCTAssertEqual(r.receipt?.sha256, SpectreCrypto.sha256Hex(bytes))
        XCTAssertEqual(r.receipt?.checksumSource, "sha256")
        XCTAssertTrue(r.remainingCopies.isEmpty)
        XCTAssertTrue(try allLocalCopiesGone(p, id))
        let files = try await stack.ownerFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?["sha256"] as? String, SpectreCrypto.sha256Hex(bytes), "original bytes unmodified on Drive")
        XCTAssertEqual(r.userFacingStatus, .confirmed)
    }

    // T03: airplane mode before stopping the recording
    func testT03_offlineCaptureKeepsOriginalAndVisibleTask() async throws {
        let offlineEndpoint = URL(string: "http://127.0.0.1:9/macros/s/MOCK/exec")!   // nothing listens on port 9
        let p = try Phone.make()
        try CredentialVault(secrets: p.secrets).save(DeviceCredentials(endpoint: offlineEndpoint, deviceId: "d_0123456789abcdef",
                                                                       secretHex: String(repeating: "a", count: 64), enrolledAt: Date()))
        let id = try await p.capture(syntheticBytes(700_000))
        let r = await p.run(id, maxPasses: 3)
        XCTAssertEqual(r.stage, .queued)
        XCTAssertEqual(r.failure?.kind, .network)
        XCTAssertNotNil(r.failure?.nextAttemptAt, "automatic retry is scheduled")
        XCTAssertTrue(p.outbox.exists(id)); XCTAssertTrue(p.vault.exists(LocalCopyRef(kind: .vaultEntry, reference: "vault-\(id)")))
        guard case .error(retryable: true, _) = r.userFacingStatus else { return XCTFail("\(r.userFacingStatus)") }
        // back online (re-enrol against the reachable backend) → completes
        _ = try await p.enroll(stack)
        try await p.engine.retryNow(id)
        let done = await p.run(id)
        XCTAssertEqual(done.stage, .completed)
    }

    // T04: cuts at 10 %, 50 % and 99 %
    func testT04_cutsAt10_50_99PercentResumeWithoutLossOrPrematureDeletion() async throws {
        try await stack.control(["driveFaults": ["dropAtFractions": [0.10, 0.50, 0.99]]])
        let p = try Phone.make()
        _ = try await p.enroll(stack)
        let bytes = syntheticBytes(5 * 1024 * 1024 + 333, seed: 4)
        let id = try await p.capture(bytes)
        var failuresSeen = 0
        var r: CaptureRecord!
        for _ in 0..<40 {
            r = await p.engine.process(id)!
            if r.failure != nil {
                XCTAssertTrue(p.outbox.exists(id) && p.vault.exists(LocalCopyRef(kind: .vaultEntry, reference: "vault-\(id)")),
                              "nothing deleted while the upload is incomplete")
                XCTAssertNil(r.receipt)
                XCTAssertNotEqual(r.stage, .confirmed)
                failuresSeen += 1
                usleep(500_000)
            }
            if r.stage == .completed { break }
            p.clock.advance(60)
        }
        XCTAssertEqual(r.stage, .completed)
        let drops = try await stack.dropsDone()
        XCTAssertEqual(drops, 3, "three network cuts performed by the mock (10/50/99 %)")
        XCTAssertGreaterThanOrEqual(failuresSeen, 3)
        let files = try await stack.ownerFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?["sha256"] as? String, SpectreCrypto.sha256Hex(bytes))
    }

    // T05: app killed during upload, phone rebooted → state recovered from disk
    func testT05_crashMidUploadRecoversFromDisk() async throws {
        let root = tempDir("phone-crash")
        let bytes = syntheticBytes(3 * 1024 * 1024, seed: 5)
        var id = ""
        do {
            let p1 = try Phone.make(root: root)
            _ = try await p1.enroll(stack)
            id = try await p1.capture(bytes)
            try await stack.control(["driveFaults": ["dropAtFractions": [0.5], "offlineMsAfterDrop": 3000]])
            let r = await p1.engine.process(id)!      // network dies at 50 %
            XCTAssertEqual(r.stage, .uploading)
            XCTAssertGreaterThan(r.bytesConfirmedByServer, 0)
        } // engine, transport, memory: gone ("kill -9")
        usleep(3_100_000)
        let p2 = try Phone.make(root: root)           // relaunch with the same on-disk state + keychain
        let before = try XCTUnwrap(try p2.store.load(id))
        XCTAssertEqual(before.stage, .uploading)
        XCTAssertTrue(p2.outbox.exists(id))
        let r = await p2.run(id)
        XCTAssertEqual(r.stage, .completed)
        let ownerCount = try await stack.ownerFiles().count; XCTAssertEqual(ownerCount, 1)
    }

    // T06: HTTP success on upload but file missing on Drive
    func testT06_httpSuccessButDriveFileAbsent_deletionBlocked() async throws {
        let p = try Phone.make()
        _ = try await p.enroll(stack)
        // Drive accepts every byte and answers 200 to the final chunk, but the file is
        // not visible to the server-side verification.
        try await stack.control(["driveFaults": ["getFault": "missing"]])
        let id = try await p.capture(syntheticBytes(400_000))
        var r: CaptureRecord!
        for _ in 0..<5 { r = await p.engine.process(id)!; p.clock.advance(60) }
        XCTAssertNotNil(r.driveFileIdFromUpload, "Drive answered 200 to the final chunk")
        XCTAssertTrue([.awaitingVerification, .uploading].contains(r.stage), "\(r.stage)")
        XCTAssertNil(r.receipt)
        XCTAssertTrue(p.outbox.exists(id)); XCTAssertTrue(p.vault.exists(LocalCopyRef(kind: .vaultEntry, reference: "vault-\(id)")))
        guard case .verifying = r.userFacingStatus else {
            if case .transferring = r.userFacingStatus { return }
            return XCTFail("\(r.userFacingStatus)")
        }
    }

    // T07: remote size / checksum differs
    func testT07_remoteSizeOrChecksumDiffers_blockedWithVisibleAlert() async throws {
        for fault in ["sizeWrong", "sha256Wrong", "md5Wrong"] {
            try await stack.control(["reset": true])
            let p = try Phone.make()
            _ = try await p.enroll(stack)
            try await stack.control(["driveFaults": ["getFault": fault]])
            let id = try await p.capture(syntheticBytes(300_000, seed: 7))
            let r = await p.run(id)
            XCTAssertEqual(r.stage, .blocked, fault)
            XCTAssertEqual(r.failure?.kind, .integrityMismatch, fault)
            guard case .blocked = r.userFacingStatus else { return XCTFail(fault) }
            XCTAssertTrue(p.outbox.exists(id), fault); XCTAssertTrue(p.vault.exists(LocalCopyRef(kind: .vaultEntry, reference: "vault-\(id)")), fault)
            // after the problem is fixed, "Renvoyer" uploads a NEW copy and then completes
            try await stack.control(["driveFaults": [String: Any]()])
            try await p.engine.retryNow(id)
            let again = await p.run(id)
            XCTAssertEqual(again.stage, .completed, fault)
        }
    }

    // T07b: forged / altered receipt (MITM) never authorises deletion
    func testT07b_tamperedReceiptBlocksDeletion() async throws {
        final class TamperingBackend: DepositBackend, @unchecked Sendable {
            let inner: DepositBackend
            init(_ i: DepositBackend) { inner = i }
            func enroll(endpoint: URL, inviteCode: String) async throws -> DeviceCredentials { try await inner.enroll(endpoint: endpoint, inviteCode: inviteCode) }
            func initUpload(_ req: InitUploadRequest, credentials: DeviceCredentials) async throws -> InitUploadResult { try await inner.initUpload(req, credentials: credentials) }
            func finalize(uploadId: String, captureId: String, driveFileId: String?, credentials: DeviceCredentials) async throws -> FinalizeResult {
                let r = try await inner.finalize(uploadId: uploadId, captureId: captureId, driveFileId: driveFileId, credentials: credentials)
                if case .verified(var rec) = r { rec.size += 0; rec.verifiedAt = "2030-01-01T00:00:00.000Z"; return .verified(rec) }
                return r
            }
        }
        let p = try Phone.make(backend: TamperingBackend(HTTPDepositBackend(transport: URLSessionTransport())))
        _ = try await p.enroll(stack)
        let id = try await p.capture(syntheticBytes(300_000))
        let r = await p.run(id)
        XCTAssertEqual(r.stage, .blocked)
        XCTAssertEqual(r.failure?.kind, .receiptInvalid)
        XCTAssertTrue(p.outbox.exists(id))
    }

    // T08: double tap / concurrent retries
    func testT08_concurrentProcessingIsIdempotent() async throws {
        let p = try Phone.make()
        _ = try await p.enroll(stack)
        let id = try await p.capture(syntheticBytes(2 * 1024 * 1024, seed: 8))
        _ = try await p.engine.register(captureId: id, mimeType: "video/quicktime", fileExtension: "mov", localCopies: [])  // re-register: no-op
        async let a = p.engine.process(id)
        async let b = p.engine.process(id)
        async let c = p.engine.process(id)
        _ = await [a, b, c]
        try await p.engine.retryNow(id)
        let r = await p.run(id)
        XCTAssertEqual(r.stage, .completed)
        let ownerCount = try await stack.ownerFiles().count; XCTAssertEqual(ownerCount, 1, "no uncontrolled duplicate on Drive")
        XCTAssertEqual(try p.store.all().count, 1)
    }

    // T09: revoked device
    func testT09_revokedDeviceCannotUploadAndKeepsOriginal() async throws {
        let p = try Phone.make()
        let creds = try await p.enroll(stack)
        try await stack.revoke(creds.deviceId)
        let id = try await p.capture(syntheticBytes(300_000))
        let r = await p.run(id)
        XCTAssertEqual(r.failure?.kind, .deviceNotAuthorized)
        XCTAssertNil(r.failure?.nextAttemptAt, "no hammering after revocation")
        XCTAssertEqual(r.failure?.message, "Cet appareil a été révoqué par le responsable.")
        XCTAssertTrue(p.outbox.exists(id))
        let ownerCount = try await stack.ownerFiles().count; XCTAssertEqual(ownerCount, 0)
    }

    // T10: compromised phone — everything it holds, inspected and replayed by an attacker
    func testT10_compromisedPhoneCannotListReadDownloadOrDelete() async throws {
        let victim = try Phone.make()
        _ = try await victim.enroll(stack)
        let vid = try await victim.capture(syntheticBytes(300_000, seed: 10))
        let done = await victim.run(vid)
        let victimFile = try XCTUnwrap(done.receipt?.driveFileId)

        let p = try Phone.make()
        let creds = try await p.enroll(stack)
        try await stack.control(["driveFaults": ["dropAtFractions": [0.5], "offlineMsAfterDrop": 300]])
        let id = try await p.capture(syntheticBytes(1_000_000, seed: 11))
        let mid = await p.engine.process(id)!
        XCTAssertEqual(mid.stage, .uploading)
        usleep(400_000)
        let sessionData = try XCTUnwrap(try p.secrets.get(SecretKeys.session(id)))
        let session = URL(string: String(decoding: sessionData, as: UTF8.self))!
        let base = stack.base.absoluteString
        let t = URLSessionTransport()
        let probes: [(String, URL, [String: String])] = [
            ("GET", URL(string: base + "/drive/v3/files")!, [:]),
            ("GET", URL(string: base + "/drive/v3/files")!, ["Authorization": "Bearer \(creds.secretHex)"]),
            ("GET", URL(string: base + "/drive/v3/files/\(victimFile)?alt=media")!, [:]),
            ("DELETE", URL(string: base + "/drive/v3/files/\(victimFile)")!, [:]),
            ("PATCH", URL(string: base + "/drive/v3/files/\(victimFile)")!, [:]),
            ("GET", session, [:]),
        ]
        for (m, u, h) in probes {
            let s = try await t.send(SpectreHTTPRequest(method: m, url: u, headers: h)).status
            XCTAssertTrue(s == 401 || s == 404, "\(m) → \(s)")
        }
        // and the deposit API itself refuses anything but deposit
        let backend = HTTPDepositBackend(transport: t)
        do {
            _ = try await backend.finalize(uploadId: done.uploadId!, captureId: vid, driveFileId: victimFile, credentials: creds)
            XCTFail("cross-device finalize must fail")
        } catch SpectreError.backend(let code, _) { XCTAssertEqual(code, "NOT_FOUND") }
        // nothing in the phone's secret store looks like a Google OAuth token / key
        for k in [SecretKeys.deviceCredentials, SecretKeys.session(id), SecretKeys.outboxKey(id)] {
            let v = String(decoding: (try p.secrets.get(k)) ?? Data(), as: UTF8.self)
            XCTAssertFalse(v.contains("ya29.") || v.contains("BEGIN PRIVATE KEY") || v.contains("refresh_token"), k)
        }
    }

    // T11: Google unavailable, Drive full, owner token expired, Apps Script 503 → no loss, bounded retry, actionable errors
    func testT11_googleFailuresAreBoundedAndActionable() async throws {
        let cases: [([String: Any], FailureKind)] = [
            (["driveFaults": ["storageQuotaExceeded": true]], .driveQuotaExceeded),
            (["driveFaults": ["driveDown": true]], .serverUnavailable),
            (["driveFaults": ["ownerTokenExpired": true]], .serverUnavailable),
            (["backendFaults": ["unavailable": 1000]], .serverUnavailable),
        ]
        for (fault, kind) in cases {
            try await stack.control(["reset": true])
            let p = try Phone.make()
            _ = try await p.enroll(stack)
            try await stack.control(fault)
            let id = try await p.capture(syntheticBytes(200_000))
            let r = await p.run(id, maxPasses: 20)
            XCTAssertEqual(r.failure?.kind, kind, "\(fault)")
            XCTAssertEqual(r.failure?.attempts, 6, "bounded by RetryPolicy.maxAutomaticAttempts")
            XCTAssertNil(r.failure?.nextAttemptAt, "stops after the bound")
            XCTAssertTrue(p.outbox.exists(id), "\(fault)")
            XCTAssertFalse(r.failure!.message.isEmpty)
        }
    }

    // T12: synthetic MOVs with technical metadata (+ fictional GPS), incl. 4K60, arrive byte-identical
    func testT12_originalAndMetadataPreservedByteForByte() async throws {
        let dir = Repo.root.appendingPathComponent("tests/fixtures/generated")
        let names = ["short_1080p30_meta.mov", "short_2160p60.mov"]
        guard names.allSatisfy({ FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }) else {
            throw XCTSkip("run scripts/make_fixtures.sh first (needs ffmpeg)")
        }
        for name in names {
            let src = dir.appendingPathComponent(name)
            let bytes = try Data(contentsOf: src)
            let p = try Phone.make()
            _ = try await p.enroll(stack)
            let id = try await p.capture(bytes)
            let r = await p.run(id)
            XCTAssertEqual(r.stage, .completed, name)
            let fileId = try XCTUnwrap(r.receipt?.driveFileId)
            let downloaded = try await stack.ownerDownload(fileId)
            XCTAssertEqual(downloaded, bytes, "\(name): Drive copy is the unmodified original")
            if let probe = Self.ffprobe(src), let probe2 = Self.ffprobe(Self.write(downloaded)) {
                XCTAssertEqual(probe, probe2, name)
                if name.contains("meta") {
                    // ffmpeg 6 prints "…12:00:00Z", ffmpeg 9 "…12:00:00.000000Z": compare up to the second.
                    XCTAssertTrue(probe.contains("creation_time=2026-11-04T12:00:00"), probe)
                    XCTAssertTrue(probe.contains("location=+00.0000+000.0000/"), probe)
                }
            }
        }
    }

    static func write(_ d: Data) -> URL { let u = tempDir("dl").appendingPathComponent("x.mov"); try! d.write(to: u); return u }
    static func ffprobe(_ u: URL) -> String? {
        let candidates = ["/usr/bin/ffprobe", "/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        guard let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-v", "error", "-show_entries", "format=duration,size:format_tags:stream=codec_name,width,height,r_frame_rate", "-of", "compact", u.path]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    // T14: two phones at the same time
    func testT14_twoDevicesSimultaneously() async throws {
        let a = try Phone.make(), b = try Phone.make()
        _ = try await a.enroll(stack); _ = try await b.enroll(stack)
        let ida = try await a.capture(syntheticBytes(1_500_000, seed: 21))
        let idb = try await b.capture(syntheticBytes(1_500_000, seed: 22))
        async let ra = a.run(ida)
        async let rb = b.run(idb)
        let (x, y) = await (ra, rb)
        XCTAssertEqual(x.stage, .completed); XCTAssertEqual(y.stage, .completed)
        XCTAssertNotEqual(x.receipt?.driveFileId, y.receipt?.driveFileId)
        XCTAssertNotEqual(x.receipt?.deviceId, y.receipt?.deviceId)
        let ownerCount = try await stack.ownerFiles().count; XCTAssertEqual(ownerCount, 2)
    }

    // Logs: no session URL, no secret, no owner token in client or backend journals
    func testLogsContainNoSensitiveData() async throws {
        let p = try Phone.make()
        let creds = try await p.enroll(stack)
        let id = try await p.capture(syntheticBytes(300_000))
        _ = await p.run(id)
        let client = p.logs.all.joined(separator: "\n")
        let backend = try await stack.backendLogs().joined(separator: "\n")
        for blob in [client, backend] {
            XCTAssertFalse(blob.contains("upload_id")); XCTAssertFalse(blob.contains("://"))
            XCTAssertFalse(blob.contains(creds.secretHex)); XCTAssertFalse(blob.contains("ya29."))
        }
        XCTAssertFalse(client.isEmpty)
    }

    // T02: long video (multi-GB when SPECTRE_LARGE_TEST_BYTES is set)
    func testT02_largeVideoOriginalUnmodified() async throws {
        let env = ProcessInfo.processInfo.environment
        let size = Int(env["SPECTRE_LARGE_TEST_BYTES"] ?? "") ?? 64 * 1024 * 1024
        let root = tempDir("phone-large")
        defer { try? FileManager.default.removeItem(at: root) }
        let tmp = root.appendingPathComponent("tmp"); try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let src = tmp.appendingPathComponent("large.mov")
        // stream-write synthetic content (constant memory)
        XCTAssertTrue(FileManager.default.createFile(atPath: src.path, contents: nil))
        let h = try FileHandle(forWritingTo: src)
        var written = 0, seed: UInt32 = 77
        while written < size {
            let n = min(8 * 1024 * 1024, size - written)
            try h.write(contentsOf: syntheticBytes(n, seed: seed)); seed &+= 1; written += n
        }
        try h.close()
        let expected = try StreamingDigest.fingerprint(of: src)
        try await stack.control(["driveFaults": ["dropAtFractions": [0.5]]])
        let p = try Phone.make(root: root, chunk: 8 * 1024 * 1024)
        _ = try await p.enroll(stack)
        let id = UUID().uuidString.lowercased()
        p.vault.add("vault-\(id)", Data([1]))
        try await p.engine.register(captureId: id, mimeType: "video/quicktime", fileExtension: "mov",
                                    localCopies: [LocalCopyRef(kind: .vaultEntry, reference: "vault-\(id)"),
                                                  LocalCopyRef(kind: .cameraOriginalTemp, reference: src.path)])
        let prepared = try await p.engine.prepare(captureId: id, plaintextURL: src, expectedSHA256: expected.sha256)
        XCTAssertEqual(prepared.fingerprint, expected)
        let r = await p.run(id, maxPasses: 60)
        XCTAssertEqual(r.stage, .completed, "\(String(describing: r.failure))")
        let ownerFiles = try await stack.ownerFiles(); let f = try XCTUnwrap(ownerFiles.first)
        XCTAssertEqual(f["sha256"] as? String, expected.sha256)
        print("T02 bytes=\(size) sha256=\(expected.sha256)")
    }
}
