package org.spectre.capture.core

import java.io.File
import java.util.concurrent.TimeUnit

object Ffmpeg {
    private fun exe(name: String): String? =
        listOf("/usr/bin", "/opt/homebrew/bin", "/usr/local/bin").map { File(it, name) }.firstOrNull { it.canExecute() }?.path

    private fun run(vararg args: String): Pair<Int, String> {
        val p = ProcessBuilder(*args).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        p.waitFor(120, TimeUnit.SECONDS)
        return p.exitValue() to out
    }

    fun probe(f: File): String? {
        val e = exe("ffprobe") ?: return null
        return run(e, "-v", "error", "-show_entries", "format=duration,size:format_tags:stream=codec_name,width,height,r_frame_rate",
            "-of", "compact", f.path).second
    }

    fun probeAudio(f: File): String? {
        val e = exe("ffprobe") ?: return null
        return run(e, "-v", "error", "-show_entries", "format=format_name:stream=codec_name,sample_rate,channels,duration_ts",
            "-of", "compact", f.path).second
    }

    /** Synthetic AAC-LC in ADTS framing (like Tella's AudioRecorder), 44.1 kHz mono, 32 kb/s. */
    fun makeAdts(dir: File, seconds: Int, rate: Int = 44100, channels: Int = 1): File? {
        val e = exe("ffmpeg") ?: return null
        val out = File(dir, "rec.aac")
        val (code, log) = run(e, "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=$rate:duration=$seconds",
            "-ac", "$channels", "-c:a", "aac", "-b:a", "32k", "-f", "adts", out.path)
        check(code == 0) { log }
        return out
    }

    /** MD5 of the decoded PCM (proves the audio is unchanged, without re-encoding artefacts). */
    fun decodedMd5(f: File): String {
        val e = exe("ffmpeg")!!
        val (code, log) = run(e, "-v", "error", "-i", f.path, "-map", "0:a", "-f", "md5", "-")
        check(code == 0) { log }
        return log.trim().lines().last()
    }

    fun decodeErrors(f: File): String {
        val e = exe("ffmpeg")!!
        return run(e, "-v", "error", "-i", f.path, "-f", "null", "-").second.trim()
    }
}
