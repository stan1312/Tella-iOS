//  SPECTRE Capture — SpectreCore
//  Individual enrolment via QR code / invitation link:
//  spectre://enroll?v=1&endpoint=<https URL>&code=<one-time invite code>
//  The invite is single-use and short-lived; the resulting device secret is
//  stored only in the SecretStore (Keychain, this device only).

import Foundation

public struct EnrollmentInvite: Equatable, Sendable {
    public let endpoint: URL
    public let code: String
}

public enum EnrollmentParser {
    public static func parse(_ text: String, allowInsecureLocalhost: Bool = false) throws -> EnrollmentInvite {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed), comps.scheme == "spectre", comps.host == "enroll" else {
            throw SpectreError.invalidEnrollmentPayload("format")
        }
        let items = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard items["v"] == "1" else { throw SpectreError.invalidEnrollmentPayload("version") }
        guard let e = items["endpoint"], let url = URL(string: e), let host = url.host else {
            throw SpectreError.invalidEnrollmentPayload("endpoint")
        }
        let isLocal = host == "127.0.0.1" || host == "localhost"
        if url.scheme != "https" && !(allowInsecureLocalhost && isLocal && url.scheme == "http") {
            throw SpectreError.invalidEnrollmentPayload("endpoint must be https")
        }
        if !allowInsecureLocalhost && !(host == "script.google.com" || host.hasSuffix(".run.app")) {
            // Production endpoints: Apps Script web app, or the documented Cloud Run fallback.
            throw SpectreError.invalidEnrollmentPayload("unexpected endpoint host")
        }
        guard let code = items["code"], code.count >= 20, code.count <= 64,
              code.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw SpectreError.invalidEnrollmentPayload("code")
        }
        return EnrollmentInvite(endpoint: url, code: code)
    }
}

public final class CredentialVault: @unchecked Sendable {
    private let secrets: SecretStore
    public init(secrets: SecretStore) { self.secrets = secrets }

    public func load() -> DeviceCredentials? {
        guard let d = (try? secrets.get(SecretKeys.deviceCredentials)) ?? nil else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(DeviceCredentials.self, from: d)
    }

    public func save(_ c: DeviceCredentials) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try secrets.set(enc.encode(c), for: SecretKeys.deviceCredentials)
    }

    public func clear() throws { try secrets.delete(SecretKeys.deviceCredentials) }

    public func enroll(using invite: EnrollmentInvite, backend: DepositBackend) async throws -> DeviceCredentials {
        let c = try await backend.enroll(endpoint: invite.endpoint, inviteCode: invite.code)
        try save(c)
        return c
    }
}
