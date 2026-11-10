// SPECTRE Capture — spectre-core
// Deletes every app-managed local copy of a capture, ONLY with a VerifiedReceipt.
package org.spectre.capture.core

import java.io.File
import java.io.RandomAccessFile

interface LocalCopyHandler {
    val kind: LocalCopyKind
    fun delete(ref: LocalCopyRef)
    fun exists(ref: LocalCopyRef): Boolean
}

data class DeletionReport(val deleted: MutableList<LocalCopyKind> = mutableListOf(),
                          val failed: MutableMap<LocalCopyKind, String> = linkedMapOf()) {
    val allDeleted: Boolean get() = failed.isEmpty()

    companion object {
        /** Honest statement shown in the UI / handover. */
        val limitations = listOf(
            "La suppression retire les fichiers et clés gérés par l'application ; l'effacement physique de la mémoire flash n'est pas garanti.",
            "Le conteneur d'envoi est chiffré avec une clé propre à la captation, détruite en premier (effacement cryptographique).",
            "Les copies créées hors de l'application (capture d'écran, autre app, sauvegarde antérieure) ne sont pas couvertes."
        )
    }
}

class DeletionCoordinator(handlers: List<LocalCopyHandler>) {
    private val handlers: Map<LocalCopyKind, LocalCopyHandler> = handlers.associateBy { it.kind }

    companion object {
        /** Deletion order: plaintext temps first, vault, then the outbox (key first). */
        val order = listOf(LocalCopyKind.plaintextTemp, LocalCopyKind.cameraOriginalTemp, LocalCopyKind.uploadChunkTemp,
            LocalCopyKind.vaultEntry, LocalCopyKind.outboxEncrypted)
    }

    fun deleteLocalCopies(record: CaptureRecord, proof: VerifiedReceipt): DeletionReport {
        val report = DeletionReport()
        if (proof.receipt.captureId != record.captureId) {
            for (c in record.localCopies) report.failed[c.kind] = "reçu non lié à cette captation"
            return report
        }
        val copies = record.localCopies.sortedBy { order.indexOf(it.kind).let { i -> if (i < 0) 99 else i } }
        for (copy in copies) {
            val h = handlers[copy.kind]
            if (h == null) { report.failed[copy.kind] = "aucun gestionnaire de suppression"; continue }
            try {
                if (h.exists(copy)) h.delete(copy)
                if (h.exists(copy)) report.failed[copy.kind] = "copie toujours présente après suppression"
                else report.deleted.add(copy.kind)
            } catch (e: Exception) {
                report.failed[copy.kind] = "échec de suppression"
            }
        }
        return report
    }
}

/** Handler for the SPECTRE encrypted outbox (key destroyed first). */
class OutboxCopyHandler(private val outbox: EncryptedOutbox) : LocalCopyHandler {
    override val kind = LocalCopyKind.outboxEncrypted
    override fun delete(ref: LocalCopyRef) = outbox.destroy(ref.reference)
    override fun exists(ref: LocalCopyRef) = outbox.exists(ref.reference) || outbox.hasKey(ref.reference)
}

/** Handler for plain files (temp copies). Overwrites then removes; the overwrite is best-effort only (flash). */
class FileCopyHandler(override val kind: LocalCopyKind, allowedRoot: File) : LocalCopyHandler {
    private val root: File = allowedRoot.canonicalFile

    internal fun file(ref: LocalCopyRef): File? {
        val f = File(ref.reference).canonicalFile
        return if (f.path.startsWith(root.path + File.separator)) f else null
    }

    override fun delete(ref: LocalCopyRef) {
        val f = file(ref) ?: throw SpectreException.ProtocolViolation("path outside managed root")
        runCatching {
            RandomAccessFile(f, "rw").use { raf ->
                val zero = ByteArray(64 * 1024)
                var remaining = raf.length()
                raf.seek(0)
                while (remaining > 0) { val n = minOf(remaining, zero.size.toLong()).toInt(); raf.write(zero, 0, n); remaining -= n }
                raf.fd.sync()
            }
        }
        if (f.exists() && !f.delete()) throw java.io.IOException("delete failed")
    }

    // unknown location: never claim it is gone
    override fun exists(ref: LocalCopyRef): Boolean = file(ref)?.exists() ?: true
}
