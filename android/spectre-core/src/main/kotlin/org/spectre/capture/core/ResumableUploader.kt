// SPECTRE Capture — spectre-core
// Google Drive resumable-upload protocol (client side, bytes only).
// https://developers.google.com/workspace/drive/api/guides/manage-uploads#resumable
// The session URI is created by the backend; the phone never holds an OAuth token.
package org.spectre.capture.core

import com.google.gson.JsonParser

sealed class UploadProbe {
    data class Incomplete(val nextOffset: Long) : UploadProbe()
    data class Complete(val driveFileId: String?) : UploadProbe()
}

class ResumableUploader(private val transport: HttpTransport, val chunkSize: Int = 8 * 1024 * 1024) {
    companion object { const val GRANULARITY = 256 * 1024 }

    init { require(chunkSize % GRANULARITY == 0) { "Drive requires chunks that are multiples of 256 KiB" } }

    /** Asks Drive how many bytes it has durably received. */
    fun probe(session: String, total: Long): UploadProbe =
        interpret(transport.send(HttpRequest("PUT", session, mapOf("Content-Range" to "bytes */$total"), null)), total)

    internal fun interpret(r: HttpResponse, total: Long): UploadProbe = when (r.status) {
        200, 201 -> {
            val id = runCatching { JsonParser.parseString(r.text).asJsonObject.get("id")?.asString }.getOrNull()
            UploadProbe.Complete(id)
        }
        308 -> {
            val range = r.header("range")
            if (range == null) UploadProbe.Incomplete(0)
            else {
                // "bytes=0-12345"
                val last = range.substringAfterLast('-', "").toLongOrNull()
                    ?: throw SpectreException.ProtocolViolation("bad Range header")
                val next = last + 1
                if (next > total) throw SpectreException.ProtocolViolation("server claims more bytes than declared")
                UploadProbe.Incomplete(next)
            }
        }
        404, 410 -> throw SpectreException.SessionExpired()
        else -> throw SpectreException.Http(r.status)
    }

    /**
     * Uploads remaining bytes. Always starts by probing the server so that a
     * locally recorded offset is never trusted blindly. Returns the Drive file id
     * reported by the final response (informational — deletion still requires a
     * verified receipt from the backend).
     */
    fun upload(session: String, total: Long, read: (offset: Long, length: Int) -> ByteArray, progress: (Long) -> Unit): String? {
        if (total <= 0) throw SpectreException.ProtocolViolation("empty file")
        var state = probe(session, total)
        while (true) {
            when (val s = state) {
                is UploadProbe.Complete -> { progress(total); return s.driveFileId }
                is UploadProbe.Incomplete -> {
                    val offset = s.nextOffset
                    progress(offset)
                    if (offset == total) {
                        // All bytes acknowledged but no final response: probe again.
                        state = probe(session, total)
                        val again = state
                        if (again is UploadProbe.Incomplete && again.nextOffset == total) {
                            throw SpectreException.ProtocolViolation("server holds all bytes but did not complete")
                        }
                        continue
                    }
                    val len = minOf(chunkSize.toLong(), total - offset).toInt()
                    val chunk = read(offset, len)
                    if (chunk.size != len) throw SpectreException.OutboxRange()
                    val r = transport.send(HttpRequest("PUT", session, mapOf(
                        "Content-Range" to "bytes $offset-${offset + len - 1}/$total",
                        "Content-Type" to "application/octet-stream"), chunk))
                    state = interpret(r, total)
                }
            }
        }
    }
}
