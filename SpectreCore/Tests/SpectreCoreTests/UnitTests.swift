import XCTest
@testable import SpectreCore

final class OutboxTests: XCTestCase {
    func testRoundTripRandomRangesAndFingerprint() throws {
        let dir = tempDir("outbox")
        let secrets = InMemorySecretStore()
        let ob = try EncryptedOutbox(directory: dir, secrets: secrets, segmentSize: 4096)
        let data = syntheticBytes(4096 * 5 + 123, seed: 9)
        let src = dir.appendingPathComponent("plain.mov"); try data.write(to: src)
        let id = UUID().uuidString.lowercased()
        let fp = try ob.importPlaintext(from: src, captureId: id)
        XCTAssertEqual(fp.size, UInt64(data.count))
        XCTAssertEqual(fp.sha256, SpectreCrypto.sha256Hex(data))
        XCTAssertEqual(try ob.fingerprint(id), fp)
        for (off, len) in [(0, 10), (4090, 20), (8192, 4096), (data.count - 5, 100), (0, data.count)] {
            XCTAssertEqual(try ob.readPlaintext(id, offset: UInt64(off), length: len),
                           data.subdata(in: off..<min(data.count, off + len)))
        }
        // Ciphertext does not contain plaintext
        let raw = try Data(contentsOf: ob.containerURL(id))
        XCTAssertNil(raw.range(of: data.subdata(in: 100..<164)))
    }

    func testTamperingIsDetected() throws {
        let dir = tempDir("outbox")
        let ob = try EncryptedOutbox(directory: dir, secrets: InMemorySecretStore(), segmentSize: 4096)
        let src = dir.appendingPathComponent("p"); try syntheticBytes(10000).write(to: src)
        let id = UUID().uuidString.lowercased()
        try ob.importPlaintext(from: src, captureId: id)
        var raw = try Data(contentsOf: ob.containerURL(id))
        raw[EncryptedOutbox.headerSize + 50] ^= 0x01
        try raw.write(to: ob.containerURL(id))
        XCTAssertThrowsError(try ob.readPlaintext(id, offset: 0, length: 100)) { XCTAssertEqual($0 as? SpectreError, .outboxCorrupted) }
        // truncation: drop the last segment
        try raw.prefix(EncryptedOutbox.headerSize + 4096 + 16).write(to: ob.containerURL(id))
        XCTAssertThrowsError(try ob.readPlaintext(id, offset: 8192, length: 10))
    }

    func testDestroyIsCryptographicErasure() throws {
        let dir = tempDir("outbox")
        let secrets = InMemorySecretStore()
        let ob = try EncryptedOutbox(directory: dir, secrets: secrets, segmentSize: 4096)
        let src = dir.appendingPathComponent("p"); try syntheticBytes(5000).write(to: src)
        let id = UUID().uuidString.lowercased()
        try ob.importPlaintext(from: src, captureId: id)
        let copy = try Data(contentsOf: ob.containerURL(id))   // simulates a flash remnant
        try ob.destroy(id)
        XCTAssertFalse(ob.exists(id)); XCTAssertFalse(ob.hasKey(id))
        try copy.write(to: ob.containerURL(id))
        XCTAssertThrowsError(try ob.readPlaintext(id, offset: 0, length: 10)) { XCTAssertEqual($0 as? SpectreError, .outboxKeyMissing) }
    }
}

final class ReceiptVerifierTests: XCTestCase {
    let creds = DeviceCredentials(endpoint: URL(string: "https://script.google.com/macros/s/x/exec")!,
                                  deviceId: "d_0123456789abcdef", secretHex: String(repeating: "ab", count: 32), enrolledAt: Date())
    func record(_ data: Data) -> CaptureRecord {
        var r = CaptureRecord(mimeType: "video/quicktime", fileExtension: "mov", stage: .awaitingVerification, localCopies: [])
        var d = StreamingDigest(); d.update(data); r.fingerprint = d.finalize()
        r.uploadId = "u_000000000000000000000001"
        return r
    }
    func receipt(for r: CaptureRecord, mutate: (inout DepositReceipt) -> Void = { _ in }, resign: Bool = true) -> DepositReceipt {
        var x = DepositReceipt(v: 1, status: "VERIFIED", captureId: r.captureId, uploadId: r.uploadId!, deviceId: creds.deviceId,
                               driveFileId: "1AbCdEfGhIjKlMnOp", size: r.fingerprint!.size, sha256: r.fingerprint!.sha256,
                               md5: r.fingerprint!.md5, checksumSource: "sha256", verifiedAt: "2026-11-04T17:00:00.000Z", mac: "")
        mutate(&x)
        if resign { x.mac = SpectreCrypto.hmacSHA256Hex(key: Data(creds.secretHex.utf8), message: x.canonicalString) }
        return x
    }
    func testValidReceipt() {
        let r = record(syntheticBytes(1000))
        guard case .verified = ReceiptVerifier().verify(receipt(for: r), record: r, credentials: creds) else { return XCTFail() }
    }
    func testEveryFieldIsChecked() {
        let r = record(syntheticBytes(1000))
        let cases: [(String, (inout DepositReceipt) -> Void)] = [
            ("status", { $0.status = "PENDING" }), ("capture", { $0.captureId = UUID().uuidString.lowercased() }),
            ("upload", { $0.uploadId = "u_999999999999999999999999" }), ("device", { $0.deviceId = "d_ffffffffffffffff" }),
            ("size", { $0.size += 1 }), ("sha", { $0.sha256 = String(repeating: "0", count: 64) }),
            ("md5", { $0.md5 = String(repeating: "0", count: 32) }), ("drive", { $0.driveFileId = "" }),
            ("version", { $0.v = 2 }),
        ]
        for (name, m) in cases {
            if case .verified = ReceiptVerifier().verify(receipt(for: r, mutate: m), record: r, credentials: creds) { XCTFail(name) }
        }
    }
    func testForgedMacRejected() {
        let r = record(syntheticBytes(1000))
        var x = receipt(for: r); x.mac = String(repeating: "0", count: 64)
        XCTAssertEqual(ReceiptVerifier().verify(x, record: r, credentials: creds), .rejected(kind: .receiptInvalid, reason: "Reçu non authentifié (MAC invalide)"))
    }
    func testDriveIdMustMatchUploadResponseAndMd5PolicyIsConfigurable() {
        var r = record(syntheticBytes(1000)); r.driveFileIdFromUpload = "1ZZZZZZZZZZZZZ"
        guard case .rejected(.integrityMismatch, _) = ReceiptVerifier().verify(receipt(for: r), record: r, credentials: creds) else { return XCTFail() }
        r.driveFileIdFromUpload = nil
        let md5Receipt = receipt(for: r, mutate: { $0.checksumSource = "md5" })
        guard case .rejected = ReceiptVerifier(allowedChecksumSources: ["sha256"]).verify(md5Receipt, record: r, credentials: creds) else { return XCTFail() }
        guard case .verified = ReceiptVerifier().verify(md5Receipt, record: r, credentials: creds) else { return XCTFail() }
    }
}

final class DeletionCoordinatorTests: XCTestCase {
    func testPartialFailureIsReportedAndFileOutsideRootIsNeverClaimedDeleted() throws {
        let root = tempDir("del")
        let vault = FakeVault(dir: root.appendingPathComponent("vault")); vault.add("v1", Data([1])); vault.failDeletes = true
        let tmp = root.appendingPathComponent("tmp"); try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let f = tmp.appendingPathComponent("a.mov"); try Data([1, 2, 3]).write(to: f)
        let outside = root.appendingPathComponent("elsewhere.mov"); try Data([9]).write(to: outside)
        var rec = CaptureRecord(mimeType: "video/quicktime", fileExtension: "mov", stage: .confirmed, localCopies: [
            LocalCopyRef(kind: .vaultEntry, reference: "v1"), LocalCopyRef(kind: .plaintextTemp, reference: f.path),
            LocalCopyRef(kind: .cameraOriginalTemp, reference: outside.path)])
        rec.uploadId = "u_1"
        let proof = VerifiedReceipt(DepositReceipt(v: 1, status: "VERIFIED", captureId: rec.captureId, uploadId: "u_1", deviceId: "d", driveFileId: "x",
                                                   size: 1, sha256: "", md5: "", checksumSource: "sha256", verifiedAt: "", mac: ""))
        let dc = DeletionCoordinator(handlers: [vault, FileCopyHandler(kind: .plaintextTemp, allowedRoot: tmp),
                                                FileCopyHandler(kind: .cameraOriginalTemp, allowedRoot: tmp)])
        let rep = dc.deleteLocalCopies(of: rec, authorizedBy: proof)
        XCTAssertEqual(rep.deleted, [.plaintextTemp])
        XCTAssertEqual(Set(rep.failed.keys), [.vaultEntry, .cameraOriginalTemp])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }
}

final class EnrollmentAndLoggingTests: XCTestCase {
    func testParser() throws {
        let ok = "spectre://enroll?v=1&endpoint=https%3A%2F%2Fscript.google.com%2Fmacros%2Fs%2FAKfy%2Fexec&code=0123abcd-4567ef01-89abcdef-01234567"
        XCTAssertEqual(try EnrollmentParser.parse(ok).endpoint.host, "script.google.com")
        for bad in ["https://evil.example/enroll", "spectre://enroll?v=1&endpoint=http%3A%2F%2Fscript.google.com%2Fx&code=0123abcd-4567ef01-89abcdef",
                    "spectre://enroll?v=1&endpoint=https%3A%2F%2Fevil.example%2Fx&code=0123abcd-4567ef01-89abcdef",
                    "spectre://enroll?v=1&endpoint=https%3A%2F%2Fscript.google.com%2Fx&code=short"] {
            XCTAssertThrowsError(try EnrollmentParser.parse(bad), bad)
        }
    }
    func testLogRedaction() {
        let sink = MemoryLogSink()
        SpectreLog(sink: sink).event("x", ["capture": "0f8fad5b-d9cb-469f-a165-70867728950e", "status": "https://www.googleapis.com/upload?upload_id=SECRET",
                                           "kind": String(repeating: "a", count: 64), "secretField": "leak"])
        let line = sink.all.joined()
        XCTAssertFalse(line.contains("upload_id")); XCTAssertFalse(line.contains("leak")); XCTAssertFalse(line.contains(String(repeating: "a", count: 64)))
        XCTAssertTrue(line.contains("capture=0f8fad5b "))
    }
    func testStatusLabels() {
        var r = CaptureRecord(mimeType: "video/quicktime", fileExtension: "mov", stage: .queued, localCopies: [])
        XCTAssertEqual(r.userFacingStatus, .pending)
        r.stage = .confirmed; XCTAssertEqual(r.userFacingStatus, .confirmedLocalCopyRemains)
        r.stage = .completed; XCTAssertEqual(r.userFacingStatus.labelFR, "Transfert confirmé — supprimée du téléphone")
    }
}

/// In-process transport returning scripted responses (protocol edge cases).
final class ScriptedTransport: SpectreHTTPTransport, @unchecked Sendable {
    var responses: [SpectreHTTPResponse]
    var sent: [SpectreHTTPRequest] = []
    init(_ r: [SpectreHTTPResponse]) { responses = r }
    func send(_ request: SpectreHTTPRequest) async throws -> SpectreHTTPResponse { sent.append(request); return responses.removeFirst() }
}

final class ResumableUploaderTests: XCTestCase {
    let session = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=abc")!
    func testResumesFromServerOffsetNotLocalBelief() async throws {
        let t = ScriptedTransport([
            SpectreHTTPResponse(status: 308, headers: ["Range": "bytes=0-262143"], body: Data()),
            SpectreHTTPResponse(status: 200, headers: [:], body: Data(#"{"id":"1Abc"}"#.utf8)),
        ])
        let data = syntheticBytes(300_000)
        let id = try await ResumableUploader(transport: t, chunkSize: 256 * 1024).upload(session: session, total: UInt64(data.count),
            read: { o, l in data.subdata(in: Int(o)..<Int(o) + l) }, progress: { _ in })
        XCTAssertEqual(id, "1Abc")
        XCTAssertEqual(t.sent[1].headers["Content-Range"], "bytes 262144-299999/300000")
        XCTAssertNil(t.sent.first { $0.headers["Authorization"] != nil }, "phone never sends an OAuth token")
    }
    func testExpiredSessionAndLyingServer() async {
        let u1 = ResumableUploader(transport: ScriptedTransport([SpectreHTTPResponse(status: 404, headers: [:], body: Data())]), chunkSize: 256 * 1024)
        do { _ = try await u1.probe(session: session, total: 10); XCTFail() } catch { XCTAssertEqual(error as? SpectreError, .sessionExpired) }
        let u2 = ResumableUploader(transport: ScriptedTransport([SpectreHTTPResponse(status: 308, headers: ["Range": "bytes=0-99"], body: Data())]), chunkSize: 256 * 1024)
        do { _ = try await u2.probe(session: session, total: 10); XCTFail() } catch { if case .protocolViolation = error as? SpectreError {} else { XCTFail() } }
    }
}
