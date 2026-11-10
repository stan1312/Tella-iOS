// SPECTRE Capture — spectre-core
// The ONLY place where a VerifiedReceipt can be created. Deletion of local
// copies requires a VerifiedReceipt, so "HTTP 200", "100 % progress" or
// "no error" can never authorise a deletion by construction.
package org.spectre.capture.core

/** Constructor is internal: the app module cannot forge one. */
class VerifiedReceipt internal constructor(val receipt: DepositReceipt)

sealed class ReceiptVerification {
    data class Verified(val proof: VerifiedReceipt) : ReceiptVerification()
    data class Rejected(val kind: FailureKind, val reason: String) : ReceiptVerification()
}

class ReceiptVerifier(val allowedChecksumSources: Set<String> = setOf("sha256", "md5")) {

    fun verify(r: DepositReceipt, record: CaptureRecord, credentials: DeviceCredentials): ReceiptVerification {
        fun reject(k: FailureKind, why: String) = ReceiptVerification.Rejected(k, why)

        val expectedMac = SpectreCrypto.hmacSha256Hex(credentials.keyData, r.canonicalString)
        if (!SpectreCrypto.constantTimeEquals(expectedMac, r.mac.lowercase())) return reject(FailureKind.receiptInvalid, "Reçu non authentifié (MAC invalide)")
        if (r.v != 1) return reject(FailureKind.receiptInvalid, "Version de reçu inconnue")
        if (r.status != "VERIFIED") return reject(FailureKind.receiptInvalid, "Statut du reçu non final")
        if (r.captureId != record.captureId) return reject(FailureKind.receiptInvalid, "Reçu d'une autre captation")
        val uid = record.uploadId
        if (uid == null || r.uploadId != uid) return reject(FailureKind.receiptInvalid, "Reçu d'un autre envoi")
        if (r.deviceId != credentials.deviceId) return reject(FailureKind.receiptInvalid, "Reçu d'un autre appareil")
        if (r.driveFileId.isEmpty()) return reject(FailureKind.receiptInvalid, "Identifiant Drive absent")
        val fromUpload = record.driveFileIdFromUpload
        if (fromUpload != null && fromUpload != r.driveFileId) return reject(FailureKind.integrityMismatch, "Identifiant Drive différent de celui renvoyé à l'envoi")
        val fp = record.fingerprint ?: return reject(FailureKind.receiptInvalid, "Empreinte locale inconnue")
        if (r.size != fp.size) return reject(FailureKind.integrityMismatch, "Taille distante différente")
        if (r.sha256.lowercase() != fp.sha256) return reject(FailureKind.integrityMismatch, "SHA-256 différent")
        if (r.md5.lowercase() != fp.md5) return reject(FailureKind.integrityMismatch, "MD5 différent")
        if (r.checksumSource !in allowedChecksumSources) return reject(FailureKind.receiptInvalid, "Méthode de vérification non acceptée (${r.checksumSource})")
        return ReceiptVerification.Verified(VerifiedReceipt(r))
    }
}
