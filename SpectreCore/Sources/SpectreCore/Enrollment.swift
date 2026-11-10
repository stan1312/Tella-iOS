//  SPECTRE Capture — SpectreCore
//  Individual enrolment via QR code / invitation link:
//  spectre://enroll?v=1&endpoint=<https URL>&code=<one-time invite code>
//  or the shareable web-app form: https://script.google.com/macros/s/<id>/exec?i=<code>
//  (endpoint = the URL without its query, code = i).
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
        if let comps = URLComponents(string: trimmed), comps.scheme == "https" || comps.scheme == "http" {
            return try parseWebLink(comps, allowInsecureLocalhost: allowInsecureLocalhost)
        }
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
        return EnrollmentInvite(endpoint: url, code: try validCode(items["code"]))
    }

    /// `https://script.google.com/macros/s/<deployment id>/exec?i=<code>`: the invitation link the
    /// owner can paste in a message. Only the Apps Script web-app shape is accepted in production.
    private static func parseWebLink(_ comps: URLComponents, allowInsecureLocalhost: Bool) throws -> EnrollmentInvite {
        guard let host = comps.host, comps.user == nil, comps.password == nil else {
            throw SpectreError.invalidEnrollmentPayload("format")
        }
        let isLocal = host == "127.0.0.1" || host == "localhost"
        if comps.scheme != "https" && !(allowInsecureLocalhost && isLocal) {
            throw SpectreError.invalidEnrollmentPayload("endpoint must be https")
        }
        let segs = comps.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let isWebApp = host == "script.google.com" && segs.count == 5 && segs[0].isEmpty
            && segs[1] == "macros" && segs[2] == "s" && segs[4] == "exec"
            && !segs[3].isEmpty && segs[3].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        guard (isWebApp && comps.port == nil) || (allowInsecureLocalhost && isLocal) else {
            throw SpectreError.invalidEnrollmentPayload("unexpected endpoint host")
        }
        guard comps.fragment == nil else { throw SpectreError.invalidEnrollmentPayload("format") }
        let items = comps.queryItems ?? []
        guard items.count == 1, items[0].name == "i" else { throw SpectreError.invalidEnrollmentPayload("format") }
        var base = comps
        base.query = nil
        guard let url = base.url else { throw SpectreError.invalidEnrollmentPayload("endpoint") }
        return EnrollmentInvite(endpoint: url, code: try validCode(items[0].value))
    }

    private static func validCode(_ code: String?) throws -> String {
        guard let code, code.count >= 20, code.count <= 64,
              code.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw SpectreError.invalidEnrollmentPayload("code")
        }
        return code
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
