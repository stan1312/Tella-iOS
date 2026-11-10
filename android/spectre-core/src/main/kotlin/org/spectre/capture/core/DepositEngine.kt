// SPECTRE Capture — spectre-core
// Persistent, idempotent state machine (same as iOS DepositEngine):
//   awaitingPreparation → queued → uploading → awaitingVerification → confirmed → completed
// Every transition is written to the QueueStore BEFORE the next side effect,
// so a crash at any point resumes safely. Local copies are deleted only from
// `confirmed`, with a receipt re-verified at deletion time.
// Blocking API: call from a background thread (WorkManager worker on Android).
package org.spectre.capture.core

import java.io.File
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

data class RetryPolicy(
    val baseDelayMs: Long = 5_000,
    val maxDelayMs: Long = 15 * 60_000,
    val maxAutomaticAttempts: Int = 8,
    val maxPendingChecks: Int = 20
) {
    fun delayForAttempt(n: Int): Long {
        val exp = baseDelayMs.toDouble() * Math.pow(2.0, maxOf(0, n - 1).toDouble())
        return minOf(maxDelayMs.toDouble(), exp).toLong()
    }
}

class DepositEngine(
    private val store: QueueStore,
    private val outbox: EncryptedOutbox,
    private val secrets: SecretStore,
    private val backend: DepositBackend,
    private val uploader: ResumableUploader,
    private val verifier: ReceiptVerifier = ReceiptVerifier(),
    private val deletion: DeletionCoordinator,
    private val retry: RetryPolicy = RetryPolicy(),
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val log: SpectreLog = SpectreLog(null)
) {
    private val credentials = CredentialVault(secrets)
    private val inFlight: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private val pendingChecks = ConcurrentHashMap<String, Int>()
    private val observers = CopyOnWriteArrayList<(CaptureRecord) -> Unit>()
    private val intakeLock = Any()

    fun addObserver(o: (CaptureRecord) -> Unit) { observers.add(o) }

    // ---------------------------------------------------------------- intake

    /** Step 1 (at the end of recording): durable task creation. Idempotent. */
    fun register(captureId: String = UUID.randomUUID().toString(), mimeType: String, fileExtension: String,
                 localCopies: List<LocalCopyRef>): CaptureRecord = synchronized(intakeLock) {
        store.load(captureId)?.let { return it }
        val r = CaptureRecord(captureId = captureId, createdAt = clock(), mimeType = mimeType,
            fileExtension = fileExtension, stage = CaptureStage.awaitingPreparation,
            localCopies = (localCopies + LocalCopyRef(LocalCopyKind.outboxEncrypted, captureId)).toMutableList())
        persist(r)
        log.event("registered", mapOf("capture" to captureId))
        r
    }

    /** Step 2: build the encrypted outbox from the original plaintext file. */
    fun prepare(captureId: String, plaintext: File, expectedSha256: String?): CaptureRecord =
        prepareWith(captureId, expectedSha256) { outbox.importPlaintext(plaintext, captureId) }

    /** Step 2 (stream variant, e.g. decrypted Tella vault stream of known length). */
    fun prepare(captureId: String, input: InputStream, size: Long, expectedSha256: String?): CaptureRecord =
        prepareWith(captureId, expectedSha256) { outbox.importStream(input, size, captureId) }

    private fun prepareWith(captureId: String, expectedSha256: String?, build: () -> FileFingerprint): CaptureRecord {
        val r = store.load(captureId) ?: throw SpectreException.InvalidCaptureId()
        if (r.stage != CaptureStage.awaitingPreparation) return r
        try {
            val fp = build()
            val e = expectedSha256?.lowercase()
            if (!e.isNullOrEmpty() && e != fp.sha256) { runCatching { outbox.destroy(captureId) }; throw SpectreException.OutboxCorrupted() }
            if (fp.size <= 0) { runCatching { outbox.destroy(captureId) }; throw SpectreException.ProtocolViolation("empty") }
            r.fingerprint = fp
            r.stage = CaptureStage.queued
            r.failure = null
            persist(r)
            log.event("prepared", mapOf("capture" to captureId, "bytes" to fp.size.toString()))
        } catch (e: Exception) {
            r.failure = CaptureFailure(FailureKind.preparationFailed,
                "Préparation de l'envoi impossible ; l'enregistrement reste dans le coffre.",
                (r.failure?.attempts ?: 0) + 1, null)
            persist(r)
            throw e
        }
        return r
    }

    // ---------------------------------------------------------------- queries

    fun record(id: String): CaptureRecord? = store.load(id)
    fun allRecords(): List<CaptureRecord> = store.all()

    /** Earliest date (epoch ms) at which processAll has something to do (for scheduling). */
    fun nextWakeAt(): Long? = store.all().mapNotNull { r ->
        when (r.stage) {
            CaptureStage.completed, CaptureStage.blocked, CaptureStage.awaitingPreparation -> null
            else -> r.failure?.nextAttemptAt ?: r.notBefore ?: (if (r.failure == null) clock() else null)
        }
    }.minOrNull()

    /** True while some capture still needs work that the engine can do on its own. */
    fun hasAutomaticWork(): Boolean = nextWakeAt() != null

    // ---------------------------------------------------------------- user actions

    /** "Réessayer": clears a halted failure. After an integrity block, a brand-new upload is requested. */
    fun retryNow(id: String) {
        val r = store.load(id) ?: return
        if (r.stage == CaptureStage.blocked) {
            r.stage = CaptureStage.queued
            r.forceNewUpload = true
            r.uploadId = null
            r.driveFileIdFromUpload = null
            r.receipt = null
            r.bytesConfirmedByServer = 0
            runCatching { secrets.delete(SecretKeys.session(id)) }
        }
        r.failure = null
        r.transientAttempts = 0
        r.notBefore = null
        pendingChecks[id] = 0
        persist(r)
    }

    // ---------------------------------------------------------------- processing

    fun processAll() { for (r in store.all()) process(r.captureId) }

    fun process(id: String): CaptureRecord? {
        if (!inFlight.add(id)) return store.load(id)   // T08: no concurrent duplicate
        try {
            var steps = 0
            while (steps < 12) {
                steps++
                val r = store.load(id) ?: return null
                val now = clock()
                val f = r.failure
                if (f != null) {
                    val at = f.nextAttemptAt
                    if (!f.kind.isAutomaticallyRetryable || at == null || at > now) return r
                }
                val nb = r.notBefore
                if (nb != null && nb > now) return r
                when (r.stage) {
                    CaptureStage.awaitingPreparation, CaptureStage.completed, CaptureStage.blocked, CaptureStage.failed -> return r
                    CaptureStage.queued -> authorize(r)
                    CaptureStage.uploading -> upload(r)
                    CaptureStage.awaitingVerification -> finalize(r)
                    CaptureStage.confirmed -> deleteLocal(r)
                }
                val after = store.load(id) ?: return null
                if (after.failure != null || after.notBefore != null) return after
            }
            return store.load(id)
        } finally {
            inFlight.remove(id)
        }
    }

    private fun authorize(r: CaptureRecord) {
        val creds = credentials.load() ?: return fail(r, FailureKind.notEnrolled, "Appareil non enrôlé ; scannez votre invitation.")
        val fp = r.fingerprint ?: return fail(r, FailureKind.preparationFailed, "Empreinte manquante")
        try {
            when (val res = backend.initUpload(InitUploadRequest(r.captureId, fp.size, fp.sha256, fp.md5, r.mimeType,
                r.fileExtension, r.renewSession, r.forceNewUpload), creds)) {
                is InitUploadResult.Session -> {
                    secrets.set(SecretKeys.session(r.captureId), res.sessionUrl.toByteArray(Charsets.UTF_8))
                    if (r.uploadId != res.uploadId) { r.driveFileIdFromUpload = null; r.bytesConfirmedByServer = 0 }
                    r.uploadId = res.uploadId
                    r.stage = CaptureStage.uploading
                }
                is InitUploadResult.FinalizeExisting -> {
                    r.uploadId = res.uploadId
                    r.stage = CaptureStage.awaitingVerification
                }
                is InitUploadResult.AlreadyVerified -> {
                    r.uploadId = res.receipt.uploadId
                    acceptReceipt(r, res.receipt, creds)
                    if (r.stage != CaptureStage.confirmed) return
                }
            }
            r.renewSession = false
            r.forceNewUpload = false
            succeed(r)
            log.event("authorized", mapOf("capture" to r.captureId))
        } catch (e: Exception) {
            handle(r, e)
        }
    }

    private fun upload(r0: CaptureRecord) {
        var r = r0
        val fp = r.fingerprint ?: return fail(r, FailureKind.preparationFailed, "Empreinte manquante")
        val session = secrets.get(SecretKeys.session(r.captureId))?.let { String(it, Charsets.UTF_8) }
        if (session == null) { r.stage = CaptureStage.queued; persist(r); return }
        val id = r.captureId
        try {
            val fileId = uploader.upload(session, fp.size,
                read = { off, len -> outbox.readPlaintext(id, off, len) },
                progress = { confirmed ->
                    val cur = store.load(id)
                    if (cur != null && cur.bytesConfirmedByServer != confirmed) {
                        cur.bytesConfirmedByServer = confirmed
                        cur.updatedAt = clock()
                        store.save(cur)
                        notifyObservers(cur)
                    }
                })
            r = store.load(id) ?: r
            r.driveFileIdFromUpload = fileId
            r.bytesConfirmedByServer = fp.size
            r.stage = CaptureStage.awaitingVerification
            succeed(r)
            log.event("uploaded", mapOf("capture" to id, "bytes" to fp.size.toString()))
        } catch (e: SpectreException.SessionExpired) {
            r = store.load(id) ?: r
            runCatching { secrets.delete(SecretKeys.session(id)) }
            r.renewSession = true
            r.stage = CaptureStage.queued
            r.bytesConfirmedByServer = 0
            handle(r, e)
        } catch (e: Exception) {
            r = store.load(id) ?: r
            handle(r, e)
        }
    }

    private fun finalize(r: CaptureRecord) {
        val creds = credentials.load() ?: return fail(r, FailureKind.notEnrolled, "Appareil non enrôlé")
        val uid = r.uploadId
        if (uid == null) { r.stage = CaptureStage.queued; persist(r); return }
        try {
            when (val res = backend.finalize(uid, r.captureId, r.driveFileIdFromUpload, creds)) {
                is FinalizeResult.Verified -> acceptReceipt(r, res.receipt, creds)
                is FinalizeResult.Pending -> {
                    val n = (pendingChecks[r.captureId] ?: 0) + 1
                    pendingChecks[r.captureId] = n
                    if (n > retry.maxPendingChecks) {
                        fail(r, FailureKind.serverUnavailable, "Vérification Drive non disponible pour l'instant ; l'enregistrement reste sur le téléphone.")
                    } else {
                        r.notBefore = clock() + (maxOf(1.0, res.retryAfterSec) * 1000).toLong()
                        persist(r)
                    }
                }
                FinalizeResult.Incomplete -> { r.stage = CaptureStage.uploading; persist(r) }
                is FinalizeResult.Mismatch -> block(r, FailureKind.integrityMismatch, "Le fichier sur le Drive ne correspond pas (${res.detail}). Original conservé.")
            }
        } catch (e: Exception) {
            handle(r, e)
        }
    }

    private fun acceptReceipt(r: CaptureRecord, receipt: DepositReceipt, creds: DeviceCredentials) {
        when (val v = verifier.verify(receipt, r, creds)) {
            is ReceiptVerification.Verified -> {
                r.receipt = receipt
                r.stage = CaptureStage.confirmed   // persisted BEFORE any deletion
                succeed(r)
                runCatching { secrets.delete(SecretKeys.session(r.captureId)) }
                log.event("verified", mapOf("capture" to r.captureId))
            }
            is ReceiptVerification.Rejected -> block(r, v.kind, v.reason + ". Original conservé.")
        }
    }

    private fun deleteLocal(r: CaptureRecord) {
        val creds = credentials.load()
        val receipt = r.receipt
        if (creds == null || receipt == null) return fail(r, FailureKind.notEnrolled, "Reçu ou identifiants indisponibles ; suppression différée.")
        // Re-verify at deletion time (receipt read back from disk).
        val v = verifier.verify(receipt, r, creds)
        if (v !is ReceiptVerification.Verified) return block(r, FailureKind.receiptInvalid, "Reçu stocké invalide ; suppression bloquée.")
        val report = deletion.deleteLocalCopies(r, v.proof)
        r.remainingCopies = report.failed.keys.sortedBy { it.name }.toMutableList()
        if (report.allDeleted) {
            r.stage = CaptureStage.completed
            succeed(r)
            log.event("local-deleted", mapOf("capture" to r.captureId, "copies" to report.deleted.size.toString()))
        } else {
            val attempts = (r.failure?.attempts ?: 0) + 1
            r.failure = CaptureFailure(FailureKind.localDeletionFailed,
                "Transfert confirmé, mais une copie locale n'a pas pu être supprimée.", attempts,
                clock() + retry.delayForAttempt(attempts))
            persist(r)
            log.event("local-delete-incomplete", mapOf("capture" to r.captureId, "copies" to report.failed.size.toString()))
        }
    }

    // ---------------------------------------------------------------- failure handling

    private fun handle(r: CaptureRecord, error: Exception) {
        val (kind, msg) = classify(error)
        if (kind == FailureKind.integrityMismatch || kind == FailureKind.receiptInvalid) return block(r, kind, msg)
        val attempts = r.transientAttempts + 1
        r.transientAttempts = attempts
        val auto = kind.isAutomaticallyRetryable && attempts < retry.maxAutomaticAttempts
        r.failure = CaptureFailure(kind, msg, attempts, if (auto) clock() + retry.delayForAttempt(attempts) else null)
        persist(r)
        log.event("failure", mapOf("capture" to r.captureId, "kind" to kind.name, "attempt" to attempts.toString()))
    }

    private fun fail(r: CaptureRecord, kind: FailureKind, msg: String) {
        r.failure = CaptureFailure(kind, msg, r.transientAttempts + 1, null)
        persist(r)
        log.event("failure", mapOf("capture" to r.captureId, "kind" to kind.name))
    }

    private fun block(r: CaptureRecord, kind: FailureKind, msg: String) {
        r.stage = CaptureStage.blocked
        r.failure = CaptureFailure(kind, msg, r.transientAttempts, null)
        persist(r)
        log.event("blocked", mapOf("capture" to r.captureId, "kind" to kind.name))
    }

    private fun succeed(r: CaptureRecord) {
        r.failure = null
        r.transientAttempts = 0
        r.notBefore = null
        persist(r)
    }

    private fun persist(r: CaptureRecord) {
        r.updatedAt = clock()
        store.save(r)
        notifyObservers(r)
    }

    private fun notifyObservers(r: CaptureRecord) {
        val snapshot = r.copyDeep()
        for (o in observers) runCatching { o(snapshot) }
    }

    companion object {
        fun classify(error: Exception): Pair<FailureKind, String> = when (error) {
            is SpectreException.Transport -> FailureKind.network to "Réseau indisponible ; nouvel essai automatique."
            is SpectreException.SessionExpired -> FailureKind.sessionExpired to "Session d'envoi expirée ; une nouvelle sera demandée."
            is SpectreException.Http -> when {
                error.status == 429 -> FailureKind.rateLimited to "Trop de requêtes ; nouvel essai plus tard."
                error.status >= 500 -> FailureKind.serverUnavailable to "Service Google indisponible (${error.status})."
                error.status == 401 || error.status == 403 -> FailureKind.deviceNotAuthorized to "Envoi refusé par le serveur (${error.status})."
                else -> FailureKind.invalidRequest to "Requête refusée (${error.status})."
            }
            is SpectreException.OutboxKeyMissing, is SpectreException.OutboxCorrupted, is SpectreException.OutboxRange ->
                FailureKind.preparationFailed to "Copie d'envoi locale illisible ; l'original du coffre est conservé."
            is SpectreException.Backend -> when (error.code) {
                "DEVICE_REVOKED" -> FailureKind.deviceNotAuthorized to "Cet appareil a été révoqué par le responsable."
                "DEVICE_EXPIRED" -> FailureKind.deviceNotAuthorized to "L'autorisation de cet appareil a expiré."
                "AUTH_INVALID", "REPLAY" -> FailureKind.deviceNotAuthorized to "Authentification refusée."
                "RATE_LIMITED" -> FailureKind.rateLimited to "Trop de requêtes ; nouvel essai plus tard."
                "QUOTA_EXCEEDED" -> FailureKind.quotaExceeded to "Quota de dépôt de l'appareil atteint ; nouvel essai plus tard."
                "DRIVE_QUOTA" -> FailureKind.driveQuotaExceeded to "Espace Drive du responsable plein ; enregistrement conservé."
                "DRIVE_UNAVAILABLE", "INTERNAL", "BUSY" -> FailureKind.serverUnavailable to "Service Google indisponible."
                "FILE_TOO_LARGE" -> FailureKind.fileTooLarge to "Fichier trop volumineux pour la politique de dépôt."
                "MISMATCH" -> FailureKind.integrityMismatch to "Incohérence d'intégrité signalée par le serveur."
                else -> FailureKind.invalidRequest to "Requête refusée (${error.code})."
            }
            else -> FailureKind.unknown to "Erreur inattendue ; l'enregistrement est conservé."
        }
    }
}
