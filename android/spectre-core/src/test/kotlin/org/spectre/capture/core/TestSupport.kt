// SPECTRE Capture — spectre-core tests: helpers (synthetic data only).
package org.spectre.capture.core

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.Socket
import java.net.URI
import java.net.URL
import java.nio.file.Files as NioFiles
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assume

object Repo {
    val root: File = File(System.getProperty("spectre.repoRoot") ?: "../..").canonicalFile
}

class TestClock {
    private val offset = AtomicLong(0)
    fun now(): Long = System.currentTimeMillis() + offset.get()
    fun advanceSec(s: Long) { offset.addAndGet(s * 1000) }
}

/** Deterministic synthetic "video" bytes (fictional data only). Same generator as the iOS tests. */
fun syntheticBytes(n: Int, seed: Int = 1): ByteArray {
    var x = seed
    val d = ByteArray(n)
    for (i in 0 until n) { x = x * 1664525 + 1013904223; d[i] = (x ushr 24).toByte() }
    return d
}

fun tempDir(name: String = "spectre"): File = NioFiles.createTempDirectory("$name-").toFile()

fun newCaptureId(): String = UUID.randomUUID().toString()

/** Launches backend/mock-stack/server.mjs (REAL Apps Script code in a Node vm + MockDrive). */
class MockStack {
    val base: String
    val webApp: String
    private val process: Process

    companion object {
        fun nodePath(): String? {
            System.getenv("SPECTRE_NODE")?.let { return it }
            val path = System.getenv("PATH") ?: ""
            for (dir in path.split(File.pathSeparator) + listOf("/opt/node22/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin")) {
                val f = File(dir, "node")
                if (f.canExecute()) return f.path
            }
            return null
        }
    }

    init {
        val node = nodePath()
        Assume.assumeTrue("node not found: mock stack unavailable (set SPECTRE_NODE)", node != null)
        val server = File(Repo.root, "backend/mock-stack/server.mjs")
        check(server.exists()) { "missing ${server.path}" }
        process = ProcessBuilder(node, server.path, "--port=0").redirectErrorStream(true).start()
        val reader = BufferedReader(InputStreamReader(process.inputStream))
        val deadline = System.currentTimeMillis() + 15_000
        var found: String? = null
        while (System.currentTimeMillis() < deadline) {
            val line = reader.readLine() ?: break
            if (line.startsWith("MOCK_STACK_READY ")) { found = line.removePrefix("MOCK_STACK_READY ").trim(); break }
        }
        if (found == null) { process.destroyForcibly(); error("mock stack did not start") }
        base = found
        webApp = "$base/macros/s/MOCK/exec"
        Thread { runCatching { while (reader.readLine() != null) {} } }.apply { isDaemon = true }.start()
    }

    fun stop() {
        runCatching { process.outputStream.close() }
        process.destroy()
        process.waitFor(5, TimeUnit.SECONDS)
        if (process.isAlive) process.destroyForcibly()
    }

    private fun request(path: String, method: String = "GET", json: String? = null): JsonObject {
        val c = URL(base + path).openConnection() as HttpURLConnection
        c.requestMethod = method
        if (json != null) { c.doOutput = true; c.setRequestProperty("Content-Type", "application/json"); c.outputStream.use { it.write(json.toByteArray()) } }
        val text = (if (c.responseCode >= 400) c.errorStream else c.inputStream)?.use { String(it.readBytes()) } ?: "{}"
        return JsonParser.parseString(text).asJsonObject
    }

    fun control(json: String) { request("/__control", "POST", json) }
    fun inviteLink(label: String = "membre-test"): String = request("/__admin/invite?label=$label").get("link").asString
    fun revoke(deviceId: String) { request("/__admin/revoke?deviceId=$deviceId") }
    fun ownerFiles(): List<JsonObject> = request("/__owner/files").getAsJsonArray("files").map { it.asJsonObject }
    fun dropsDone(): Int = request("/__owner/files").get("dropsDone").asInt
    fun backendLogs(): List<String> = request("/__admin/logs").getAsJsonArray("logs").map { it.asString }
    fun ownerDownload(id: String): ByteArray = (URL("$base/__owner/content?id=$id").openConnection() as HttpURLConnection).inputStream.use { it.readBytes() }
}

/** Raw HTTP/1.1 request to 127.0.0.1 (HttpURLConnection cannot send PATCH). Returns the status code. */
fun rawStatus(method: String, url: String, headers: Map<String, String> = emptyMap()): Int {
    val u = URI(url)
    Socket(u.host, u.port).use { s ->
        val path = (u.rawPath ?: "/") + (u.rawQuery?.let { "?$it" } ?: "")
        val sb = StringBuilder("$method $path HTTP/1.1\r\nHost: ${u.host}:${u.port}\r\nConnection: close\r\nContent-Length: 0\r\n")
        for ((k, v) in headers) sb.append("$k: $v\r\n")
        sb.append("\r\n")
        s.getOutputStream().write(sb.toString().toByteArray())
        val line = BufferedReader(InputStreamReader(s.getInputStream())).readLine() ?: return -1
        return line.split(" ")[1].toInt()
    }
}

/** Stand-in for the Tella vault entry (encrypted container + DB row). */
class FakeVault(val dir: File) : LocalCopyHandler {
    override val kind = LocalCopyKind.vaultEntry
    @Volatile var failDeletes = false
    init { dir.mkdirs() }
    fun add(id: String, data: ByteArray) = File(dir, id).writeBytes(data)
    override fun delete(ref: LocalCopyRef) {
        if (failDeletes) throw java.io.IOException("FakeVault")
        File(dir, ref.reference).delete()
    }
    override fun exists(ref: LocalCopyRef) = File(dir, ref.reference).exists()
    fun has(id: String) = File(dir, "vault-$id").exists()
}

/** One simulated phone: stores, outbox, engine wired to a backend. */
class Phone(
    val root: File = tempDir("phone"),
    backend: DepositBackend? = null,
    val transport: HttpTransport = UrlConnectionTransport(connectTimeoutMs = 5_000, readTimeoutMs = 20_000),
    chunk: Int = 512 * 1024,
    verifier: ReceiptVerifier = ReceiptVerifier(),
    retry: RetryPolicy = RetryPolicy(baseDelayMs = 0, maxDelayMs = 0, maxAutomaticAttempts = 6, maxPendingChecks = 10)
) {
    val secrets = FileSecretStoreForTests(File(root, "keychain"))
    val store = FileQueueStore(File(root, "queue"))
    val outbox = EncryptedOutbox(File(root, "outbox"), secrets, segmentSize = 64 * 1024)
    val vault = FakeVault(File(root, "vault"))
    val logs = MemoryLogSink()
    val clock = TestClock()
    val tmp = File(root, "tmp").apply { mkdirs() }
    val engine = DepositEngine(store, outbox, secrets, backend ?: HttpDepositBackend(transport),
        ResumableUploader(transport, chunk), verifier,
        DeletionCoordinator(listOf(OutboxCopyHandler(outbox), vault,
            FileCopyHandler(LocalCopyKind.plaintextTemp, tmp), FileCopyHandler(LocalCopyKind.cameraOriginalTemp, tmp))),
        retry, { clock.now() }, SpectreLog(logs))

    /** Simulates "stop recording": camera temp file + vault entry + durable task + outbox. */
    fun capture(bytes: ByteArray, captureId: String = newCaptureId(), mimeType: String = "video/mp4", ext: String = "mp4"): String {
        val cam = File(tmp, "movie-$captureId.$ext")
        cam.writeBytes(bytes)
        vault.add("vault-$captureId", "ENCRYPTED-BY-TELLA".toByteArray() + bytes.copyOf(16))
        engine.register(captureId, mimeType, ext, listOf(
            LocalCopyRef(LocalCopyKind.vaultEntry, "vault-$captureId"),
            LocalCopyRef(LocalCopyKind.cameraOriginalTemp, cam.path)))
        engine.prepare(captureId, cam, SpectreCrypto.sha256Hex(bytes))
        return captureId
    }

    fun enroll(stack: MockStack): DeviceCredentials {
        val invite = EnrollmentParser.parse(stack.inviteLink(), allowInsecureLocalhost = true)
        return CredentialVault(secrets).enroll(invite, HttpDepositBackend(transport))
    }

    /** Drives the engine until a terminal/halted state (bounded). */
    fun run(id: String, maxPasses: Int = 40, until: ((CaptureRecord) -> Boolean)? = null): CaptureRecord {
        var last: CaptureRecord? = null
        for (i in 0 until maxPasses) {
            val r = engine.process(id) ?: break
            last = r
            if (until != null && until(r)) break
            if (r.stage == CaptureStage.completed || r.stage == CaptureStage.blocked) break
            val f = r.failure
            if (f != null && f.nextAttemptAt == null) break      // halted: needs a human / enrolment
            if (f?.kind == FailureKind.network) Thread.sleep(500)  // let the simulated network come back
            clock.advanceSec(120)
        }
        return last!!
    }
}
