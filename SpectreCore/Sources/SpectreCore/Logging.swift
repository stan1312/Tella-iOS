//  SPECTRE Capture — SpectreCore
//  Minimal technical journal. Only whitelisted, non-sensitive fields; URLs,
//  secrets, file names and locations are never logged.

import Foundation

public protocol SpectreLogSink: Sendable {
    func record(_ line: String)
}

public final class MemoryLogSink: SpectreLogSink, @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()
    public init() {}
    public func record(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    public var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

public struct SpectreLog: Sendable {
    public static let allowedFields: Set<String> = ["capture", "stage", "kind", "attempt", "status", "bytes", "copies", "result"]
    let sink: SpectreLogSink?
    public init(sink: SpectreLogSink?) { self.sink = sink }

    public func event(_ name: String, _ fields: [String: String] = [:]) {
        guard let sink = sink else { return }
        let safe = fields.filter { Self.allowedFields.contains($0.key) }
            .map { "\($0.key)=\(Self.redact($0.value))" }.sorted().joined(separator: " ")
        sink.record("spectre \(name) \(safe)")
    }

    /// Defence in depth: strip anything that looks like a URL or long hex secret.
    public static func redact(_ v: String) -> String {
        if v.contains("://") || v.contains("upload_id") { return "[redacted-url]" }
        if v.count >= 40 && v.allSatisfy({ $0.isHexDigit }) { return "[redacted-hex]" }
        // capture ids: keep a short prefix only
        if Validation.isUUID(v) { return String(v.prefix(8)) }
        return String(v.prefix(64))
    }
}
