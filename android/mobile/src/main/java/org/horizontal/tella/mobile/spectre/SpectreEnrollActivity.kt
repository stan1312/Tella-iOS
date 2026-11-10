// SPECTRE Capture — enrolment with the one-time invitation shown IN PERSON by
// the owner (QR). Accepts the QR scanned here, a pasted link, or a
// spectre://enroll link opened from the system camera. Always asks for an
// explicit confirmation and requires the unlocked app (BaseLockActivity), so a
// stray link cannot silently redirect this phone's deposits.
package org.horizontal.tella.mobile.spectre

import android.content.Intent
import android.os.Bundle
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import androidx.appcompat.app.AlertDialog
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import dagger.hilt.android.AndroidEntryPoint
import org.horizontal.tella.mobile.views.base_ui.BaseLockActivity
import java.net.URI

@AndroidEntryPoint
class SpectreEnrollActivity : BaseLockActivity() {

    private lateinit var message: android.widget.TextView
    private var busy = false

    private val scan = registerForActivityResult(ScanContract()) { result ->
        val text = result?.contents
        if (!text.isNullOrBlank()) confirm(text)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        SpectreDeposit.engineOrInit(this)
        val c = this
        val root = SpectreUi.column(c).apply { setBackgroundColor(SpectreUi.BLACK) }
        root.addView(SpectreUi.label(c, "CONFIGURER CET APPAREIL", 16f))
        root.addView(SpectreUi.label(c,
            "Scannez l'invitation que le responsable vous montre en personne. Elle ne sert qu'une fois et expire après 48 h. " +
                "Ne la recevez jamais par messagerie.", 13f, bold = false, color = SpectreUi.WHITE_60), SpectreUi.lp(c, 8))
        root.addView(SpectreUi.button(c, "Scanner le QR d'invitation", filled = true) {
            scan.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Invitation SPECTRE")
                .setBeepEnabled(false).setOrientationLocked(false))
        }, SpectreUi.lp(c, 16))
        root.addView(SpectreUi.button(c, "Coller un lien d'invitation") { pasteDialog() }, SpectreUi.lp(c, 8))
        message = SpectreUi.label(c, "", 13f, bold = false)
        root.addView(message, SpectreUi.lp(c, 16))
        root.addView(SpectreUi.button(c, "Fermer") { finish() }, SpectreUi.lp(c, 24))
        setContentView(ScrollView(c).apply { setBackgroundColor(SpectreUi.BLACK); isFillViewport = true; addView(root) })
        handleLink(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleLink(intent)
    }

    private fun handleLink(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme == "spectre") confirm(data.toString())
    }

    private fun pasteDialog() {
        val input = EditText(this).apply { hint = "spectre://enroll?…"; setSingleLine(false) }
        AlertDialog.Builder(this)
            .setTitle("Lien d'invitation")
            .setView(LinearLayout(this).apply { setPadding(48, 16, 48, 0); addView(input) })
            .setPositiveButton("Continuer") { _, _ -> confirm(input.text.toString()) }
            .setNegativeButton("Annuler", null)
            .show()
    }

    private fun confirm(payload: String) {
        if (busy) return
        val invite = try { SpectreDeposit.parseInvite(payload) } catch (e: Exception) {
            show("Ce n'est pas une invitation SPECTRE valide.", error = true); return
        }
        val host = runCatching { URI(invite.endpoint).host }.getOrNull() ?: "?"
        val replace = if (SpectreDeposit.isEnrolled())
            "\n\nCet appareil est déjà configuré : la nouvelle invitation remplacera l'ancienne configuration." else ""
        AlertDialog.Builder(this)
            .setTitle("Configurer cet appareil ?")
            .setMessage("Les enregistrements faits avec SPECTRE Capture seront déposés via le service : $host$replace")
            .setPositiveButton("Configurer") { _, _ -> enroll(payload) }
            .setNegativeButton("Annuler", null)
            .show()
    }

    private fun enroll(payload: String) {
        busy = true
        show("Configuration en cours…", error = false)
        SpectreDeposit.enroll(payload) { ok, err ->
            runOnUiThread {
                busy = false
                if (ok) {
                    show("Appareil configuré. Les enregistrements seront déposés automatiquement.", error = false)
                } else {
                    show(err ?: "Invitation refusée.", error = true)
                }
            }
        }
    }

    private fun show(text: String, error: Boolean) {
        message.text = text
        message.setTextColor(if (error) SpectreUi.RED else SpectreUi.WHITE)
    }
}
