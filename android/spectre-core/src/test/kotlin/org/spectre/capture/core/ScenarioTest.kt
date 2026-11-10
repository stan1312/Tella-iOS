// End-to-end scenarios T01–T15 on synthetic data:
// Kotlin client (spectre-core) ⇄ REAL Apps Script code (Node vm) ⇄ MockDrive.
// Same scenarios as SpectreCore/Tests/ScenarioTests.swift (iOS).
package org.spectre.capture.core

import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume
import org.junit.Before
import org.junit.Test

class ScenarioTest {
    private lateinit var stack: MockStack

    @Before fun setUp() { stack = MockStack() }
    @After fun tearDown() { if (::stack.isInitialized) stack.stop() }

    private fun allLocalCopiesGone(p: Phone, id: String): Boolean {
        val r = p.store.load(id)!!
        val camGone = r.localCopies.filter { it.kind == LocalCopyKind.cameraOriginalTemp }.all { !File(it.reference).exists() }
        return !p.outbox.exists(id) && !p.outbox.hasKey(id) && !p.vault.has(id) && camGone
    }

    // T01 + T13
    @Test fun t01_shortVideoStableNetwork_verifiedThenAllCopiesDeleted() {
        val p = Phone()
        p.enroll(stack)
        val bytes = syntheticBytes(1_900_000, 1)
        val id = p.capture(bytes)
        val r = p.run(id)
        assertEquals(r.failure.toString(), CaptureStage.completed, r.stage)
        assertEquals(SpectreCrypto.sha256Hex(bytes), r.receipt?.sha256)
        assertEquals("sha256", r.receipt?.checksumSource)
        assertTrue(r.remainingCopies.isEmpty())
        assertTrue(allLocalCopiesGone(p, id))
        val files = stack.ownerFiles()
        assertEquals(1, files.size)
        assertEquals("original bytes unmodified on Drive", SpectreCrypto.sha256Hex(bytes), files[0].get("sha256").asString)
        assertTrue(files[0].get("name").asString.endsWith(".mp4"))
        assertEquals(UserFacingStatus.Confirmed, r.userFacingStatus)
        assertEquals("Transfert confirmé — supprimée du téléphone", r.userFacingStatus.labelFR)
    }

    // Home screen: current deposit folder name only.
    @Test fun depositStatusReturnsCurrentFolderNameOnly() {
        val p = Phone()
        val creds = p.enroll(stack)
        val st = HttpDepositBackend(p.transport).depositStatus(creds)
        assertEquals(DepositStatus("SPECTRE_DEPOT_TEST", false), st)
    }

    // Dictaphone: an m4a recording follows the same verified path as a video.
    @Test fun audioRecordingIsDepositedAndVerified() {
        val p = Phone()
        p.enroll(stack)
        val id = p.capture(syntheticBytes(300_000, 4), mimeType = "audio/mp4", ext = "m4a")
        val r = p.run(id)
        assertEquals(r.failure.toString(), CaptureStage.completed, r.stage)
        assertTrue(allLocalCopiesGone(p, id))
        assertTrue(stack.ownerFiles()[0].get("name").asString.endsWith(".m4a"))
    }

    // T03: airplane mode before stopping the recording
    @Test fun t03_offlineCaptureKeepsOriginalAndVisibleTask() {
        val p = Phone()
        CredentialVault(p.secrets).save(DeviceCredentials("http://127.0.0.1:9/macros/s/MOCK/exec", "d_0123456789abcdef", "a".repeat(64), 0))
        val id = p.capture(syntheticBytes(700_000))
        val r = p.run(id, maxPasses = 3)
        assertEquals(CaptureStage.queued, r.stage)
        assertEquals(FailureKind.network, r.failure?.kind)
        assertNotNull("automatic retry is scheduled", r.failure?.nextAttemptAt)
        assertTrue(p.outbox.exists(id)); assertTrue(p.vault.has(id))
        val st = r.userFacingStatus
        assertTrue(st.toString(), st is UserFacingStatus.Error && st.retryable)
        p.enroll(stack)   // back online
        p.engine.retryNow(id)
        assertEquals(CaptureStage.completed, p.run(id).stage)
    }

    // T04: cuts at 10 %, 50 % and 99 %
    @Test fun t04_cutsAt10_50_99PercentResumeWithoutLossOrPrematureDeletion() {
        stack.control("""{"driveFaults":{"dropAtFractions":[0.10,0.50,0.99]}}""")
        val p = Phone()
        p.enroll(stack)
        val bytes = syntheticBytes(5 * 1024 * 1024 + 333, 4)
        val id = p.capture(bytes)
        var failuresSeen = 0
        var r: CaptureRecord? = null
        for (i in 0 until 40) {
            r = p.engine.process(id)!!
            if (r.failure != null) {
                assertTrue("nothing deleted while the upload is incomplete", p.outbox.exists(id) && p.vault.has(id))
                assertNull(r.receipt)
                assertNotEquals(CaptureStage.confirmed, r.stage)
                failuresSeen++
                Thread.sleep(500)
            }
            if (r.stage == CaptureStage.completed) break
            p.clock.advanceSec(60)
        }
        assertEquals(CaptureStage.completed, r!!.stage)
        assertEquals("three network cuts performed by the mock (10/50/99 %)", 3, stack.dropsDone())
        assertTrue(failuresSeen >= 3)
        val files = stack.ownerFiles()
        assertEquals(1, files.size)
        assertEquals(SpectreCrypto.sha256Hex(bytes), files[0].get("sha256").asString)
    }

    // T05: app killed during upload, phone rebooted → state recovered from disk
    @Test fun t05_crashMidUploadRecoversFromDisk() {
        val root = tempDir("phone-crash")
        val bytes = syntheticBytes(3 * 1024 * 1024, 5)
        val p1 = Phone(root)
        p1.enroll(stack)
        val id = p1.capture(bytes)
        stack.control("""{"driveFaults":{"dropAtFractions":[0.5],"offlineMsAfterDrop":3000}}""")
        val mid = p1.engine.process(id)!!     // network dies at 50 %
        assertEquals(CaptureStage.uploading, mid.stage)
        assertTrue(mid.bytesConfirmedByServer > 0)
        // p1 (engine, transport, memory) is abandoned: "kill -9"
        Thread.sleep(3_100)
        val p2 = Phone(root)                    // relaunch with the same on-disk state + secrets
        val before = p2.store.load(id)!!
        assertEquals(CaptureStage.uploading, before.stage)
        assertTrue(p2.outbox.exists(id))
        assertEquals(CaptureStage.completed, p2.run(id).stage)
        assertEquals(1, stack.ownerFiles().size)
    }

    // T06: HTTP success on upload but file missing on Drive
    @Test fun t06_httpSuccessButDriveFileAbsent_deletionBlocked() {
        val p = Phone()
        p.enroll(stack)
        stack.control("""{"driveFaults":{"getFault":"missing"}}""")
        val id = p.capture(syntheticBytes(400_000))
        var r: CaptureRecord? = null
        repeat(5) { r = p.engine.process(id)!!; p.clock.advanceSec(60) }
        val rr = r!!
        assertNotNull("Drive answered 200 to the final chunk", rr.driveFileIdFromUpload)
        assertTrue(rr.stage.toString(), rr.stage == CaptureStage.awaitingVerification || rr.stage == CaptureStage.uploading)
        assertNull(rr.receipt)
        assertTrue(p.outbox.exists(id)); assertTrue(p.vault.has(id))
        val st = rr.userFacingStatus
        assertTrue(st.toString(), st is UserFacingStatus.Verifying || st is UserFacingStatus.Transferring)
    }

    // T07: remote size / checksum differs
    @Test fun t07_remoteSizeOrChecksumDiffers_blockedWithVisibleAlert() {
        for (fault in listOf("sizeWrong", "sha256Wrong", "md5Wrong")) {
            stack.control("""{"reset":true}""")
            val p = Phone()
            p.enroll(stack)
            stack.control("""{"driveFaults":{"getFault":"$fault"}}""")
            val id = p.capture(syntheticBytes(300_000, 7))
            val r = p.run(id)
            assertEquals(fault, CaptureStage.blocked, r.stage)
            assertEquals(fault, FailureKind.integrityMismatch, r.failure?.kind)
            assertTrue(fault, r.userFacingStatus is UserFacingStatus.Blocked)
            assertTrue(fault, p.outbox.exists(id)); assertTrue(fault, p.vault.has(id))
            // after the problem is fixed, "Renvoyer" uploads a NEW copy and then completes
            stack.control("""{"driveFaults":{}}""")
            p.engine.retryNow(id)
            assertEquals(fault, CaptureStage.completed, p.run(id).stage)
        }
    }

    // T07b: forged / altered receipt (MITM) never authorises deletion
    @Test fun t07b_tamperedReceiptBlocksDeletion() {
        val inner = HttpDepositBackend(UrlConnectionTransport())
        val tampering = object : DepositBackend {
            override fun enroll(endpoint: String, inviteCode: String) = inner.enroll(endpoint, inviteCode)
            override fun initUpload(req: InitUploadRequest, credentials: DeviceCredentials) = inner.initUpload(req, credentials)
            override fun finalize(uploadId: String, captureId: String, driveFileId: String?, credentials: DeviceCredentials): FinalizeResult {
                val r = inner.finalize(uploadId, captureId, driveFileId, credentials)
                return if (r is FinalizeResult.Verified) FinalizeResult.Verified(r.receipt.copy(verifiedAt = "2030-01-01T00:00:00.000Z")) else r
            }
        }
        val p = Phone(backend = tampering)
        p.enroll(stack)
        val id = p.capture(syntheticBytes(300_000))
        val r = p.run(id)
        assertEquals(CaptureStage.blocked, r.stage)
        assertEquals(FailureKind.receiptInvalid, r.failure?.kind)
        assertTrue(p.outbox.exists(id))
    }

    // T08: double tap / concurrent retries
    @Test fun t08_concurrentProcessingIsIdempotent() {
        val p = Phone()
        p.enroll(stack)
        val id = p.capture(syntheticBytes(2 * 1024 * 1024, 8))
        p.engine.register(id, "video/mp4", "mp4", emptyList())   // re-register: no-op
        val pool = Executors.newFixedThreadPool(3)
        repeat(3) { pool.submit { p.engine.process(id) } }
        pool.shutdown(); assertTrue(pool.awaitTermination(60, TimeUnit.SECONDS))
        p.engine.retryNow(id)
        assertEquals(CaptureStage.completed, p.run(id).stage)
        assertEquals("no uncontrolled duplicate on Drive", 1, stack.ownerFiles().size)
        assertEquals(1, p.store.all().size)
    }

    // T09: revoked device
    @Test fun t09_revokedDeviceCannotUploadAndKeepsOriginal() {
        val p = Phone()
        val creds = p.enroll(stack)
        stack.revoke(creds.deviceId)
        val id = p.capture(syntheticBytes(300_000))
        val r = p.run(id)
        assertEquals(FailureKind.deviceNotAuthorized, r.failure?.kind)
        assertNull("no hammering after revocation", r.failure?.nextAttemptAt)
        assertEquals("Cet appareil a été révoqué par le responsable.", r.failure?.message)
        assertTrue(p.outbox.exists(id))
        assertEquals(0, stack.ownerFiles().size)
    }

    // T10: compromised phone — everything it holds, inspected and replayed by an attacker
    @Test fun t10_compromisedPhoneCannotListReadDownloadOrDelete() {
        val victim = Phone()
        victim.enroll(stack)
        val vid = victim.capture(syntheticBytes(300_000, 10))
        val done = victim.run(vid)
        val victimFile = done.receipt!!.driveFileId

        val p = Phone()
        val creds = p.enroll(stack)
        stack.control("""{"driveFaults":{"dropAtFractions":[0.5],"offlineMsAfterDrop":300}}""")
        val id = p.capture(syntheticBytes(1_000_000, 11))
        val mid = p.engine.process(id)!!
        assertEquals(CaptureStage.uploading, mid.stage)
        Thread.sleep(400)
        val session = String(p.secrets.get(SecretKeys.session(id))!!)
        val base = stack.base
        val probes = listOf(
            Triple("GET", "$base/drive/v3/files", emptyMap()),
            Triple("GET", "$base/drive/v3/files", mapOf("Authorization" to "Bearer ${creds.secretHex}")),
            Triple("GET", "$base/drive/v3/files/$victimFile?alt=media", emptyMap()),
            Triple("DELETE", "$base/drive/v3/files/$victimFile", emptyMap()),
            Triple("PATCH", "$base/drive/v3/files/$victimFile", emptyMap()),
            Triple("GET", session, emptyMap<String, String>()),
        )
        for ((m, u, h) in probes) {
            val s = rawStatus(m, u, h)
            assertTrue("$m → $s", s == 401 || s == 404)
        }
        // and the deposit API itself refuses anything but deposit
        try {
            HttpDepositBackend(UrlConnectionTransport()).finalize(done.uploadId!!, vid, victimFile, creds)
            fail("cross-device finalize must fail")
        } catch (e: SpectreException.Backend) { assertEquals("NOT_FOUND", e.code) }
        // nothing in the phone's secret store looks like a Google OAuth token / key
        for (k in listOf(SecretKeys.deviceCredentials, SecretKeys.session(id), SecretKeys.outboxKey(id))) {
            val v = String(p.secrets.get(k) ?: ByteArray(0), Charsets.ISO_8859_1)
            assertFalse(k, v.contains("ya29.") || v.contains("BEGIN PRIVATE KEY") || v.contains("refresh_token"))
        }
    }

    // T11: Google unavailable, Drive full, owner token expired, Apps Script 503 → no loss, bounded retry, actionable errors
    @Test fun t11_googleFailuresAreBoundedAndActionable() {
        val cases = listOf(
            """{"driveFaults":{"storageQuotaExceeded":true}}""" to FailureKind.driveQuotaExceeded,
            """{"driveFaults":{"driveDown":true}}""" to FailureKind.serverUnavailable,
            """{"driveFaults":{"ownerTokenExpired":true}}""" to FailureKind.serverUnavailable,
            """{"backendFaults":{"unavailable":1000}}""" to FailureKind.serverUnavailable,
        )
        for ((fault, kind) in cases) {
            stack.control("""{"reset":true}""")
            val p = Phone()
            p.enroll(stack)
            stack.control(fault)
            val id = p.capture(syntheticBytes(200_000))
            val r = p.run(id, maxPasses = 20)
            assertEquals(fault, kind, r.failure?.kind)
            assertEquals("bounded by RetryPolicy.maxAutomaticAttempts", 6, r.failure?.attempts)
            assertNull("stops after the bound", r.failure?.nextAttemptAt)
            assertTrue(fault, p.outbox.exists(id))
            assertFalse(r.failure!!.message.isEmpty())
        }
    }

    // T12: synthetic MP4/MOV with technical metadata (+ fictional GPS), incl. 4K60, arrive byte-identical
    @Test fun t12_originalAndMetadataPreservedByteForByte() {
        val dir = File(Repo.root, "tests/fixtures/generated")
        val names = listOf("short_1080p30_meta.mov", "short_2160p60.mov", "android_1080p30_meta.mp4")
        Assume.assumeTrue("run scripts/make_fixtures.sh and scripts/android_make_fixtures.sh first (needs ffmpeg)",
            names.all { File(dir, it).exists() })
        for (name in names) {
            val src = File(dir, name)
            val bytes = src.readBytes()
            val p = Phone()
            p.enroll(stack)
            val (mime, ext) = if (name.endsWith(".mp4")) "video/mp4" to "mp4" else "video/quicktime" to "mov"
            val id = p.capture(bytes, mimeType = mime, ext = ext)
            val r = p.run(id)
            assertEquals(name, CaptureStage.completed, r.stage)
            val downloaded = stack.ownerDownload(r.receipt!!.driveFileId)
            assertArrayEquals("$name: Drive copy is the unmodified original", bytes, downloaded)
            val out = File(tempDir("dl"), "x.$ext").apply { writeBytes(downloaded) }
            val a = Ffmpeg.probe(src); val b = Ffmpeg.probe(out)
            if (a != null && b != null) {
                assertEquals(name, a, b)
                if (name.contains("meta")) {
                    assertTrue(a, a.contains("creation_time=2026-11-04T12:00:00"))
                    assertTrue(a, a.contains("location=+00.0000+000.0000/"))
                }
            }
        }
    }

    // T14: two phones at the same time
    @Test fun t14_twoDevicesSimultaneously() {
        val a = Phone(); val b = Phone()
        a.enroll(stack); b.enroll(stack)
        val ida = a.capture(syntheticBytes(1_500_000, 21))
        val idb = b.capture(syntheticBytes(1_500_000, 22))
        val pool = Executors.newFixedThreadPool(2)
        val fa = pool.submit<CaptureRecord> { a.run(ida) }
        val fb = pool.submit<CaptureRecord> { b.run(idb) }
        val x = fa.get(120, TimeUnit.SECONDS); val y = fb.get(120, TimeUnit.SECONDS)
        pool.shutdown()
        assertEquals(CaptureStage.completed, x.stage); assertEquals(CaptureStage.completed, y.stage)
        assertNotEquals(x.receipt?.driveFileId, y.receipt?.driveFileId)
        assertNotEquals(x.receipt?.deviceId, y.receipt?.deviceId)
        assertEquals(2, stack.ownerFiles().size)
    }

    // Logs: no session URL, no secret, no owner token in client or backend journals
    @Test fun logsContainNoSensitiveData() {
        val p = Phone()
        val creds = p.enroll(stack)
        val id = p.capture(syntheticBytes(300_000))
        p.run(id)
        val client = p.logs.all.joinToString("\n")
        val backend = stack.backendLogs().joinToString("\n")
        for (blob in listOf(client, backend)) {
            assertFalse(blob.contains("upload_id")); assertFalse(blob.contains("://"))
            assertFalse(blob.contains(creds.secretHex)); assertFalse(blob.contains("ya29."))
        }
        assertFalse(client.isEmpty())
    }

    // T02: long video (multi-GB when SPECTRE_LARGE_TEST_BYTES is set)
    @Test fun t02_largeVideoOriginalUnmodified() {
        val size = System.getenv("SPECTRE_LARGE_TEST_BYTES")?.toLongOrNull() ?: (64L * 1024 * 1024)
        val root = tempDir("phone-large")
        try {
            val tmp = File(root, "tmp").apply { mkdirs() }
            val src = File(tmp, "large.mp4")
            src.outputStream().buffered(8 shl 20).use { out ->
                var written = 0L; var seed = 77
                while (written < size) {
                    val n = minOf(8L * 1024 * 1024, size - written).toInt()
                    out.write(syntheticBytes(n, seed)); seed++; written += n
                }
            }
            val expected = StreamingDigest.fingerprint(src)
            stack.control("""{"driveFaults":{"dropAtFractions":[0.5]}}""")
            val p = Phone(root, chunk = 8 * 1024 * 1024)
            p.enroll(stack)
            val id = newCaptureId()
            p.vault.add("vault-$id", byteArrayOf(1))
            p.engine.register(id, "video/mp4", "mp4", listOf(LocalCopyRef(LocalCopyKind.vaultEntry, "vault-$id"),
                LocalCopyRef(LocalCopyKind.cameraOriginalTemp, src.path)))
            val prepared = p.engine.prepare(id, src, expected.sha256)
            assertEquals(expected, prepared.fingerprint)
            val r = p.run(id, maxPasses = 60)
            assertEquals(r.failure.toString(), CaptureStage.completed, r.stage)
            assertEquals(expected.sha256, stack.ownerFiles()[0].get("sha256").asString)
            println("T02 bytes=$size sha256=${expected.sha256}")
        } finally { root.deleteRecursively() }
    }

    // Tella vault path on Android: the outbox is built from a decrypted STREAM (no plaintext temp file).
    @Test fun streamPreparationFromVaultStream() {
        val p = Phone()
        p.enroll(stack)
        val bytes = syntheticBytes(1_234_567, 31)
        val id = newCaptureId()
        p.vault.add("vault-$id", byteArrayOf(9))
        p.engine.register(id, "video/mp4", "mp4", listOf(LocalCopyRef(LocalCopyKind.vaultEntry, "vault-$id")))
        p.engine.prepare(id, bytes.inputStream(), bytes.size.toLong(), SpectreCrypto.sha256Hex(bytes))
        val r = p.run(id)
        assertEquals(CaptureStage.completed, r.stage)
        assertFalse(p.vault.has(id))
        assertArrayEquals(bytes, stack.ownerDownload(r.receipt!!.driveFileId))
    }

    // Dictaphone end to end: Tella ADTS recording → m4a (no re-encoding) → Drive → decodes to the same audio.
    @Test fun dictaphoneAdtsIsRewrappedToM4aAndDeposited() {
        val adts = Ffmpeg.makeAdts(tempDir("adts"), seconds = 3)
        Assume.assumeTrue("ffmpeg not available", adts != null)
        val src = adts!!.readBytes()
        val plan = AdtsToM4a.scan(src.inputStream())
        val p = Phone()
        p.enroll(stack)
        val id = newCaptureId()
        p.vault.add("vault-$id", byteArrayOf(9))
        p.engine.register(id, "audio/mp4", "m4a", listOf(LocalCopyRef(LocalCopyKind.vaultEntry, "vault-$id")))
        p.engine.prepare(id, AdtsToM4a.M4aInputStream(src.inputStream(), plan), plan.outputSize, null)
        val r = p.run(id)
        assertEquals(r.failure.toString(), CaptureStage.completed, r.stage)
        val m4a = File(tempDir("m4a"), "rec.m4a").apply { writeBytes(stack.ownerDownload(r.receipt!!.driveFileId)) }
        assertEquals(Ffmpeg.decodedMd5(adts), Ffmpeg.decodedMd5(m4a))
    }

    // Invitation received as an https link inside a message, then a deposit.
    @Test fun httpsInvitationLinkInAMessageEnrolsAndDeposits() {
        val p = Phone()
        val link = stack.httpsInviteLink()
        assertTrue(link, link.contains("/macros/s/MOCK/exec?i="))
        p.enrollWith("Rejoins le dépôt SPECTRE :\n$link\n(Lien personnel.)")
        val bytes = syntheticBytes(300_000, 31)
        val r = p.run(p.capture(bytes))
        assertEquals(r.failure.toString(), CaptureStage.completed, r.stage)
        // single use
        assertThrows(SpectreException::class.java) { Phone().enrollWith(link) }
    }
}
