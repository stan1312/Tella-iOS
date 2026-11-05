//  SPECTRE Capture — SpectreCore
//  Encrypted outbox: holds the ORIGINAL video bytes until the deposit is
//  verified. Format "SPXO1": header + fixed-size segments, each sealed with
//  AES-256-GCM under a random per-capture key kept in the SecretStore
//  (Keychain on iOS). Segment nonce = 4 zero bytes ‖ big-endian segment index;
//  AAD = header ‖ index ‖ last-flag, so truncation/reordering is detected.
//  Deleting the key is a cryptographic erasure of the container: flash
//  remnants of the ciphertext are unreadable without it.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public final class EncryptedOutbox: @unchecked Sendable {
    public static let magic = Data("SPXO1".utf8)
    public static let headerSize = 5 + 4 + 8      // magic + segment size + plaintext size
    public static let tagSize = 16

    public let directory: URL
    private let secrets: SecretStore
    public let segmentSize: Int
    /// Applied to every container created (NSFileProtection, backup exclusion on iOS).
    public var didCreateFile: ((URL) -> Void)?

    public init(directory: URL, secrets: SecretStore, segmentSize: Int = 1 << 20) throws {
        precondition(segmentSize >= 4096)
        self.directory = directory
        self.secrets = secrets
        self.segmentSize = segmentSize
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func containerURL(_ id: CaptureID) -> URL { directory.appendingPathComponent("outbox-\(id).spxo") }

    /// Streams `plaintextURL` into a new encrypted container and returns the
    /// fingerprint (size, SHA-256, MD5) of the ORIGINAL bytes. The plaintext
    /// file is not modified; the caller is responsible for deleting it.
    @discardableResult
    public func importPlaintext(from plaintextURL: URL, captureId: CaptureID) throws -> FileFingerprint {
        guard Validation.isUUID(captureId) else { throw SpectreError.invalidCaptureId }
        let attrs = try FileManager.default.attributesOfItem(atPath: plaintextURL.path)
        let total = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try secrets.set(keyData, for: SecretKeys.outboxKey(captureId))

        let out = containerURL(captureId)
        guard FileManager.default.createFile(atPath: out.path, contents: nil) else { throw SpectreError.outboxCorrupted }
        didCreateFile?(out)
        let w = try FileHandle(forWritingTo: out)
        let r = try FileHandle(forReadingFrom: plaintextURL)
        defer { try? w.close(); try? r.close() }

        let header = Self.header(segmentSize: segmentSize, plaintextSize: total)
        try w.write(contentsOf: header)

        var digest = StreamingDigest()
        let segCount = Self.segmentCount(total: total, segmentSize: segmentSize)
        for index in 0..<segCount {
            let chunk = try r.read(upToCount: segmentSize) ?? Data()
            digest.update(chunk)
            let sealed = try AES.GCM.seal(chunk, using: key,
                                          nonce: Self.nonce(index),
                                          authenticating: Self.aad(header: header, index: index, last: index == segCount - 1))
            try w.write(contentsOf: sealed.ciphertext)
            try w.write(contentsOf: sealed.tag)
        }
        try w.synchronize()
        let fp = digest.finalize()
        guard fp.size == total else { throw SpectreError.outboxCorrupted }
        return fp
    }

    public func plaintextSize(_ id: CaptureID) throws -> UInt64 {
        let h = try FileHandle(forReadingFrom: containerURL(id))
        defer { try? h.close() }
        let header = try h.read(upToCount: Self.headerSize) ?? Data()
        return try Self.parseHeader(header).plaintextSize
    }

    /// Returns decrypted bytes [offset, offset+length) of the original file.
    /// Every segment touched is authenticated (GCM tag) before use.
    public func readPlaintext(_ id: CaptureID, offset: UInt64, length: Int) throws -> Data {
        guard let keyData = try secrets.get(SecretKeys.outboxKey(id)) else { throw SpectreError.outboxKeyMissing }
        let key = SymmetricKey(data: keyData)
        let h = try FileHandle(forReadingFrom: containerURL(id))
        defer { try? h.close() }
        let header = try h.read(upToCount: Self.headerSize) ?? Data()
        let (seg, total) = try Self.parseHeader(header)
        guard offset <= total else { throw SpectreError.outboxRange }
        let end = min(total, offset + UInt64(max(0, length)))
        if end == offset { return Data() }
        let segCount = Self.segmentCount(total: total, segmentSize: seg)
        var result = Data(capacity: Int(end - offset))
        var index = Int(offset / UInt64(seg))
        while UInt64(index) * UInt64(seg) < end {
            let plainStart = UInt64(index) * UInt64(seg)
            let plainLen = Int(min(UInt64(seg), total - plainStart))
            let fileOffset = UInt64(Self.headerSize) + UInt64(index) * UInt64(seg + Self.tagSize)
            try h.seek(toOffset: fileOffset)
            let blob = try h.read(upToCount: plainLen + Self.tagSize) ?? Data()
            guard blob.count == plainLen + Self.tagSize else { throw SpectreError.outboxCorrupted }
            let box = try AES.GCM.SealedBox(nonce: Self.nonce(index),
                                            ciphertext: blob.prefix(plainLen),
                                            tag: blob.suffix(Self.tagSize))
            let plain: Data
            do {
                plain = try AES.GCM.open(box, using: key,
                                         authenticating: Self.aad(header: header, index: index, last: index == segCount - 1))
            } catch { throw SpectreError.outboxCorrupted }
            let lo = Int(max(offset, plainStart) - plainStart)
            let hi = Int(min(end, plainStart + UInt64(plainLen)) - plainStart)
            result.append(plain.subdata(in: lo..<hi))
            index += 1
        }
        return result
    }

    /// Re-hashes the whole container (used before trusting an outbox after a crash).
    public func fingerprint(_ id: CaptureID, chunk: Int = 4 << 20) throws -> FileFingerprint {
        let total = try plaintextSize(id)
        var d = StreamingDigest()
        var off: UInt64 = 0
        while off < total {
            let part = try readPlaintext(id, offset: off, length: chunk)
            d.update(part); off += UInt64(part.count)
        }
        return d.finalize()
    }

    public func exists(_ id: CaptureID) -> Bool {
        FileManager.default.fileExists(atPath: containerURL(id).path)
    }

    public func hasKey(_ id: CaptureID) -> Bool {
        ((try? secrets.get(SecretKeys.outboxKey(id))) ?? nil) != nil
    }

    /// Cryptographic erasure (delete key first) then file removal.
    public func destroy(_ id: CaptureID) throws {
        try secrets.delete(SecretKeys.outboxKey(id))
        let u = containerURL(id)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
    }

    // MARK: format helpers
    static func header(segmentSize: Int, plaintextSize: UInt64) -> Data {
        var d = magic
        withUnsafeBytes(of: UInt32(segmentSize).bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: plaintextSize.bigEndian) { d.append(contentsOf: $0) }
        return d
    }

    static func parseHeader(_ h: Data) throws -> (segmentSize: Int, plaintextSize: UInt64) {
        guard h.count == headerSize, h.prefix(5) == magic else { throw SpectreError.outboxCorrupted }
        let b = [UInt8](h)
        var seg: UInt32 = 0
        for i in 5..<9 { seg = seg << 8 | UInt32(b[i]) }
        var size: UInt64 = 0
        for i in 9..<17 { size = size << 8 | UInt64(b[i]) }
        guard seg >= 4096 else { throw SpectreError.outboxCorrupted }
        return (Int(seg), size)
    }

    static func segmentCount(total: UInt64, segmentSize: Int) -> Int {
        total == 0 ? 1 : Int((total + UInt64(segmentSize) - 1) / UInt64(segmentSize))
    }

    static func nonce(_ index: Int) -> AES.GCM.Nonce {
        var n = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: UInt64(index).bigEndian) { n.append(contentsOf: $0) }
        return try! AES.GCM.Nonce(data: n)
    }

    static func aad(header: Data, index: Int, last: Bool) -> Data {
        var d = header
        withUnsafeBytes(of: UInt64(index).bigEndian) { d.append(contentsOf: $0) }
        d.append(last ? 1 : 0)
        return d
    }
}
