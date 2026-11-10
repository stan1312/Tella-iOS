// SPECTRE Capture — spectre-core unit tests (same cases as SpectreCore UnitTests.swift).
package org.spectre.capture.core

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class OutboxTest {
    @Test fun roundTripRandomRangesAndFingerprint() {
        val dir = tempDir("outbox")
        val ob = EncryptedOutbox(dir, InMemorySecretStore(), segmentSize = 4096)
        val data = syntheticBytes(4096 * 5 + 123, 9)
        val src = File(dir, "plain.mp4").apply { writeBytes(data) }
        val id = newCaptureId()
        val fp = ob.importPlaintext(src, id)
        assertEquals(data.size.toLong(), fp.size)
        assertEquals(SpectreCrypto.sha256Hex(data), fp.sha256)
        assertEquals(fp, ob.fingerprint(id))
        for ((off, len) in listOf(0 to 10, 4090 to 20, 8192 to 4096, data.size - 5 to 100, 0 to data.size)) {
            assertArrayEquals(data.copyOfRange(off, minOf(data.size, off + len)), ob.readPlaintext(id, off.toLong(), len))
        }
        // Ciphertext does not contain plaintext
        val raw = ob.containerFile(id).readBytes()
        assertFalse(String(raw, Charsets.ISO_8859_1).contains(String(data.copyOfRange(100, 164), Charsets.ISO_8859_1)))
    }

    @Test fun tamperingIsDetected() {
        val dir = tempDir("outbox")
        val ob = EncryptedOutbox(dir, InMemorySecretStore(), segmentSize = 4096)
        val src = File(dir, "p").apply { writeBytes(syntheticBytes(10000)) }
        val id = newCaptureId()
        ob.importPlaintext(src, id)
        val raw = ob.containerFile(id).readBytes()
        raw[EncryptedOutbox.HEADER_SIZE + 50] = (raw[EncryptedOutbox.HEADER_SIZE + 50].toInt() xor 1).toByte()
        ob.containerFile(id).writeBytes(raw)
        assertThrows(SpectreException.OutboxCorrupted::class.java) { ob.readPlaintext(id, 0, 100) }
        // truncation: drop the last segment
        ob.containerFile(id).writeBytes(raw.copyOf(EncryptedOutbox.HEADER_SIZE + 4096 + 16))
        assertThrows(SpectreException::class.java) { ob.readPlaintext(id, 8192, 10) }
    }

    @Test fun destroyIsCryptographicErasure() {
        val dir = tempDir("outbox")
        val secrets = InMemorySecretStore()
        val ob = EncryptedOutbox(dir, secrets, segmentSize = 4096)
        val src = File(dir, "p").apply { writeBytes(syntheticBytes(5000)) }
        val id = newCaptureId()
        ob.importPlaintext(src, id)
        val copy = ob.containerFile(id).readBytes()   // simulates a flash remnant
        ob.destroy(id)
        assertFalse(ob.exists(id)); assertFalse(ob.hasKey(id))
        ob.containerFile(id).writeBytes(copy)
        assertThrows(SpectreException.OutboxKeyMissing::class.java) { ob.readPlaintext(id, 0, 10) }
    }

    @Test fun streamShorterThanAnnouncedIsRefusedAndLeavesNothing() {
        val ob = EncryptedOutbox(tempDir("outbox"), InMemorySecretStore(), segmentSize = 4096)
        val id = newCaptureId()
        assertThrows(SpectreException.OutboxCorrupted::class.java) { ob.importStream(syntheticBytes(5000).inputStream(), 9000, id) }
        assertFalse(ob.exists(id)); assertFalse(ob.hasKey(id))
    }

    @Test fun formatIsTheIosSpxo1Layout() {
        val ob = EncryptedOutbox(tempDir("outbox"), InMemorySecretStore(), segmentSize = 4096)
        val id = newCaptureId()
        ob.importStream(syntheticBytes(4097).inputStream(), 4097, id)
        val raw = ob.containerFile(id).readBytes()
        assertEquals("SPXO1", String(raw.copyOf(5), Charsets.US_ASCII))
        assertEquals(EncryptedOutbox.HEADER_SIZE + (4096 + 16) + (1 + 16), raw.size)
    }
}

class ReceiptVerifierTest {
    private val creds = DeviceCredentials("https://script.google.com/macros/s/x/exec", "d_0123456789abcdef", "ab".repeat(32), 0)

    private fun record(data: ByteArray): CaptureRecord {
        val d = StreamingDigest(); d.update(data)
        return CaptureRecord(captureId = newCaptureId(), createdAt = 0, mimeType = "video/mp4", fileExtension = "mp4",
            stage = CaptureStage.awaitingVerification, fingerprint = d.finish(), uploadId = "u_000000000000000000000001")
    }

    private fun receipt(r: CaptureRecord, mutate: (DepositReceipt) -> DepositReceipt = { it }, resign: Boolean = true): DepositReceipt {
        var x = DepositReceipt(1, "VERIFIED", r.captureId, r.uploadId!!, creds.deviceId, "1AbCdEfGhIjKlMnOp", r.fingerprint!!.size,
            r.fingerprint!!.sha256, r.fingerprint!!.md5, "sha256", "2026-11-04T17:00:00.000Z", "")
        x = mutate(x)
        if (resign) x = x.copy(mac = SpectreCrypto.hmacSha256Hex(creds.keyData, x.canonicalString))
        return x
    }

    @Test fun validReceipt() {
        val r = record(syntheticBytes(1000))
        assertTrue(ReceiptVerifier().verify(receipt(r), r, creds) is ReceiptVerification.Verified)
    }

    @Test fun everyFieldIsChecked() {
        val r = record(syntheticBytes(1000))
        val cases = listOf<Pair<String, (DepositReceipt) -> DepositReceipt>>(
            "status" to { it.copy(status = "PENDING") }, "capture" to { it.copy(captureId = newCaptureId()) },
            "upload" to { it.copy(uploadId = "u_999999999999999999999999") }, "device" to { it.copy(deviceId = "d_ffffffffffffffff") },
            "size" to { it.copy(size = it.size + 1) }, "sha" to { it.copy(sha256 = "0".repeat(64)) },
            "md5" to { it.copy(md5 = "0".repeat(32)) }, "drive" to { it.copy(driveFileId = "") }, "version" to { it.copy(v = 2) })
        for ((name, m) in cases) assertTrue(name, ReceiptVerifier().verify(receipt(r, m), r, creds) is ReceiptVerification.Rejected)
    }

    @Test fun forgedMacRejected() {
        val r = record(syntheticBytes(1000))
        val x = receipt(r).copy(mac = "0".repeat(64))
        assertEquals(ReceiptVerification.Rejected(FailureKind.receiptInvalid, "Reçu non authentifié (MAC invalide)"), ReceiptVerifier().verify(x, r, creds))
    }

    @Test fun driveIdMustMatchUploadResponseAndMd5PolicyIsConfigurable() {
        val r = record(syntheticBytes(1000)); r.driveFileIdFromUpload = "1ZZZZZZZZZZZZZ"
        val v = ReceiptVerifier().verify(receipt(r), r, creds)
        assertTrue(v is ReceiptVerification.Rejected && v.kind == FailureKind.integrityMismatch)
        r.driveFileIdFromUpload = null
        val md5Receipt = receipt(r, { it.copy(checksumSource = "md5") })
        assertTrue(ReceiptVerifier(setOf("sha256")).verify(md5Receipt, r, creds) is ReceiptVerification.Rejected)
        assertTrue(ReceiptVerifier().verify(md5Receipt, r, creds) is ReceiptVerification.Verified)
    }

    /** Same canonical string and HMAC as the Apps Script backend (Node crypto), computed independently. */
    @Test fun canonicalStringsMatchTheBackendDefinition() {
        val r = DepositReceipt(1, "VERIFIED", "0f8fad5b-d9cb-469f-a165-70867728950e", "u_0123456789abcdef01234567", "d_0123456789abcdef",
            "1AbCdEfGhIjKlMnOp", 1900000, "a".repeat(64), "b".repeat(32), "sha256", "2026-11-04T17:00:00.000Z", "")
        assertEquals("spectre-receipt-v1\n1\nVERIFIED\n0f8fad5b-d9cb-469f-a165-70867728950e\nu_0123456789abcdef01234567\nd_0123456789abcdef\n" +
            "1AbCdEfGhIjKlMnOp\n1900000\n${"a".repeat(64)}\n${"b".repeat(32)}\nsha256\n2026-11-04T17:00:00.000Z", r.canonicalString)
        val req = HttpDepositBackend.requestCanonical("initUpload", "d_0123456789abcdef", 1762275413, "0".repeat(32), "{}")
        assertEquals("spectre-req-v1\ninitUpload\nd_0123456789abcdef\n1762275413\n${"0".repeat(32)}\n" +
            "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a", req)
        val node = MockStack.nodePath()
        if (node != null) {
            val js = "const c=require('crypto');process.stdout.write(c.createHmac('sha256',Buffer.from(process.argv[1],'utf8')).update(process.argv[2],'utf8').digest('hex'))"
            val p = ProcessBuilder(node, "-e", js, "ab".repeat(32), req).start()
            val out = p.inputStream.bufferedReader().readText(); p.waitFor()
            assertEquals(out, SpectreCrypto.hmacSha256Hex(("ab".repeat(32)).toByteArray(), req))
        }
    }
}

class DeletionCoordinatorTest {
    @Test fun partialFailureIsReportedAndFileOutsideRootIsNeverClaimedDeleted() {
        val root = tempDir("del")
        val vault = FakeVault(File(root, "vault")); vault.add("v1", byteArrayOf(1)); vault.failDeletes = true
        val tmp = File(root, "tmp").apply { mkdirs() }
        val f = File(tmp, "a.mp4").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val outside = File(root, "elsewhere.mp4").apply { writeBytes(byteArrayOf(9)) }
        val rec = CaptureRecord(captureId = newCaptureId(), createdAt = 0, mimeType = "video/mp4", fileExtension = "mp4",
            stage = CaptureStage.confirmed, uploadId = "u_1", localCopies = mutableListOf(
                LocalCopyRef(LocalCopyKind.vaultEntry, "v1"), LocalCopyRef(LocalCopyKind.plaintextTemp, f.path),
                LocalCopyRef(LocalCopyKind.cameraOriginalTemp, outside.path)))
        val proof = VerifiedReceipt(DepositReceipt(1, "VERIFIED", rec.captureId, "u_1", "d", "x", 1, "", "", "sha256", "", ""))
        val dc = DeletionCoordinator(listOf(vault, FileCopyHandler(LocalCopyKind.plaintextTemp, tmp), FileCopyHandler(LocalCopyKind.cameraOriginalTemp, tmp)))
        val rep = dc.deleteLocalCopies(rec, proof)
        assertEquals(listOf(LocalCopyKind.plaintextTemp), rep.deleted)
        assertEquals(setOf(LocalCopyKind.vaultEntry, LocalCopyKind.cameraOriginalTemp), rep.failed.keys)
        assertTrue(outside.exists())
        assertFalse(f.exists())
        // path traversal attempt is not "inside the root"
        assertTrue(FileCopyHandler(LocalCopyKind.plaintextTemp, tmp).exists(LocalCopyRef(LocalCopyKind.plaintextTemp, "${tmp.path}/../elsewhere.mp4")))
    }
}

class EnrollmentAndLoggingTest {
    @Test fun parser() {
        val ok = "spectre://enroll?v=1&endpoint=https%3A%2F%2Fscript.google.com%2Fmacros%2Fs%2FAKfy%2Fexec&code=0123abcd-4567ef01-89abcdef-01234567"
        val inv = EnrollmentParser.parse(ok)
        assertEquals("https://script.google.com/macros/s/AKfy/exec", inv.endpoint)
        assertEquals("0123abcd-4567ef01-89abcdef-01234567", inv.code)
        for (bad in listOf("https://evil.example/enroll",
            "spectre://enroll?v=1&endpoint=http%3A%2F%2Fscript.google.com%2Fx&code=0123abcd-4567ef01-89abcdef",
            "spectre://enroll?v=1&endpoint=https%3A%2F%2Fevil.example%2Fx&code=0123abcd-4567ef01-89abcdef",
            "spectre://enroll?v=1&endpoint=https%3A%2F%2Fscript.google.com%2Fx&code=short",
            "spectre://enroll?v=2&endpoint=https%3A%2F%2Fscript.google.com%2Fx&code=0123abcd-4567ef01-89abcdef",
            "spectre://enroll?v=1&endpoint=https%3A%2F%2Fscript.google.com.evil.example%2Fx&code=0123abcd-4567ef01-89abcdef",
            "spectre://enroll?v=1&endpoint=http%3A%2F%2F127.0.0.1%3A9%2Fx&code=0123abcd-4567ef01-89abcdef")) {
            assertThrows(bad, SpectreException.InvalidEnrollmentPayload::class.java) { EnrollmentParser.parse(bad) }
        }
        // the local mock stack (tests / debug only)
        EnrollmentParser.parse("spectre://enroll?v=1&endpoint=http%3A%2F%2F127.0.0.1%3A9%2Fx&code=0123abcd-4567ef01-89abcdef", allowInsecureLocalhost = true)
    }

    @Test fun httpsInvitationLink() {
        val code = "0123abcd-4567ef01-89abcdef-01234567"
        val inv = EnrollmentParser.parse("https://script.google.com/macros/s/AKfy_cb-12/exec?i=$code")
        assertEquals("https://script.google.com/macros/s/AKfy_cb-12/exec", inv.endpoint)
        assertEquals(code, inv.code)
        for (bad in listOf(
            "http://script.google.com/macros/s/AKfy/exec?i=$code",
            "https://evil.example/macros/s/AKfy/exec?i=$code",
            "https://script.google.com.evil.example/macros/s/AKfy/exec?i=$code",
            "https://user@script.google.com/macros/s/AKfy/exec?i=$code",
            "https://script.google.com:8443/macros/s/AKfy/exec?i=$code",
            "https://script.google.com/macros/s/AKfy/exec?i=$code#x",
            "https://script.google.com/macros/s/AKfy/exec?i=$code&x=1",
            "https://script.google.com/macros/s/AKfy/dev?i=$code",
            "https://script.google.com/macros/s/AK/fy/exec?i=$code",
            "https://script.google.com/macros/s/AKfy/exec?i=short",
            "https://script.google.com/macros/s/AKfy/exec")) {
            assertThrows(bad, SpectreException.InvalidEnrollmentPayload::class.java) { EnrollmentParser.parse(bad) }
        }
        // a whole message pasted or left in the clipboard
        val msg = "Rejoins le dépôt SPECTRE : ouvre ce lien.\nhttps://script.google.com/macros/s/AKfy/exec?i=$code\n(Lien personnel.)"
        assertEquals(code, EnrollmentParser.find(msg)?.code)
        assertEquals(code, EnrollmentParser.find("voir spectre://enroll?v=1&endpoint=https%3A%2F%2Fscript.google.com%2Fmacros%2Fs%2FAKfy%2Fexec&code=$code merci")?.code)
        assertNull(EnrollmentParser.find("https://evil.example/macros/s/AKfy/exec?i=$code"))
        assertNull(EnrollmentParser.find("bonjour"))
        assertNull(EnrollmentParser.find(null))
    }

    @Test fun logRedaction() {
        val sink = MemoryLogSink()
        SpectreLog(sink).event("x", mapOf("capture" to "0f8fad5b-d9cb-469f-a165-70867728950e",
            "status" to "https://www.googleapis.com/upload?upload_id=SECRET", "kind" to "a".repeat(64), "secretField" to "leak"))
        val line = sink.all.joinToString()
        assertFalse(line.contains("upload_id")); assertFalse(line.contains("leak")); assertFalse(line.contains("a".repeat(64)))
        assertTrue(line.contains("capture=0f8fad5b "))
    }

    @Test fun statusLabels() {
        val r = CaptureRecord(captureId = newCaptureId(), createdAt = 0, mimeType = "video/mp4", fileExtension = "mp4", stage = CaptureStage.queued)
        assertEquals(UserFacingStatus.Pending, r.userFacingStatus)
        r.stage = CaptureStage.confirmed; assertEquals(UserFacingStatus.ConfirmedLocalCopyRemains, r.userFacingStatus)
        r.stage = CaptureStage.completed; assertEquals("Transfert confirmé — supprimée du téléphone", r.userFacingStatus.labelFR)
    }

    @Test fun queueStoreSurvivesRestartAndRefusesTraversal() {
        val dir = tempDir("queue")
        val s1 = FileQueueStore(dir)
        val r = CaptureRecord(captureId = newCaptureId(), createdAt = 42, mimeType = "audio/mp4", fileExtension = "m4a", stage = CaptureStage.queued,
            fingerprint = FileFingerprint(3, "a".repeat(64), "b".repeat(32)), localCopies = mutableListOf(LocalCopyRef(LocalCopyKind.vaultEntry, "v")))
        s1.save(r)
        val back = FileQueueStore(dir).load(r.captureId)!!
        assertEquals(r, back)
        assertNull(s1.load("../../etc/passwd"))
        assertThrows(SpectreException.InvalidCaptureId::class.java) { s1.save(r.copy(captureId = "../x")) }
    }

    @Test fun credentialsRoundTrip() {
        val s = InMemorySecretStore()
        val v = CredentialVault(s)
        assertNull(v.load())
        val c = DeviceCredentials("https://script.google.com/macros/s/x/exec", "d_0123456789abcdef", "ab".repeat(32), 7)
        v.save(c); assertEquals(c, v.load())
        v.clear(); assertNull(v.load())
    }
}

/** In-process transport returning scripted responses (protocol edge cases). */
class ScriptedTransport(responses: List<HttpResponse>) : HttpTransport {
    private val queue = ArrayDeque(responses)
    val sent = mutableListOf<HttpRequest>()
    override fun send(request: HttpRequest): HttpResponse { sent.add(request); return queue.removeFirst() }
}

class ResumableUploaderTest {
    private val session = "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=abc"

    @Test fun resumesFromServerOffsetNotLocalBelief() {
        val t = ScriptedTransport(listOf(
            HttpResponse(308, mapOf("range" to "bytes=0-262143"), ByteArray(0)),
            HttpResponse(200, emptyMap(), """{"id":"1Abc"}""".toByteArray())))
        val data = syntheticBytes(300_000)
        val id = ResumableUploader(t, 256 * 1024).upload(session, data.size.toLong(),
            { o, l -> data.copyOfRange(o.toInt(), o.toInt() + l) }, {})
        assertEquals("1Abc", id)
        assertEquals("bytes 262144-299999/300000", t.sent[1].headers["Content-Range"])
        assertTrue("phone never sends an OAuth token", t.sent.none { it.headers.containsKey("Authorization") })
        assertFalse("308 is never followed as a redirect", t.sent.any { it.followRedirects })
    }

    @Test fun expiredSessionAndLyingServer() {
        val u1 = ResumableUploader(ScriptedTransport(listOf(HttpResponse(404, emptyMap(), ByteArray(0)))), 256 * 1024)
        assertThrows(SpectreException.SessionExpired::class.java) { u1.probe(session, 10) }
        val u2 = ResumableUploader(ScriptedTransport(listOf(HttpResponse(308, mapOf("range" to "bytes=0-99"), ByteArray(0)))), 256 * 1024)
        assertThrows(SpectreException.ProtocolViolation::class.java) { u2.probe(session, 10) }
    }

    @Test fun chunkSizeMustBeDriveGranularity() {
        assertThrows(IllegalArgumentException::class.java) { ResumableUploader(ScriptedTransport(emptyList()), 1000) }
    }
}

class EngineUnitTest {
    @Test fun classificationMessagesAreActionableAndFrench() {
        assertEquals(FailureKind.deviceNotAuthorized, DepositEngine.classify(SpectreException.Backend("DEVICE_REVOKED", "")).first)
        assertEquals(FailureKind.network, DepositEngine.classify(SpectreException.Transport("x")).first)
        assertEquals(FailureKind.serverUnavailable, DepositEngine.classify(SpectreException.Http(503)).first)
        assertEquals(FailureKind.rateLimited, DepositEngine.classify(SpectreException.Http(429)).first)
        assertEquals(FailureKind.integrityMismatch, DepositEngine.classify(SpectreException.Backend("MISMATCH", "")).first)
    }

    @Test fun retryPolicyIsBoundedExponential() {
        val p = RetryPolicy(baseDelayMs = 5000, maxDelayMs = 60_000)
        assertEquals(5000, p.delayForAttempt(1)); assertEquals(10_000, p.delayForAttempt(2)); assertEquals(60_000, p.delayForAttempt(10))
    }

    @Test fun notEnrolledHaltsWithoutNetworkAndKeepsEverything() {
        val p = Phone(backend = object : DepositBackend {
            override fun enroll(endpoint: String, inviteCode: String) = error("no")
            override fun initUpload(req: InitUploadRequest, credentials: DeviceCredentials) = error("must not be called")
            override fun finalize(uploadId: String, captureId: String, driveFileId: String?, credentials: DeviceCredentials) = error("no")
        })
        val id = p.capture(syntheticBytes(10_000))
        val r = p.run(id)
        assertEquals(FailureKind.notEnrolled, r.failure?.kind)
        assertNull(r.failure?.nextAttemptAt)
        assertTrue(p.outbox.exists(id) && p.vault.has(id))
    }
}
