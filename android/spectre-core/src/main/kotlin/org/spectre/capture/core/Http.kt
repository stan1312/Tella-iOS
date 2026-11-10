// SPECTRE Capture — spectre-core
// Minimal HTTP abstraction. The default transport uses HttpURLConnection
// (Android and JVM) with automatic redirects DISABLED: Drive answers 308
// "Resume Incomplete" which must never be followed, while Apps Script answers
// POST /exec with 302 to script.googleusercontent.com, which is followed here
// explicitly (as GET) for backend calls only.
package org.spectre.capture.core

import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

data class HttpRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    val body: ByteArray? = null,
    /** Follow 301/302/303 as GET (Apps Script echo). Never 307/308. */
    val followRedirects: Boolean = false
)

data class HttpResponse(val status: Int, val headers: Map<String, String>, val body: ByteArray) {
    fun header(name: String): String? = headers[name.lowercase()]
    val text: String get() = String(body, Charsets.UTF_8)
}

fun interface HttpTransport {
    /** Throws SpectreException.Transport on network failure. */
    fun send(request: HttpRequest): HttpResponse
}

class UrlConnectionTransport(
    private val connectTimeoutMs: Int = 30_000,
    private val readTimeoutMs: Int = 120_000,
    private val maxRedirects: Int = 5
) : HttpTransport {

    override fun send(request: HttpRequest): HttpResponse {
        var current = request
        var hops = 0
        while (true) {
            val r = sendOnce(current)
            val loc = r.header("location")
            if (request.followRedirects && r.status in setOf(301, 302, 303) && loc != null && hops < maxRedirects) {
                hops++
                current = HttpRequest("GET", URI(current.url).resolve(loc).toString(), emptyMap(), null, true)
                continue
            }
            return r
        }
    }

    private fun sendOnce(req: HttpRequest): HttpResponse {
        val conn: HttpURLConnection
        try {
            conn = URL(req.url).openConnection() as HttpURLConnection
        } catch (e: IOException) {
            throw SpectreException.Transport("open")
        }
        try {
            conn.instanceFollowRedirects = false
            conn.connectTimeout = connectTimeoutMs
            conn.readTimeout = readTimeoutMs
            conn.useCaches = false
            conn.requestMethod = req.method
            for ((k, v) in req.headers) conn.setRequestProperty(k, v)
            val body = req.body
            if (body != null || req.method == "PUT" || req.method == "POST") {
                val bytes = body ?: ByteArray(0)
                conn.doOutput = true
                conn.setFixedLengthStreamingMode(bytes.size)
                conn.outputStream.use { it.write(bytes) }
            }
            val status = conn.responseCode
            val headers = HashMap<String, String>()
            for ((k, v) in conn.headerFields) if (k != null && v != null && v.isNotEmpty()) headers[k.lowercase()] = v.joinToString(",")
            val stream: InputStream? = try {
                if (status >= 400) conn.errorStream else conn.inputStream
            } catch (e: IOException) {
                conn.errorStream
            }
            val data = stream?.use { it.readBytes() } ?: ByteArray(0)
            return HttpResponse(status, headers, data)
        } catch (e: IOException) {
            throw SpectreException.Transport(e.javaClass.simpleName)
        } finally {
            conn.disconnect()
        }
    }
}
