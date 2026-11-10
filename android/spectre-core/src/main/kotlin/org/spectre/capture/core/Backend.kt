// SPECTRE Capture — spectre-core
// Client of the deposit-only backend (Google Apps Script web app, unchanged
// from the iOS project). The API intentionally offers NO list / read /
// download / delete operation.
package org.spectre.capture.core

import com.google.gson.Gson
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser

data class DeviceCredentials(
    val endpoint: String,
    val deviceId: String,
    val secretHex: String,
    val enrolledAt: Long
) {
    val keyData: ByteArray get() = secretHex.toByteArray(Charsets.UTF_8)
}

sealed class InitUploadResult {
    data class Session(val uploadId: String, val sessionUrl: String) : InitUploadResult()
    data class AlreadyVerified(val receipt: DepositReceipt) : InitUploadResult()
    /** The previous session already produced a Drive file: go verify it. */
    data class FinalizeExisting(val uploadId: String) : InitUploadResult()
}

sealed class FinalizeResult {
    data class Verified(val receipt: DepositReceipt) : FinalizeResult()
    data class Pending(val retryAfterSec: Double) : FinalizeResult()
    object Incomplete : FinalizeResult()
    data class Mismatch(val detail: String) : FinalizeResult()
}

data class InitUploadRequest(
    val captureId: String,
    val size: Long,
    val sha256: String,
    val md5: String,
    val mimeType: String,
    val ext: String,
    val renewSession: Boolean,
    val forceNewUpload: Boolean
)

/** Name of the folder currently receiving deposits (e.g. the demonstration of the day). Label only. */
data class DepositStatus(val depositName: String, val isEvent: Boolean)

interface DepositBackend {
    fun enroll(endpoint: String, inviteCode: String): DeviceCredentials
    fun initUpload(req: InitUploadRequest, credentials: DeviceCredentials): InitUploadResult
    fun finalize(uploadId: String, captureId: String, driveFileId: String?, credentials: DeviceCredentials): FinalizeResult
    fun depositStatus(credentials: DeviceCredentials): DepositStatus =
        throw SpectreException.ProtocolViolation("status not supported")
}

class HttpDepositBackend(
    private val transport: HttpTransport,
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val platform: String = "android",
    private val client: String = "spectre-capture-android/0.1"
) : DepositBackend {

    private val gson = Gson()

    companion object {
        /** MUST match backend `spRequestCanonical_`. */
        fun requestCanonical(action: String, deviceId: String, ts: Long, nonce: String, payload: String): String =
            listOf("spectre-req-v1", action, deviceId, ts.toString(), nonce, SpectreCrypto.sha256Hex(payload)).joinToString("\n")

        fun decodeReceipt(e: JsonElement?): DepositReceipt {
            if (e == null || !e.isJsonObject) throw SpectreException.ProtocolViolation("missing receipt")
            val o = e.asJsonObject
            try {
                return DepositReceipt(
                    v = o.get("v").asInt, status = o.get("status").asString, captureId = o.get("captureId").asString,
                    uploadId = o.get("uploadId").asString, deviceId = o.get("deviceId").asString,
                    driveFileId = o.get("driveFileId").asString, size = o.get("size").asLong,
                    sha256 = o.get("sha256").asString, md5 = o.get("md5").asString,
                    checksumSource = o.get("checksumSource").asString, verifiedAt = o.get("verifiedAt").asString,
                    mac = o.get("mac").asString
                )
            } catch (ex: RuntimeException) {
                throw SpectreException.ProtocolViolation("malformed receipt")
            }
        }
    }

    private fun call(endpoint: String, action: String, payload: Map<String, Any>, credentials: DeviceCredentials?): JsonObject {
        val payloadString = gson.toJson(payload)
        val env = LinkedHashMap<String, Any>()
        env["action"] = action
        if (credentials != null) {
            val ts = clock() / 1000
            val nonce = Hex.encode(SpectreCrypto.randomBytes(16))
            val sig = SpectreCrypto.hmacSha256Hex(credentials.keyData,
                requestCanonical(action, credentials.deviceId, ts, nonce, payloadString))
            env["deviceId"] = credentials.deviceId
            env["ts"] = ts
            env["nonce"] = nonce
            env["payload"] = payloadString
            env["sig"] = sig
        } else {
            env["payload"] = payloadString
        }
        // text/plain avoids a CORS preflight and is what Apps Script expects in e.postData.
        val resp = transport.send(HttpRequest("POST", endpoint, mapOf("Content-Type" to "text/plain;charset=utf-8"),
            gson.toJson(env).toByteArray(Charsets.UTF_8), followRedirects = true))
        if (resp.status !in 200..299) {
            if (resp.status == 429) throw SpectreException.Backend("RATE_LIMITED", "HTTP 429")
            throw SpectreException.Http(resp.status)
        }
        val obj = try { JsonParser.parseString(resp.text).takeIf { it.isJsonObject }?.asJsonObject } catch (e: RuntimeException) { null }
            ?: throw SpectreException.ProtocolViolation("backend returned non-JSON")
        if (obj.get("ok")?.let { it.isJsonPrimitive && it.asBoolean } == true && obj.get("data")?.isJsonObject == true) {
            return obj.getAsJsonObject("data")
        }
        val err = obj.get("error")?.takeIf { it.isJsonObject }?.asJsonObject
        throw SpectreException.Backend(err?.get("code")?.asString ?: "INTERNAL", err?.get("message")?.asString ?: "")
    }

    private fun JsonObject.str(k: String): String? = get(k)?.takeIf { it.isJsonPrimitive }?.asString

    override fun enroll(endpoint: String, inviteCode: String): DeviceCredentials {
        val d = call(endpoint, "enroll", mapOf("inviteCode" to inviteCode, "platform" to platform, "client" to client), null)
        val id = d.str("deviceId")
        val secret = d.str("deviceSecret")
        if (id == null || secret == null || secret.length < 64) throw SpectreException.ProtocolViolation("bad enroll response")
        return DeviceCredentials(endpoint, id, secret, clock())
    }

    override fun initUpload(req: InitUploadRequest, credentials: DeviceCredentials): InitUploadResult {
        val d = call(credentials.endpoint, "initUpload", linkedMapOf(
            "captureId" to req.captureId, "size" to req.size, "sha256" to req.sha256, "md5" to req.md5,
            "mimeType" to req.mimeType, "ext" to req.ext, "renewSession" to req.renewSession,
            "forceNewUpload" to req.forceNewUpload
        ), credentials)
        return when (d.str("state")) {
            "SESSION" -> {
                val uid = d.str("uploadId"); val s = d.str("sessionUrl")
                if (uid == null || s == null) throw SpectreException.ProtocolViolation("bad session response")
                InitUploadResult.Session(uid, s)
            }
            "VERIFIED" -> InitUploadResult.AlreadyVerified(decodeReceipt(d.get("receipt")))
            "FINALIZE" -> InitUploadResult.FinalizeExisting(d.str("uploadId") ?: throw SpectreException.ProtocolViolation("bad finalize hint"))
            else -> throw SpectreException.ProtocolViolation("unknown init state")
        }
    }

    override fun finalize(uploadId: String, captureId: String, driveFileId: String?, credentials: DeviceCredentials): FinalizeResult {
        val p = linkedMapOf<String, Any>("uploadId" to uploadId, "captureId" to captureId)
        if (driveFileId != null) p["driveFileId"] = driveFileId
        val d = call(credentials.endpoint, "finalizeUpload", p, credentials)
        return when (d.str("state")) {
            "VERIFIED" -> FinalizeResult.Verified(decodeReceipt(d.get("receipt")))
            "PENDING" -> FinalizeResult.Pending(d.get("retryAfterSec")?.asDouble ?: 30.0)
            "INCOMPLETE" -> FinalizeResult.Incomplete
            "MISMATCH" -> FinalizeResult.Mismatch(d.str("detail") ?: "")
            else -> throw SpectreException.ProtocolViolation("unknown finalize state")
        }
    }

    override fun depositStatus(credentials: DeviceCredentials): DepositStatus {
        val d = call(credentials.endpoint, "status", emptyMap(), credentials)
        val name = d.str("depositName") ?: throw SpectreException.ProtocolViolation("bad status")
        return DepositStatus(name.take(80), d.get("isEvent")?.asBoolean ?: false)
    }
}
