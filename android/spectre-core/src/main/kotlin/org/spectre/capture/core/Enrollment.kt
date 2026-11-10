// SPECTRE Capture — spectre-core
// Individual enrolment via QR code / invitation link:
//   spectre://enroll?v=1&endpoint=<https URL>&code=<one-time invite code>
//   https://script.google.com/macros/s/<id>/exec?i=<one-time invite code>   (link sent by message;
//       endpoint = the URL without its query; same strict rules as the iOS parser)
// The invite is single-use and short-lived; the resulting device secret is
// stored only in the SecretStore (Android Keystore-wrapped, this device only).
package org.spectre.capture.core

import com.google.gson.Gson
import java.net.URI
import java.net.URLDecoder

data class EnrollmentInvite(val endpoint: String, val code: String)

object EnrollmentParser {
    private val CODE = Regex("^[A-Za-z0-9-]{20,64}$")

    private val EXEC_PATH = Regex("^/macros/s/[A-Za-z0-9_-]+/exec$")
    private val FIND = Regex("(spectre://enroll\\?[^\\s\"'<>]+|https?://[^\\s\"'<>]+/exec\\?i=[A-Za-z0-9-]+)")

    /** First invitation found in a longer text (a message pasted or left in the clipboard), or null. */
    fun find(text: String?, allowInsecureLocalhost: Boolean = false): EnrollmentInvite? {
        if (text.isNullOrBlank() || text.length > 4000) return null
        return FIND.findAll(text).firstNotNullOfOrNull { runCatching { parse(it.value, allowInsecureLocalhost) }.getOrNull() }
    }

    fun parse(text: String, allowInsecureLocalhost: Boolean = false): EnrollmentInvite {
        val uri = try { URI(text.trim()) } catch (e: Exception) { throw SpectreException.InvalidEnrollmentPayload("format") }
        if (uri.scheme == "https" || (allowInsecureLocalhost && uri.scheme == "http")) return parseHttps(uri, allowInsecureLocalhost)
        if (uri.scheme != "spectre" || uri.host != "enroll") throw SpectreException.InvalidEnrollmentPayload("format")
        val items = LinkedHashMap<String, String>()
        for (part in (uri.rawQuery ?: "").split("&")) {
            if (part.isEmpty()) continue
            val k = URLDecoder.decode(part.substringBefore('='), "UTF-8")
            val v = URLDecoder.decode(part.substringAfter('=', ""), "UTF-8")
            items.putIfAbsent(k, v)
        }
        if (items["v"] != "1") throw SpectreException.InvalidEnrollmentPayload("version")
        val e = items["endpoint"] ?: throw SpectreException.InvalidEnrollmentPayload("endpoint")
        val url = try { URI(e) } catch (ex: Exception) { throw SpectreException.InvalidEnrollmentPayload("endpoint") }
        val host = url.host ?: throw SpectreException.InvalidEnrollmentPayload("endpoint")
        val isLocal = host == "127.0.0.1" || host == "localhost"
        if (url.scheme != "https" && !(allowInsecureLocalhost && isLocal && url.scheme == "http")) {
            throw SpectreException.InvalidEnrollmentPayload("endpoint must be https")
        }
        if (!allowInsecureLocalhost && !(host == "script.google.com" || host.endsWith(".run.app"))) {
            // Production endpoints: Apps Script web app, or the documented Cloud Run fallback.
            throw SpectreException.InvalidEnrollmentPayload("unexpected endpoint host")
        }
        val code = items["code"]
        if (code == null || !CODE.matches(code)) throw SpectreException.InvalidEnrollmentPayload("code")
        return EnrollmentInvite(e, code)
    }

    private fun parseHttps(uri: URI, allowInsecureLocalhost: Boolean): EnrollmentInvite {
        val host = uri.host ?: throw SpectreException.InvalidEnrollmentPayload("format")
        val isLocal = host == "127.0.0.1" || host == "localhost"
        if (uri.scheme != "https" && !(allowInsecureLocalhost && isLocal)) throw SpectreException.InvalidEnrollmentPayload("endpoint must be https")
        if (!(host == "script.google.com" || (allowInsecureLocalhost && isLocal))) throw SpectreException.InvalidEnrollmentPayload("unexpected endpoint host")
        if (uri.rawUserInfo != null || uri.rawFragment != null || (uri.port != -1 && !isLocal)) throw SpectreException.InvalidEnrollmentPayload("format")
        if (!EXEC_PATH.matches(uri.rawPath ?: "")) throw SpectreException.InvalidEnrollmentPayload("format")
        val parts = (uri.rawQuery ?: "").split("&")
        if (parts.size != 1 || !parts[0].startsWith("i=")) throw SpectreException.InvalidEnrollmentPayload("format")
        val code = parts[0].removePrefix("i=")
        if (!CODE.matches(code)) throw SpectreException.InvalidEnrollmentPayload("code")
        val endpoint = uri.scheme + "://" + uri.rawAuthority + uri.rawPath
        return EnrollmentInvite(endpoint, code)
    }
}

class CredentialVault(private val secrets: SecretStore) {
    private val gson = Gson()

    fun load(): DeviceCredentials? {
        val d = secrets.get(SecretKeys.deviceCredentials) ?: return null
        return runCatching { gson.fromJson(String(d, Charsets.UTF_8), DeviceCredentials::class.java) }.getOrNull()
            ?.takeIf { it.deviceId.isNotEmpty() && it.secretHex.isNotEmpty() }
    }

    fun save(c: DeviceCredentials) = secrets.set(SecretKeys.deviceCredentials, gson.toJson(c).toByteArray(Charsets.UTF_8))

    fun clear() = secrets.delete(SecretKeys.deviceCredentials)

    fun enroll(invite: EnrollmentInvite, backend: DepositBackend): DeviceCredentials {
        val c = backend.enroll(invite.endpoint, invite.code)
        save(c)
        return c
    }
}
