// SPECTRE Capture — dictaphone recordings: ADTS (Tella) → m4a without re-encoding.
package org.spectre.capture.core

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import org.junit.Assert.*
import org.junit.Assume
import org.junit.Test

class AdtsToM4aTest {
    private fun convert(adts: ByteArray): ByteArray {
        val plan = AdtsToM4a.scan(adts.inputStream())
        val out = ByteArrayOutputStream()
        AdtsToM4a.M4aInputStream(adts.inputStream(), plan).use { it.copyTo(out, 1000) }
        val bytes = out.toByteArray()
        assertEquals("announced size is exact (needed by the outbox)", plan.outputSize, bytes.size.toLong())
        return bytes
    }

    @Test fun ffmpegReadsTheResultAsAacInMp4AndDecodesToIdenticalAudio() {
        for ((rate, ch) in listOf(44100 to 1, 48000 to 2, 16000 to 1)) {
            val dir = tempDir("adts")
            val adts = Ffmpeg.makeAdts(dir, seconds = 5, rate = rate, channels = ch)
            Assume.assumeTrue("ffmpeg not available", adts != null)
            val m4a = File(dir, "rec.m4a").apply { writeBytes(convert(adts!!.readBytes())) }
            val probe = Ffmpeg.probeAudio(m4a)!!
            assertTrue(probe, probe.contains("codec_name=aac"))
            assertTrue(probe, probe.contains("sample_rate=$rate"))
            assertTrue(probe, probe.contains("channels=$ch"))
            assertTrue(probe, probe.contains("mov,mp4,m4a"))
            assertEquals("no decoding error", "", Ffmpeg.decodeErrors(m4a))
            assertEquals("same decoded PCM as the original recording ($rate Hz, $ch ch)", Ffmpeg.decodedMd5(adts!!), Ffmpeg.decodedMd5(m4a))
        }
    }

    @Test fun everyAacFrameIsCopiedByteForByte() {
        val adts = Ffmpeg.makeAdts(tempDir("adts"), seconds = 2) ?: return Assume.assumeTrue(false)
        val src = adts.readBytes()
        val m4a = convert(src)
        // concatenation of ADTS payloads == content of mdat
        val payloads = ByteArrayOutputStream()
        var i = 0
        while (i < src.size) {
            val len = ((src[i + 3].toInt() and 3) shl 11) or ((src[i + 4].toInt() and 0xff) shl 3) or ((src[i + 5].toInt() and 0xff) ushr 5)
            val hl = if ((src[i + 1].toInt() and 1) == 1) 7 else 9
            payloads.write(src, i + hl, len - hl); i += len
        }
        val p = payloads.toByteArray()
        val mdat = String(m4a, Charsets.ISO_8859_1).indexOf("mdat") + 4
        assertArrayEquals(p, m4a.copyOfRange(mdat, mdat + p.size))
    }

    @Test fun garbageAndTruncationAreRejected() {
        assertThrows(IOException::class.java) { AdtsToM4a.scan(syntheticBytes(5000).inputStream()) }
        assertThrows(IOException::class.java) { AdtsToM4a.scan(ByteArray(0).inputStream()) }
        val adts = Ffmpeg.makeAdts(tempDir("adts"), seconds = 1) ?: return
        val src = adts.readBytes()
        assertThrows(IOException::class.java) { AdtsToM4a.scan(src.copyOf(src.size - 3).inputStream()) }
        // source changed between the two passes
        val plan = AdtsToM4a.scan(src.inputStream())
        val other = Ffmpeg.makeAdts(tempDir("adts"), seconds = 2)!!.readBytes()
        assertThrows(IOException::class.java) { AdtsToM4a.M4aInputStream(other.inputStream(), plan).readBytes() }
    }
}
