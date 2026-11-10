// SPECTRE Capture — deposit status: one line per recording still known to the
// queue, honest states (same wording as iOS), "Réessayer" when a human is needed.
package org.horizontal.tella.mobile.spectre

import android.content.Intent
import android.os.Bundle
import android.widget.LinearLayout
import android.widget.ScrollView
import dagger.hilt.android.AndroidEntryPoint
import org.horizontal.tella.mobile.spectre.SpectreUi.dp
import org.horizontal.tella.mobile.views.base_ui.BaseLockActivity
import org.spectre.capture.core.CaptureRecord
import org.spectre.capture.core.CaptureStage
import org.spectre.capture.core.DeletionReport

@AndroidEntryPoint
class SpectreStatusActivity : BaseLockActivity() {

    private lateinit var list: LinearLayout
    private lateinit var header: android.widget.TextView
    private lateinit var enrollButton: android.widget.Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        SpectreDeposit.engineOrInit(this)
        val c = this
        val root = SpectreUi.column(c).apply { setBackgroundColor(SpectreUi.BLACK) }
        val top = LinearLayout(c).apply { orientation = LinearLayout.HORIZONTAL }
        top.addView(SpectreUi.label(c, "DÉPÔT SPECTRE", 16f), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        top.addView(SpectreUi.button(c, "Fermer") { finish() })
        root.addView(top)
        header = SpectreUi.label(c, "", 12f, bold = false, color = SpectreUi.WHITE_60, mono = true)
        root.addView(header, SpectreUi.lp(c, 8))
        enrollButton = SpectreUi.button(c, "Configurer cet appareil (invitation)") {
            startActivity(Intent(c, SpectreEnrollActivity::class.java))
        }
        root.addView(enrollButton, SpectreUi.lp(c, 12))
        root.addView(SpectreUi.button(c, "Envoyer maintenant") { SpectreDeposit.kick() }, SpectreUi.lp(c, 8))
        list = LinearLayout(c).apply { orientation = LinearLayout.VERTICAL }
        root.addView(list, SpectreUi.lp(c, 16))
        val note = SpectreUi.label(c, DeletionReport.limitations.joinToString("\n\n") { "· $it" }, 11f, bold = false, color = SpectreUi.WHITE_60)
        root.addView(note, SpectreUi.lp(c, 24))
        setContentView(ScrollView(c).apply { setBackgroundColor(SpectreUi.BLACK); isFillViewport = true; addView(root) })

        SpectreDeposit.records.observe(this) { render() }
        SpectreDeposit.enrolled.observe(this) { render() }
        SpectreDeposit.depositName.observe(this) { render() }
    }

    override fun onResume() {
        super.onResume()
        SpectreDeposit.refreshDepositStatus()
        SpectreDeposit.onVaultUnlocked()
    }

    private fun render() {
        val enrolled = SpectreDeposit.enrolled.value == true
        val name = SpectreDeposit.depositName.value
        header.text = when {
            !enrolled -> "Cet appareil n'est pas configuré. Ouvrez le lien d'invitation reçu du responsable."
            name.isNullOrEmpty() -> "Appareil configuré."
            else -> "Appareil configuré. Dossier de dépôt : $name"
        }
        enrollButton.text = if (enrolled) "Remplacer la configuration (nouvelle invitation)" else "Configurer cet appareil (invitation)"
        list.removeAllViews()
        val records = SpectreDeposit.records.value ?: emptyList()
        if (records.isEmpty()) {
            list.addView(SpectreUi.label(this, "Aucun enregistrement dans la file.", 12f, bold = false, color = SpectreUi.WHITE_60))
            return
        }
        for (r in records) list.addView(row(r), SpectreUi.lp(this, 8))
    }

    private fun row(r: CaptureRecord): LinearLayout {
        val c = this
        val box = LinearLayout(c).apply {
            orientation = LinearLayout.VERTICAL
            background = SpectreUi.outline(c, stroke = if (SpectreUi.isProblem(r)) SpectreUi.RED else SpectreUi.WHITE)
            setPadding(dp(c, 12), dp(c, 10), dp(c, 12), dp(c, 10))
        }
        box.addView(SpectreUi.label(c, "${SpectreUi.kindLabel(r)} · ${SpectreUi.date(r)}", 12f))
        val status = r.userFacingStatus.labelFR
        box.addView(SpectreUi.label(c, status, 12f, bold = false,
            color = if (SpectreUi.isProblem(r)) SpectreUi.RED else SpectreUi.WHITE_60), SpectreUi.lp(c, 4))
        val needsHuman = r.stage == CaptureStage.blocked || (r.failure != null && r.failure?.nextAttemptAt == null)
        if (needsHuman) {
            val label = if (r.stage == CaptureStage.blocked) "Renvoyer une nouvelle copie" else "Réessayer"
            box.addView(SpectreUi.button(c, label) { SpectreDeposit.retry(r.captureId) }, SpectreUi.lp(c, 8))
        }
        return box
    }
}
