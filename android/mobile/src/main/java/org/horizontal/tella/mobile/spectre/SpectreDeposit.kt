// SPECTRE Capture — glue between Tella Android and spectre-core.
//
// Flow: CameraX / dictaphone record → Tella encrypts into its vault (unchanged)
// → handleNewCapture() registers a durable task and builds the SPECTRE
// encrypted outbox from the decrypted vault STREAM (no plaintext temp file;
// dictaphone ADTS is re-wrapped to .m4a on the fly) → SpectreDepositWorker
// (WorkManager, network required, survives reboots) uploads to Drive through a
// backend-issued resumable session → backend verifies → receipt verified →
// every managed local copy (outbox + Tella vault entry) is deleted.
//
// Only active in the "spectre" flavor (BuildConfig.SPECTRE_ENABLED).
package org.horizontal.tella.mobile.spectre

import android.content.Context
import androidx.lifecycle.MutableLiveData
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import com.hzontal.tella_vault.VaultFile
import com.hzontal.tella_vault.rx.RxVault
import io.reactivex.subjects.AsyncSubject
import org.horizontal.tella.mobile.BuildConfig
import org.horizontal.tella.mobile.MyApplication
import org.horizontal.tella.mobile.media.MediaFileHandler
import org.spectre.capture.core.AdtsToM4a
import org.spectre.capture.core.CaptureRecord
import org.spectre.capture.core.CaptureStage
import org.spectre.capture.core.CredentialVault
import org.spectre.capture.core.DeletionCoordinator
import org.spectre.capture.core.DepositEngine
import org.spectre.capture.core.EncryptedOutbox
import org.spectre.capture.core.EnrollmentParser
import org.spectre.capture.core.FailureKind
import org.spectre.capture.core.FileQueueStore
import org.spectre.capture.core.Hex
import org.spectre.capture.core.HttpDepositBackend
import org.spectre.capture.core.LocalCopyRef
import org.spectre.capture.core.LocalCopyKind
import org.spectre.capture.core.OutboxCopyHandler
import org.spectre.capture.core.ResumableUploader
import org.spectre.capture.core.SecretKeys
import org.spectre.capture.core.SpectreCrypto
import org.spectre.capture.core.SpectreException
import org.spectre.capture.core.SpectreLog
import org.spectre.capture.core.UrlConnectionTransport
import timber.log.Timber
import java.io.File
import java.io.IOException
import java.security.DigestInputStream
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

object SpectreDeposit {
    private const val WORK_NOW = "spectre-deposit"
    private const val WORK_LATER = "spectre-deposit-later"
    private const val WORK_PERIODIC = "spectre-deposit-periodic"

    val enabled: Boolean get() = BuildConfig.SPECTRE_ENABLED

    /** Observed by the home card and the status screen (main thread). */
    val records = MutableLiveData<List<CaptureRecord>>(emptyList())
    val enrolled = MutableLiveData(false)
    val depositName = MutableLiveData<String?>(null)
    val depositIsEvent = MutableLiveData(false)

    @Volatile private var engine: DepositEngine? = null
    @Volatile private var secrets: SpectreKeystoreSecretStore? = null
    private lateinit var appContext: Context
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "spectre-intake").apply { isDaemon = true } }
    private val preparing = HashSet<String>()

    private val transport = UrlConnectionTransport(connectTimeoutMs = 30_000, readTimeoutMs = 120_000)
    private val backend = HttpDepositBackend(transport)

    // ---------------------------------------------------------------- setup

    @JvmStatic
    fun init(context: Context) {
        if (!enabled) return
        engineOrInit(context)
        schedulePeriodic()
        io.execute { refreshNow() }
    }

    @Synchronized
    fun engineOrInit(context: Context): DepositEngine? {
        if (!enabled) return null
        engine?.let { return it }
        appContext = context.applicationContext
        return try {
            val root = File(appContext.noBackupFilesDir, "spectre")
            val s = SpectreKeystoreSecretStore(appContext)
            val store = FileQueueStore(File(root, "queue"))
            val outbox = EncryptedOutbox(File(root, "outbox"), s)
            val deletion = DeletionCoordinator(listOf(OutboxCopyHandler(outbox), TellaVaultCopyHandler()))
            val e = DepositEngine(store, outbox, s, backend, ResumableUploader(transport, 8 * 1024 * 1024),
                deletion = deletion, log = SpectreLog(null))   // no technical journal on the phone
            e.addObserver { postRefresh() }
            secrets = s
            engine = e
            e
        } catch (t: Throwable) {
            Timber.e(t, "SPECTRE init failed")
            null
        }
    }

    // ---------------------------------------------------------------- vault access

    /** True when Tella's vault key is in memory (app unlocked); never blocks. */
    fun vaultUnlocked(): Boolean = try {
        MyApplication.getMainKeyHolder().exists() &&
            (MyApplication.keyRxVault.rxVault as? AsyncSubject<*>)?.hasComplete() == true
    } catch (t: Throwable) { false }

    internal fun rxVaultOrNull(): RxVault? = if (vaultUnlocked()) MyApplication.keyRxVault.rxVault.blockingFirst() else null

    // ---------------------------------------------------------------- capture intake

    /** Deterministic capture id derived from the Tella vault id (same derivation as iOS). */
    fun captureIdForVaultFileId(id: String): String {
        val c = SpectreCrypto.sha256Hex("spectre-capture:$id").substring(0, 32)
        return "${c.substring(0, 8)}-${c.substring(8, 12)}-4${c.substring(13, 16)}-a${c.substring(17, 20)}-${c.substring(20, 32)}"
    }

    private fun kindOf(vaultFile: VaultFile): Pair<String, String>? {
        val mime = vaultFile.mimeType ?: return null
        return when {
            mime.startsWith("video/") -> "video/mp4" to "mp4"            // CameraX records MP4
            mime == "audio/aac" || mime == "audio/mp4" || mime == "audio/x-m4a" -> "audio/mp4" to "m4a"
            else -> null                                                 // photos stay in the vault only
        }
    }

    /** Camera videos and dictaphone recordings become durable deposit tasks. Idempotent. */
    @JvmStatic
    fun handleNewCapture(vaultFile: VaultFile?) {
        if (!enabled || vaultFile == null) return
        val e = engine ?: return
        val (mime, ext) = kindOf(vaultFile) ?: return
        val captureId = captureIdForVaultFileId(vaultFile.id)
        io.execute {
            try {
                // 1) durable task, created immediately at the end of the recording
                e.register(captureId, mime, ext, listOf(LocalCopyRef(LocalCopyKind.vaultEntry, vaultFile.id)))
                refreshNow()
                // 2) outbox (needs the unlocked vault; otherwise retried at next unlock)
                prepare(e, captureId, vaultFile)
                kick()
            } catch (t: Throwable) {
                Timber.e(t, "SPECTRE intake failed")
                refreshNow()
            }
        }
    }

    /** Builds the outbox for every capture still waiting for it (called after unlock). */
    @JvmStatic
    fun onVaultUnlocked() {
        if (!enabled) return
        val e = engine ?: return
        // Also refresh the demonstration name shown on the home card (signed `status` action).
        refreshDepositStatus()
        io.execute {
            val vault = rxVaultOrNull() ?: return@execute
            for (r in e.allRecords().filter { it.stage == CaptureStage.awaitingPreparation }) {
                val ref = r.localCopies.firstOrNull { it.kind == LocalCopyKind.vaultEntry } ?: continue
                val vf = runCatching { vault.get(ref.reference).blockingGet() }.getOrNull() ?: continue
                runCatching { prepare(e, r.captureId, vf) }
            }
            kick()
        }
    }

    private fun prepare(e: DepositEngine, captureId: String, vaultFile: VaultFile) {
        if (!vaultUnlocked()) return
        synchronized(preparing) { if (!preparing.add(captureId)) return }
        try {
            val r = e.record(captureId) ?: return
            if (r.stage != CaptureStage.awaitingPreparation) return
            if (r.isAudio && vaultFile.mimeType == "audio/aac") {
                // Pass 1: scan the ADTS stream and check it against Tella's own SHA-256 of the recording.
                val md = MessageDigest.getInstance("SHA-256")
                val plan = openVaultStream(vaultFile).use { AdtsToM4a.scan(DigestInputStream(it, md)) }
                val vaultHash = vaultFile.hash
                if (!vaultHash.isNullOrEmpty() && Hex.encode(md.digest()) != vaultHash.lowercase()) {
                    throw SpectreException.OutboxCorrupted()
                }
                // Pass 2: the .m4a bytes, streamed straight into the encrypted outbox.
                AdtsToM4a.M4aInputStream(openVaultStream(vaultFile), plan).use { m4a ->
                    e.prepare(captureId, m4a, plan.outputSize, null)
                }
            } else {
                openVaultStream(vaultFile).use { input ->
                    e.prepare(captureId, input, MediaFileHandler.getSize(vaultFile), vaultFile.hash)
                }
            }
            refreshNow()
        } catch (t: Throwable) {
            Timber.e(t, "SPECTRE prepare failed")
            refreshNow()
        } finally {
            synchronized(preparing) { preparing.remove(captureId) }
        }
    }

    private fun openVaultStream(vaultFile: VaultFile) =
        MediaFileHandler.getStream(vaultFile) ?: throw IOException("vault stream unavailable")

    // ---------------------------------------------------------------- processing (WorkManager)

    private fun networkConstraints() = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

    /** Runs the queue as soon as a network is available. */
    @JvmStatic
    fun kick() {
        if (!enabled || !::appContext.isInitialized) return
        val req = OneTimeWorkRequestBuilder<SpectreDepositWorker>().setConstraints(networkConstraints()).build()
        WorkManager.getInstance(appContext).enqueueUniqueWork(WORK_NOW, ExistingWorkPolicy.APPEND_OR_REPLACE, req)
    }

    /** Next automatic retry (bounded back-off decided by the engine). */
    internal fun scheduleNext(atMillis: Long?) {
        if (atMillis == null || !::appContext.isInitialized) return
        val delay = (atMillis - System.currentTimeMillis()).coerceAtLeast(0)
        val req = OneTimeWorkRequestBuilder<SpectreDepositWorker>()
            .setConstraints(networkConstraints())
            .setInitialDelay(delay, TimeUnit.MILLISECONDS)
            .build()
        WorkManager.getInstance(appContext).enqueueUniqueWork(WORK_LATER, ExistingWorkPolicy.REPLACE, req)
    }

    /** Safety net: every 15 min with network (also restarts the queue after a reboot). */
    private fun schedulePeriodic() {
        val req = PeriodicWorkRequestBuilder<SpectreDepositWorker>(15, TimeUnit.MINUTES)
            .setConstraints(networkConstraints()).build()
        WorkManager.getInstance(appContext).enqueueUniquePeriodicWork(WORK_PERIODIC, ExistingPeriodicWorkPolicy.KEEP, req)
    }

    fun retry(captureId: String) {
        val e = engine ?: return
        io.execute { runCatching { e.retryNow(captureId) }; refreshNow(); kick() }
    }

    // ---------------------------------------------------------------- state for the UI

    private fun postRefresh() { if (::appContext.isInitialized) io.execute { refreshNow() } }

    internal fun refreshNow() {
        val e = engine ?: return
        val all = runCatching { e.allRecords() }.getOrDefault(emptyList()).sortedByDescending { it.createdAt }
        records.postValue(all)
        enrolled.postValue(credentials()?.load() != null)
    }

    private fun credentials(): CredentialVault? = secrets?.let { CredentialVault(it) }

    /** Asks the backend which folder receives deposits now (label only). Silent on failure. */
    fun refreshDepositStatus() {
        if (!enabled) return
        io.execute {
            val c = credentials()?.load() ?: return@execute
            runCatching { backend.depositStatus(c) }.onSuccess {
                depositName.postValue(it.depositName)
                depositIsEvent.postValue(it.isEvent)
            }
        }
    }

    // ---------------------------------------------------------------- enrolment

    fun isEnrolled(): Boolean = credentials()?.load() != null

    /** Validates an invitation link without network access (for the confirmation dialog). */
    fun parseInvite(payload: String) = EnrollmentParser.parse(payload, allowInsecureLocalhost = BuildConfig.DEBUG)

    /** Enrols this phone with a one-time invitation; result on the intake thread. */
    fun enroll(payload: String, done: (Boolean, String?) -> Unit) {
        io.execute {
            val c = credentials()
            if (c == null) { done(false, "Service de dépôt indisponible sur cet appareil."); return@execute }
            try {
                c.enroll(parseInvite(payload), backend)
                val e = engine
                if (e != null) {
                    for (r in e.allRecords()) {
                        val k = r.failure?.kind
                        if (k == FailureKind.notEnrolled || k == FailureKind.deviceNotAuthorized) runCatching { e.retryNow(r.captureId) }
                    }
                }
                refreshNow()
                kick()
                refreshDepositStatus()
                done(true, null)
            } catch (ex: SpectreException.InvalidEnrollmentPayload) {
                done(false, "Ce n'est pas une invitation SPECTRE valide.")
            } catch (ex: SpectreException.Transport) {
                done(false, "Pas de connexion : réessayez avec du réseau.")
            } catch (ex: Exception) {
                done(false, "Invitation invalide, expirée ou déjà utilisée.")
            }
        }
    }

    // ---------------------------------------------------------------- Tella quick delete

    /**
     * Tella "quick delete": the user wants no recording left on this phone,
     * deposited or not. Removes queue records, encrypted outbox copies and their
     * keys (crypto-erase). Keeps the device enrolment unless [forgetDevice].
     */
    @JvmStatic
    @JvmOverloads
    fun wipeQueuedCaptures(forgetDevice: Boolean = false) {
        if (!enabled) return
        val s = secrets ?: return
        val e = engine
        runCatching { WorkManager.getInstance(appContext).cancelUniqueWork(WORK_NOW); WorkManager.getInstance(appContext).cancelUniqueWork(WORK_LATER) }
        val ids = runCatching { e?.allRecords()?.map { it.captureId } }.getOrNull() ?: emptyList()
        for (id in ids) {
            s.delete(SecretKeys.outboxKey(id))
            s.delete(SecretKeys.session(id))
        }
        if (forgetDevice) {
            s.deleteAll()
            SpectreKeystoreSecretStore.destroyKey()
        }
        val root = File(appContext.noBackupFilesDir, "spectre")
        File(root, "queue").deleteRecursively()
        File(root, "outbox").deleteRecursively()
        File(root, "queue").mkdirs(); File(root, "outbox").mkdirs()
        records.postValue(emptyList())
        if (forgetDevice) enrolled.postValue(false)
    }
}
