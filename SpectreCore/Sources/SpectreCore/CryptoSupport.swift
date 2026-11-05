//  SPECTRE Capture — SpectreCore
//  Crypto primitives shared by the deposit pipeline.
//  Apple platforms use CryptoKit; Linux (CI / tests) uses swift-crypto,
//  which exposes the same API.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum Hex {
    public static func encode<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        var s = ""
        for b in bytes { s += String(format: "%02x", b) }
        return s
    }

    public static func decode(_ hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        func val(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        while i < chars.count {
            guard let hi = val(chars[i]), let lo = val(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }
}

/// Incremental SHA-256 + MD5 over a byte stream. MD5 is only kept because
/// Google Drive always exposes `md5Checksum` whereas `sha256Checksum` may be
/// absent; it is never used alone (size must also match).
public struct StreamingDigest {
    private var sha = SHA256()
    private var md5 = Insecure.MD5()
    public private(set) var byteCount: UInt64 = 0

    public init() {}

    public mutating func update(_ data: Data) {
        sha.update(data: data)
        md5.update(data: data)
        byteCount += UInt64(data.count)
    }

    public func finalize() -> FileFingerprint {
        FileFingerprint(size: byteCount,
                        sha256: Hex.encode(sha.finalize()),
                        md5: Hex.encode(md5.finalize()))
    }

    /// Hashes a file by streaming it (constant memory, multi-GB safe).
    public static func fingerprint(of url: URL, chunkSize: Int = 4 * 1024 * 1024) throws -> FileFingerprint {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var d = StreamingDigest()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            d.update(chunk)
        }
        return d.finalize()
    }
}

public struct FileFingerprint: Codable, Equatable, Sendable {
    public let size: UInt64
    public let sha256: String
    public let md5: String
    public init(size: UInt64, sha256: String, md5: String) {
        self.size = size; self.sha256 = sha256.lowercased(); self.md5 = md5.lowercased()
    }
}

public enum SpectreCrypto {
    public static func hmacSHA256Hex(key: Data, message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return Hex.encode(mac)
    }

    public static func sha256Hex(_ data: Data) -> String {
        Hex.encode(SHA256.hash(data: data))
    }

    /// Constant-time comparison for MACs / secrets.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    public static func randomBytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }
}
