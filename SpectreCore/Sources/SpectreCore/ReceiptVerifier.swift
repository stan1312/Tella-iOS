//  SPECTRE Capture — SpectreCore
//  The ONLY place where a `VerifiedReceipt` can be created. Deletion of local
//  copies requires a `VerifiedReceipt`, so "HTTP 200", "100 % progress" or
//  "no error" can never authorise a deletion by construction.

import Foundation

public struct VerifiedReceipt: Sendable, Equatable {
    public let receipt: DepositReceipt
    // internal init: other modules (the iOS app) cannot forge one.
    init(_ r: DepositReceipt) { receipt = r }
}

public enum ReceiptVerification: Equatable, Sendable {
    case verified(VerifiedReceipt)
    case rejected(kind: FailureKind, reason: String)
}

public struct ReceiptVerifier: Sendable {
    public var allowedChecksumSources: Set<String>

    public init(allowedChecksumSources: Set<String> = ["sha256", "md5"]) {
        self.allowedChecksumSources = allowedChecksumSources
    }

    public func verify(_ r: DepositReceipt, record: CaptureRecord, credentials: DeviceCredentials) -> ReceiptVerification {
        func reject(_ k: FailureKind, _ why: String) -> ReceiptVerification { .rejected(kind: k, reason: why) }

        let expectedMac = SpectreCrypto.hmacSHA256Hex(key: credentials.keyData, message: r.canonicalString)
        guard SpectreCrypto.constantTimeEquals(expectedMac, r.mac.lowercased()) else {
            return reject(.receiptInvalid, "Reçu non authentifié (MAC invalide)")
        }
        guard r.v == 1 else { return reject(.receiptInvalid, "Version de reçu inconnue") }
        guard r.status == "VERIFIED" else { return reject(.receiptInvalid, "Statut du reçu non final") }
        guard r.captureId == record.captureId else { return reject(.receiptInvalid, "Reçu d'une autre captation") }
        guard let uid = record.uploadId, r.uploadId == uid else { return reject(.receiptInvalid, "Reçu d'un autre envoi") }
        guard r.deviceId == credentials.deviceId else { return reject(.receiptInvalid, "Reçu d'un autre appareil") }
        guard !r.driveFileId.isEmpty else { return reject(.receiptInvalid, "Identifiant Drive absent") }
        if let fromUpload = record.driveFileIdFromUpload, fromUpload != r.driveFileId {
            return reject(.integrityMismatch, "Identifiant Drive différent de celui renvoyé à l'envoi")
        }
        guard let fp = record.fingerprint else { return reject(.receiptInvalid, "Empreinte locale inconnue") }
        guard r.size == fp.size else { return reject(.integrityMismatch, "Taille distante différente") }
        guard r.sha256.lowercased() == fp.sha256 else { return reject(.integrityMismatch, "SHA-256 différent") }
        guard r.md5.lowercased() == fp.md5 else { return reject(.integrityMismatch, "MD5 différent") }
        guard allowedChecksumSources.contains(r.checksumSource) else {
            return reject(.receiptInvalid, "Méthode de vérification non acceptée (\(r.checksumSource))")
        }
        return .verified(VerifiedReceipt(r))
    }
}
