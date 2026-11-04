//  SPECTRE Capture — SpectreCore
//  Client of the deposit-only backend (Google Apps Script web app).
//  The API intentionally offers NO list / read / download / delete operation.

import Foundation

public struct DeviceCredentials: Codable, Equatable, Sendable {
    public var endpoint: URL
    public var deviceId: String
    public var secretHex: String
    public var enrolledAt: Date
    public init(endpoint: URL, deviceId: String, secretHex: String, enrolledAt: Date) {
        self.endpoint = endpoint; self.deviceId = deviceId; self.secretHex = secretHex; self.enrolledAt = enrolledAt
    }
    var keyData: Data { Data(secretHex.utf8) }
}

public enum InitUploadResult: Equatable, Sendable {
    case session(uploadId: String, sessionURL: URL)
    case alreadyVerified(DepositReceipt)
    /// The previous session already produced a Drive file: go verify it.
    case finalizeExisting(uploadId: String)
}

public enum FinalizeResult: Equatable, Sendable {
    case verified(DepositReceipt)
    case pending(retryAfter: TimeInterval)
    case incomplete
    case mismatch(detail: String)
}

public struct InitUploadRequest: Codable, Sendable {
    public var captureId: String
    public var size: UInt64
    public var sha256: String
    public var md5: String
    public var mimeType: String
    public var ext: String
    public var renewSession: Bool
    public var forceNewUpload: Bool
}

public protocol DepositBackend: Sendable {
    func enroll(endpoint: URL, inviteCode: String) async throws -> DeviceCredentials
    func initUpload(_ req: InitUploadRequest, credentials: DeviceCredentials) async throws -> InitUploadResult
    func finalize(uploadId: String, captureId: String, driveFileId: String?, credentials: DeviceCredentials) async throws -> FinalizeResult
}

public final class HTTPDepositBackend: DepositBackend, @unchecked Sendable {
    private let transport: SpectreHTTPTransport
    private let clock: @Sendable () -> Date

    public init(transport: SpectreHTTPTransport, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport; self.clock = clock
    }

    // MARK: request signing (MUST match backend `requestCanonical_`)
    public static func requestCanonical(action: String, deviceId: String, ts: Int, nonce: String, payload: String) -> String {
        ["spectre-req-v1", action, deviceId, String(ts), nonce, SpectreCrypto.sha256Hex(Data(payload.utf8))]
            .joined(separator: "\n")
    }

    private struct Envelope: Encodable {
        let action: String
        let deviceId: String?
        let ts: Int?
        let nonce: String?
        let payload: String
        let sig: String?
    }

    private func call(endpoint: URL, action: String, payload: [String: Any], credentials: DeviceCredentials?) async throws -> [String: Any] {
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let payloadString = String(decoding: payloadData, as: UTF8.self)
        var env = Envelope(action: action, deviceId: nil, ts: nil, nonce: nil, payload: payloadString, sig: nil)
        if let c = credentials {
            let ts = Int(clock().timeIntervalSince1970)
            let nonce = Hex.encode(SpectreCrypto.randomBytes(16))
            let sig = SpectreCrypto.hmacSHA256Hex(key: c.keyData,
                                                 message: Self.requestCanonical(action: action, deviceId: c.deviceId, ts: ts, nonce: nonce, payload: payloadString))
            env = Envelope(action: action, deviceId: c.deviceId, ts: ts, nonce: nonce, payload: payloadString, sig: sig)
        }
        let body = try JSONEncoder().encode(env)
        // text/plain avoids a CORS preflight and is what Apps Script expects in e.postData.
        let resp = try await transport.send(SpectreHTTPRequest(method: "POST", url: endpoint,
                                                        headers: ["Content-Type": "text/plain;charset=utf-8"],
                                                        body: body))
        guard (200..<300).contains(resp.status) else {
            if resp.status == 429 { throw SpectreError.backend(code: "RATE_LIMITED", message: "HTTP 429") }
            throw SpectreError.http(status: resp.status)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw SpectreError.protocolViolation("backend returned non-JSON")
        }
        if (obj["ok"] as? Bool) == true, let data = obj["data"] as? [String: Any] { return data }
        let err = obj["error"] as? [String: Any]
        throw SpectreError.backend(code: err?["code"] as? String ?? "INTERNAL",
                                   message: err?["message"] as? String ?? "")
    }

    public func enroll(endpoint: URL, inviteCode: String) async throws -> DeviceCredentials {
        let d = try await call(endpoint: endpoint, action: "enroll",
                               payload: ["inviteCode": inviteCode, "platform": "ios", "client": "spectre-capture/0.1"],
                               credentials: nil)
        guard let id = d["deviceId"] as? String, let secret = d["deviceSecret"] as? String,
              secret.count >= 64 else { throw SpectreError.protocolViolation("bad enroll response") }
        return DeviceCredentials(endpoint: endpoint, deviceId: id, secretHex: secret, enrolledAt: clock())
    }

    public func initUpload(_ req: InitUploadRequest, credentials: DeviceCredentials) async throws -> InitUploadResult {
        let d = try await call(endpoint: credentials.endpoint, action: "initUpload", payload: [
            "captureId": req.captureId, "size": req.size, "sha256": req.sha256, "md5": req.md5,
            "mimeType": req.mimeType, "ext": req.ext, "renewSession": req.renewSession, "forceNewUpload": req.forceNewUpload,
        ], credentials: credentials)
        switch d["state"] as? String {
        case "SESSION":
            guard let uid = d["uploadId"] as? String, let s = d["sessionUrl"] as? String, let u = URL(string: s) else {
                throw SpectreError.protocolViolation("bad session response")
            }
            return .session(uploadId: uid, sessionURL: u)
        case "VERIFIED":
            return .alreadyVerified(try Self.decodeReceipt(d["receipt"]))
        case "FINALIZE":
            guard let uid = d["uploadId"] as? String else { throw SpectreError.protocolViolation("bad finalize hint") }
            return .finalizeExisting(uploadId: uid)
        default:
            throw SpectreError.protocolViolation("unknown init state")
        }
    }

    public func finalize(uploadId: String, captureId: String, driveFileId: String?, credentials: DeviceCredentials) async throws -> FinalizeResult {
        var p: [String: Any] = ["uploadId": uploadId, "captureId": captureId]
        if let f = driveFileId { p["driveFileId"] = f }
        let d = try await call(endpoint: credentials.endpoint, action: "finalizeUpload", payload: p, credentials: credentials)
        switch d["state"] as? String {
        case "VERIFIED": return .verified(try Self.decodeReceipt(d["receipt"]))
        case "PENDING": return .pending(retryAfter: (d["retryAfterSec"] as? Double) ?? Double(d["retryAfterSec"] as? Int ?? 30))
        case "INCOMPLETE": return .incomplete
        case "MISMATCH": return .mismatch(detail: d["detail"] as? String ?? "")
        default: throw SpectreError.protocolViolation("unknown finalize state")
        }
    }

    static func decodeReceipt(_ any: Any?) throws -> DepositReceipt {
        guard let any = any, JSONSerialization.isValidJSONObject(any) else { throw SpectreError.protocolViolation("missing receipt") }
        let data = try JSONSerialization.data(withJSONObject: any)
        do { return try JSONDecoder().decode(DepositReceipt.self, from: data) }
        catch { throw SpectreError.protocolViolation("malformed receipt") }
    }
}
