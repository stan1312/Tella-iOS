// SPECTRE Capture — spectre-core
// Persistent model of one capture travelling through the deposit pipeline.
// Mirrors SpectreCore/Models.swift (iOS) so both apps behave identically.
package org.spectre.capture.core

/** Kinds of local copies the app manages for one capture. */
enum class LocalCopyKind {
    outboxEncrypted,     // SPECTRE encrypted outbox container (+ its key)
    vaultEntry,          // Tella vault: encrypted container + DB row (incl. thumbnail)
    plaintextTemp,       // decrypted temp file used while preparing the outbox
    cameraOriginalTemp,  // camera / recorder temp file
    uploadChunkTemp
}

enum class FailureKind {
    network, serverUnavailable, rateLimited, quotaExceeded, driveQuotaExceeded,
    deviceNotAuthorized, notEnrolled, sessionExpired, fileTooLarge, insufficientStorage,
    preparationFailed, integrityMismatch, receiptInvalid, localDeletionFailed, invalidRequest, unknown;

    /** Whether the engine may retry on its own (bounded). */
    val isAutomaticallyRetryable: Boolean
        get() = when (this) {
            network, serverUnavailable, rateLimited, sessionExpired, driveQuotaExceeded, quotaExceeded -> true
            else -> false
        }
}

enum class CaptureStage {
    awaitingPreparation,  // vault entry exists; outbox not built yet (needs unlocked vault)
    queued,               // outbox ready, waiting for network/authorization
    uploading,            // resumable session active
    awaitingVerification, // all bytes sent; waiting for server-side verification
    confirmed,            // verified receipt stored; local deletion pending
    completed,            // receipt verified AND all managed local copies deleted
    failed,
    blocked               // integrity problem; original kept; needs human attention
}

data class CaptureFailure(
    val kind: FailureKind,
    val message: String,          // non-sensitive, user-facing (FR)
    val attempts: Int,
    val nextAttemptAt: Long?      // epoch ms
)

data class LocalCopyRef(val kind: LocalCopyKind, val reference: String)

data class CaptureRecord(
    var captureId: String,
    var createdAt: Long,
    var mimeType: String,
    var fileExtension: String,
    var fingerprint: FileFingerprint? = null,
    var stage: CaptureStage,
    var uploadId: String? = null,
    var driveFileIdFromUpload: String? = null,
    var bytesConfirmedByServer: Long = 0,
    var receipt: DepositReceipt? = null,
    var failure: CaptureFailure? = null,
    var localCopies: MutableList<LocalCopyRef> = mutableListOf(),
    var remainingCopies: MutableList<LocalCopyKind> = mutableListOf(),
    var transientAttempts: Int = 0,
    /** Scheduled wait that is not an error (e.g. Drive checksum not computed yet). */
    var notBefore: Long? = null,
    var forceNewUpload: Boolean = false,
    var renewSession: Boolean = false,
    var updatedAt: Long = createdAt
) {
    fun copyDeep(): CaptureRecord = copy(localCopies = localCopies.toMutableList(), remainingCopies = remainingCopies.toMutableList())

    val isAudio: Boolean get() = mimeType.startsWith("audio/")

    val userFacingStatus: UserFacingStatus
        get() {
            val f = failure
            return when (stage) {
                CaptureStage.awaitingPreparation, CaptureStage.queued ->
                    if (f != null) UserFacingStatus.Error(f.kind.isAutomaticallyRetryable, f.message) else UserFacingStatus.Pending
                CaptureStage.uploading -> {
                    if (f != null) UserFacingStatus.Error(f.kind.isAutomaticallyRetryable, f.message)
                    else {
                        val total = (fingerprint?.size ?: 0L).toDouble()
                        UserFacingStatus.Transferring(if (total > 0) bytesConfirmedByServer / total else 0.0)
                    }
                }
                CaptureStage.awaitingVerification ->
                    if (f != null) UserFacingStatus.Error(f.kind.isAutomaticallyRetryable, f.message) else UserFacingStatus.Verifying
                CaptureStage.confirmed -> UserFacingStatus.ConfirmedLocalCopyRemains
                CaptureStage.completed -> if (remainingCopies.isEmpty()) UserFacingStatus.Confirmed else UserFacingStatus.ConfirmedLocalCopyRemains
                CaptureStage.failed -> UserFacingStatus.Error(f?.kind?.isAutomaticallyRetryable ?: false, f?.message ?: "Erreur inconnue")
                CaptureStage.blocked -> UserFacingStatus.Blocked(f?.message ?: "Incohérence détectée")
            }
        }
}

/**
 * Receipt returned by the deposit backend once it has itself verified the
 * Drive file. Authenticated with an HMAC keyed by the device secret.
 */
data class DepositReceipt(
    val v: Int,
    val status: String,
    val captureId: String,
    val uploadId: String,
    val deviceId: String,
    val driveFileId: String,
    val size: Long,
    val sha256: String,
    val md5: String,
    val checksumSource: String,   // "sha256" or "md5"
    val verifiedAt: String,
    val mac: String
) {
    /** MUST match backend `spReceiptCanonical_`. */
    val canonicalString: String
        get() = listOf("spectre-receipt-v1", v.toString(), status, captureId, uploadId, deviceId,
            driveFileId, size.toString(), sha256, md5, checksumSource, verifiedAt).joinToString("\n")
}

/** User-facing status (same wording as the iOS app). */
sealed class UserFacingStatus {
    object Pending : UserFacingStatus()
    data class Transferring(val progress: Double) : UserFacingStatus()
    object Verifying : UserFacingStatus()
    object ConfirmedLocalCopyRemains : UserFacingStatus()
    object Confirmed : UserFacingStatus()
    data class Error(val retryable: Boolean, val message: String) : UserFacingStatus()
    data class Blocked(val message: String) : UserFacingStatus()

    val labelFR: String
        get() = when (this) {
            Pending -> "En attente (encore sur ce téléphone)"
            is Transferring -> "Transfert en cours (${Math.round(progress * 100)} %)"
            Verifying -> "Vérification sur le Drive…"
            ConfirmedLocalCopyRemains -> "Transfert confirmé — copie locale encore présente"
            Confirmed -> "Transfert confirmé — supprimée du téléphone"
            is Error -> (if (retryable) "Erreur — nouvel essai prévu : " else "Erreur — à réessayer : ") + message
            is Blocked -> "Suppression BLOQUÉE : $message"
        }
}
