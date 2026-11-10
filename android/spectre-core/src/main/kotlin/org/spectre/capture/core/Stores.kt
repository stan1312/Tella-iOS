// SPECTRE Capture — spectre-core
// Persistence abstractions. On Android the SecretStore is backed by a key held
// in the Android Keystore (non-exportable) and the queue lives in
// noBackupFilesDir (excluded from backups and device transfer).
package org.spectre.capture.core

import com.google.gson.Gson
import com.google.gson.GsonBuilder
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap

/** Small secrets: device credential, per-capture outbox keys, resumable session URLs. */
interface SecretStore {
    fun set(key: String, data: ByteArray)
    fun get(key: String): ByteArray?
    fun delete(key: String)
}

class InMemorySecretStore : SecretStore {
    private val items = ConcurrentHashMap<String, ByteArray>()
    override fun set(key: String, data: ByteArray) { items[key] = data.copyOf() }
    override fun get(key: String): ByteArray? = items[key]?.copyOf()
    override fun delete(key: String) { items.remove(key) }
    val allKeys: Set<String> get() = items.keys.toSet()
}

/** File-backed secret store used ONLY by tests to simulate an app restart. */
class FileSecretStoreForTests(private val dir: File) : SecretStore {
    init { dir.mkdirs() }
    private fun file(key: String) = File(dir, SpectreCrypto.sha256Hex(key))
    override fun set(key: String, data: ByteArray) { Files.atomicWrite(file(key), data) }
    override fun get(key: String): ByteArray? = file(key).takeIf { it.exists() }?.readBytes()
    override fun delete(key: String) { file(key).delete() }
}

object SecretKeys {
    const val deviceCredentials = "spectre.device.credentials"
    fun outboxKey(id: String) = "spectre.outbox.key.$id"
    fun session(id: String) = "spectre.upload.session.$id"
}

/** Durable queue of capture records (one JSON file per capture, atomic writes). */
interface QueueStore {
    fun load(id: String): CaptureRecord?
    fun save(record: CaptureRecord)
    fun all(): List<CaptureRecord>
    fun remove(id: String)
}

class FileQueueStore(val directory: File) : QueueStore {
    private val lock = Any()
    private val gson: Gson = GsonBuilder().create()
    /** Hook so the platform layer can apply extra protection to written files. */
    var didWriteFile: ((File) -> Unit)? = null

    init { directory.mkdirs() }

    // captureId is a lowercase UUID; anything else is refused (path traversal).
    private fun file(id: String) = File(directory, "capture-$id.json")

    override fun load(id: String): CaptureRecord? {
        if (!Validation.isUUID(id)) return null
        synchronized(lock) {
            val f = file(id)
            if (!f.exists()) return null
            return decode(f.readText(Charsets.UTF_8))
        }
    }

    override fun save(record: CaptureRecord) {
        if (!Validation.isUUID(record.captureId)) throw SpectreException.InvalidCaptureId()
        synchronized(lock) {
            val f = file(record.captureId)
            Files.atomicWrite(f, gson.toJson(record).toByteArray(Charsets.UTF_8))
            didWriteFile?.invoke(f)
        }
    }

    override fun all(): List<CaptureRecord> = synchronized(lock) {
        (directory.listFiles() ?: emptyArray())
            .filter { it.name.startsWith("capture-") && it.name.endsWith(".json") }
            .mapNotNull { runCatching { decode(it.readText(Charsets.UTF_8)) }.getOrNull() }
            .sortedBy { it.createdAt }
    }

    override fun remove(id: String) {
        if (!Validation.isUUID(id)) return
        synchronized(lock) { file(id).delete() }
    }

    private fun decode(json: String): CaptureRecord {
        val r = gson.fromJson(json, CaptureRecord::class.java)
        // Gson bypasses Kotlin defaults: normalise collections that may be absent.
        @Suppress("SENSELESS_COMPARISON")
        if (r.localCopies == null) r.localCopies = mutableListOf()
        @Suppress("SENSELESS_COMPARISON")
        if (r.remainingCopies == null) r.remainingCopies = mutableListOf()
        return r
    }
}

object Files {
    /** Write to a sibling temp file, fsync, then rename over the target (atomic on POSIX). */
    fun atomicWrite(target: File, data: ByteArray) {
        target.parentFile?.mkdirs()
        val tmp = File(target.parentFile, ".${target.name}.tmp")
        FileOutputStream(tmp).use { out ->
            out.write(data)
            out.fd.sync()
        }
        if (!tmp.renameTo(target)) {
            target.delete()
            if (!tmp.renameTo(target)) throw java.io.IOException("atomic rename failed")
        }
    }
}

object Validation {
    private val UUID = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    private val SHA256 = Regex("^[0-9a-f]{64}$")
    fun isUUID(s: String) = UUID.matches(s)
    fun isSHA256Hex(s: String) = SHA256.matches(s)
}
