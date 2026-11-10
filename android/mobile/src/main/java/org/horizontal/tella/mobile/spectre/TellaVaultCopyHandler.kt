// SPECTRE Capture — deletes the Tella vault entry (encrypted file + DB row +
// thumbnail) once the deposit receipt is verified. Needs the unlocked vault;
// when locked, deletion is retried later and the UI says a local copy remains.
package org.horizontal.tella.mobile.spectre

import org.spectre.capture.core.LocalCopyHandler
import org.spectre.capture.core.LocalCopyKind
import org.spectre.capture.core.LocalCopyRef
import java.io.IOException

class TellaVaultCopyHandler : LocalCopyHandler {
    override val kind = LocalCopyKind.vaultEntry

    override fun delete(ref: LocalCopyRef) {
        val vault = SpectreDeposit.rxVaultOrNull() ?: throw IOException("vault locked")
        val file = vault.get(ref.reference).blockingGet()
        if (vault.delete(file).blockingGet() != true) throw IOException("vault delete refused")
    }

    override fun exists(ref: LocalCopyRef): Boolean {
        // Locked vault: we cannot check, so never claim the copy is gone.
        val vault = SpectreDeposit.rxVaultOrNull() ?: return true
        return try {
            vault.get(ref.reference).blockingGet() != null
        } catch (e: NoSuchElementException) {
            false
        } catch (e: Throwable) {
            // RxJava wraps "not found" differently across versions: inspect the cause chain.
            var c: Throwable? = e
            while (c != null) {
                if (c is NoSuchElementException) return false
                c = c.cause
            }
            !(e.message ?: "").contains("not found", ignoreCase = true) && e !is NullPointerException
        }
    }
}
