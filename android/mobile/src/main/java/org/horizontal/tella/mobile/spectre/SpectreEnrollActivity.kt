// SPECTRE Capture — enrolment with the owner's one-time invitation: the https link
// received by message (opened from the invitation page), a QR scanned here, a pasted
// link/message, or the clipboard. Always asks for an explicit confirmation and
// requires the unlocked app (BaseLockActivity), so a stray link cannot silently
// redirect this phone's deposits. A link that arrives before the first unlock is
// kept and offered again once the app is unlocked.
package org.horizontal.tella.mobile.spectre

import android.content.ClipboardManager
import android.content.Intent
import android.os.Bundle
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import androidx.appcompat.app.AlertDialog
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import dagger.hilt.android.AndroidEntryPoint
import org.horizontal.tella.mobile.MyApplication
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
            "Ouvrez le lien d'invitation reçu et touchez « Ouvrir dans SPECTRE Capture », ou copiez le message " +
                "puis « Coller l'invitation ». Elle ne sert qu'une fois et expire après 48 h.", 13f, bold = false, color = SpectreUi.WHITE_60), SpectreUi.lp(c, 8))
        root.addView(SpectreUi.button(c, "Coller l'invitation", filled = true) { pasteFromClipboardOrAsk() }, SpectreUi.lp(c, 16))
        root.addView(SpectreUi.button(c, "Scanner le QR d'invitation") {
            scan.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Invitation SPECTRE")
                .setBeepEnabled(false).setOrientationLocked(false))
        }, SpectreUi.lp(c, 8))
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

    /** Links are offered once the app is unlocked (see onResume); kept if the lock screen comes first. */
    private fun handleLink(intent: Intent?) {
        val link = intent?.data?.toString() ?: intent?.getStringExtra(EXTRA_INVITE) ?: return
        SpectreDeposit.setPendingInvite(link)
        intent?.data = null
        intent?.removeExtra(EXTRA_INVITE)
    }

    override fun onResume() {
        super.onResume()
        if (!isLocked && MyApplication.getMainKeyHolder().exists()) {
            SpectreDeposit.takePendingInvite()?.let { confirm(it) }
        }
    }

    private fun pasteFromClipboardOrAsk() {
        val clip = (getSystemService(CLIPBOARD_SERVICE) as? ClipboardManager)?.primaryClip
        val text = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.toString()
        if (SpectreDeposit.findInvite(text) != null) confirm(text!!) else pasteDialog()
    }

    companion object {
        const val EXTRA_INVITE = "spectre.invite"
    }

    private fun pasteDialog() {
        val input = EditText(this).apply { hint = "Collez ici le message d'invitation"; setSingleLine(false) }
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
                    message.postDelayed({ if (!isFinishing) finish() }, 1500)
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
