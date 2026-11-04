//  SPECTRE Capture — SpectreCore
//  Google Drive resumable-upload protocol (client side, bytes only).
//  https://developers.google.com/workspace/drive/api/guides/manage-uploads#resumable
//  The session URI is created by the backend; the phone never holds an OAuth token.

import Foundation

public enum UploadProbe: Equatable, Sendable {
    case incomplete(nextOffset: UInt64)
    case complete(driveFileId: String?)
}

public struct ResumableUploader: Sendable {
    public static let granularity = 256 * 1024
    public let transport: HTTPTransport
    public let chunkSize: Int

    public init(transport: HTTPTransport, chunkSize: Int = 8 * 1024 * 1024) {
        precondition(chunkSize % Self.granularity == 0, "Drive requires chunks that are multiples of 256 KiB")
        self.transport = transport
        self.chunkSize = chunkSize
    }

    /// Asks Drive how many bytes it has durably received.
    public func probe(session: URL, total: UInt64) async throws -> UploadProbe {
        let r = try await transport.send(HTTPRequest(method: "PUT", url: session,
                                                     headers: ["Content-Range": "bytes */\(total)"], body: nil))
        return try interpret(r, total: total)
    }

    func interpret(_ r: HTTPResponse, total: UInt64) throws -> UploadProbe {
        switch r.status {
        case 200, 201:
            let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]
            return .complete(driveFileId: obj?["id"] as? String)
        case 308:
            guard let range = r.headers["range"] else { return .incomplete(nextOffset: 0) }
            // "bytes=0-12345"
            guard let dash = range.lastIndex(of: "-"), let last = UInt64(range[range.index(after: dash)...]) else {
                throw SpectreError.protocolViolation("bad Range header")
            }
            let next = last + 1
            guard next <= total else { throw SpectreError.protocolViolation("server claims more bytes than declared") }
            return .incomplete(nextOffset: next)
        case 404, 410:
            throw SpectreError.sessionExpired
        default:
            throw SpectreError.http(status: r.status)
        }
    }

    /// Uploads remaining bytes. Always starts by probing the server so that a
    /// locally recorded offset is never trusted blindly. Returns the Drive file id
    /// reported by the final response (informational — deletion still requires a
    /// verified receipt from the backend).
    public func upload(session: URL, total: UInt64,
                       read: @Sendable (UInt64, Int) throws -> Data,
                       progress: @Sendable (UInt64) -> Void) async throws -> String? {
        guard total > 0 else { throw SpectreError.protocolViolation("empty file") }
        var state = try await probe(session: session, total: total)
        while true {
            switch state {
            case .complete(let id):
                progress(total)
                return id
            case .incomplete(let offset):
                progress(offset)
                if offset == total {
                    // All bytes acknowledged but no final response: probe again.
                    state = try await probe(session: session, total: total)
                    if case .incomplete(let o) = state, o == total {
                        throw SpectreError.protocolViolation("server holds all bytes but did not complete")
                    }
                    continue
                }
                let len = Int(min(UInt64(chunkSize), total - offset))
                let chunk = try read(offset, len)
                guard chunk.count == len else { throw SpectreError.outboxRange }
                let r = try await transport.send(HTTPRequest(
                    method: "PUT", url: session,
                    headers: ["Content-Range": "bytes \(offset)-\(offset + UInt64(len) - 1)/\(total)",
                              "Content-Type": "application/octet-stream"],
                    body: chunk))
                state = try interpret(r, total: total)
            }
        }
    }
}
