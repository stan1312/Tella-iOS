// SPECTRE Capture — Android SecretStore.
// Values (device credential, per-capture outbox keys, resumable session URLs)
// are sealed with AES-256-GCM under a NON-EXPORTABLE key held by the Android
// Keystore (hardware-backed when the phone has a TEE / StrongBox), bound to
// their name (AAD), and stored in noBackupFilesDir (never backed up, never
// transferred to another device). Available after the first unlock, so that
// deposits continue with the screen locked (same trade-off as iOS
// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; see SECURITY_THREAT_MODEL).
package org.horizontal.tella.mobile.spectre

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.spectre.capture.core.Files
import org.spectre.capture.core.SecretStore
import org.spectre.capture.core.SpectreCrypto
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class SpectreKeystoreSecretStore(context: Context) : SecretStore {
    private val dir = File(context.noBackupFilesDir, "spectre/secrets").apply { mkdirs() }
    private val lock = Any()

    companion object {
        private const val ALIAS = "spectre.secretstore.v1"
        private const val IV_LEN = 12

        /** Removes the wrapping key: every sealed value becomes unreadable (used by quick delete). */
        fun destroyKey() {
            runCatching { KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(ALIAS) }
        }
    }

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return gen.generateKey()
    }

    private fun file(name: String) = File(dir, SpectreCrypto.sha256Hex(name))

    override fun set(key: String, data: ByteArray) = synchronized(lock) {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        c.updateAAD(key.toByteArray(Charsets.UTF_8))
        val sealed = c.doFinal(data)
        val iv = c.iv
        check(iv.size == IV_LEN)
        Files.atomicWrite(file(key), iv + sealed)
    }

    override fun get(key: String): ByteArray? = synchronized(lock) {
        val f = file(key)
        if (!f.exists()) return null
        val blob = f.readBytes()
        if (blob.size <= IV_LEN) return null
        return try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob, 0, IV_LEN))
            c.updateAAD(key.toByteArray(Charsets.UTF_8))
            c.doFinal(blob, IV_LEN, blob.size - IV_LEN)
        } catch (e: Exception) {
            null   // wrapping key gone (quick delete) or tampered value: treated as absent
        }
    }

    override fun delete(key: String) { synchronized(lock) { file(key).delete() } }

    /** Deletes every sealed value (quick delete). */
    fun deleteAll() = synchronized(lock) { dir.listFiles()?.forEach { it.delete() } }
}
