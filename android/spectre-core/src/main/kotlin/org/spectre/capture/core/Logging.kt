// SPECTRE Capture — spectre-core
// Minimal technical journal. Only whitelisted, non-sensitive fields; URLs,
// secrets, file names and locations are never logged.
package org.spectre.capture.core

fun interface SpectreLogSink { fun record(line: String) }

class MemoryLogSink : SpectreLogSink {
    private val lines = mutableListOf<String>()
    override fun record(line: String) { synchronized(lines) { lines.add(line) } }
    val all: List<String> get() = synchronized(lines) { lines.toList() }
}

class SpectreLog(private val sink: SpectreLogSink?) {
    fun event(name: String, fields: Map<String, String> = emptyMap()) {
        val s = sink ?: return
        val safe = fields.filterKeys { it in allowedFields }
            .map { "${it.key}=${redact(it.value)}" }.sorted().joinToString(" ")
        s.record("spectre $name $safe")
    }

    companion object {
        val allowedFields = setOf("capture", "stage", "kind", "attempt", "status", "bytes", "copies", "result")

        /** Defence in depth: strip anything that looks like a URL or long hex secret. */
        fun redact(v: String): String {
            if (v.contains("://") || v.contains("upload_id")) return "[redacted-url]"
            if (v.length >= 40 && v.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }) return "[redacted-hex]"
            if (Validation.isUUID(v)) return v.take(8)
            return v.take(64)
        }
    }
}
