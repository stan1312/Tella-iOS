// SPECTRE Capture — home screen: deposit card + the two capture buttons
// (camera, dictaphone) whose recordings go to the deposit. Same layout as iOS.
package org.horizontal.tella.mobile.spectre

import android.content.Intent
import android.view.Gravity
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.fragment.app.Fragment
import com.google.android.material.bottomnavigation.BottomNavigationView
import org.horizontal.tella.mobile.R
import org.horizontal.tella.mobile.spectre.SpectreUi.dp

object SpectreHomeView {

    /** Fills [container] (inside the home app bar) when the SPECTRE flavor is active. */
    @JvmStatic
    fun attach(fragment: Fragment, container: FrameLayout?) {
        if (!SpectreDeposit.enabled || container == null) return
        val c = fragment.requireContext()
        container.removeAllViews()
        container.visibility = android.view.View.VISIBLE

        val root = SpectreUi.column(c, 0).apply { setPadding(dp(c, 16), dp(c, 8), dp(c, 16), dp(c, 12)) }

        // Deposit card
        val card = LinearLayout(c).apply {
            orientation = LinearLayout.VERTICAL
            background = SpectreUi.outline(c)
            setPadding(dp(c, 16), dp(c, 12), dp(c, 16), dp(c, 12))
            contentDescription = "Dépôt SPECTRE"
            setOnClickListener { c.startActivity(Intent(c, SpectreStatusActivity::class.java)) }
        }
        val title = SpectreUi.label(c, "DÉPÔT SPECTRE")
        val summary = SpectreUi.label(c, "", 12f, bold = false, color = SpectreUi.WHITE_60, mono = true)
        card.addView(title); card.addView(summary)
        root.addView(card, SpectreUi.lp(c))

        // Two square tiles
        val row = LinearLayout(c).apply { orientation = LinearLayout.HORIZONTAL }
        row.addView(tile(fragment, "APPAREIL PHOTO", "●", R.id.camera), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { rightMargin = dp(c, 6) })
        row.addView(tile(fragment, "DICTAPHONE", "◉", R.id.mic), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { leftMargin = dp(c, 6) })
        root.addView(row, SpectreUi.lp(c, 12))

        container.addView(root)

        val owner = fragment.viewLifecycleOwner
        fun render() {
            val records = SpectreDeposit.records.value ?: emptyList()
            val enrolled = SpectreDeposit.enrolled.value == true
            val name = SpectreDeposit.depositName.value
            title.text = when {
                !enrolled || name.isNullOrEmpty() -> "DÉPÔT SPECTRE"
                SpectreDeposit.depositIsEvent.value == true -> "DÉPÔT · ${name.uppercase()}"
                else -> "DÉPÔT · DOSSIER PRINCIPAL"
            }
            val pending = records.count { it.stage != org.spectre.capture.core.CaptureStage.completed }
            val problems = records.count { SpectreUi.isProblem(it) }
            summary.text = when {
                !enrolled -> "Appareil non configuré : scannez votre invitation"
                problems > 0 -> "$problems enregistrement(s) à vérifier — encore sur ce téléphone"
                pending > 0 -> "$pending enregistrement(s) en attente ou en cours d'envoi"
                else -> "Aucun enregistrement en attente"
            }
            summary.setTextColor(if (problems > 0) SpectreUi.RED else SpectreUi.WHITE_60)
        }
        SpectreDeposit.records.observe(owner) { render() }
        SpectreDeposit.enrolled.observe(owner) { render() }
        SpectreDeposit.depositName.observe(owner) { render() }
        SpectreDeposit.depositIsEvent.observe(owner) { render() }
        SpectreDeposit.refreshDepositStatus()
    }

    private fun tile(fragment: Fragment, title: String, symbol: String, navItem: Int): LinearLayout {
        val c = fragment.requireContext()
        val t = object : LinearLayout(c) {
            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                // square, capped so the home list keeps room on small phones
                val side = minOf(android.view.View.MeasureSpec.getSize(widthMeasureSpec), dp(c, 150))
                super.onMeasure(widthMeasureSpec, android.view.View.MeasureSpec.makeMeasureSpec(side, android.view.View.MeasureSpec.EXACTLY))
            }
        }
        t.orientation = LinearLayout.VERTICAL
        t.background = SpectreUi.outline(c)
        t.setPadding(dp(c, 16), dp(c, 16), dp(c, 16), dp(c, 16))
        t.contentDescription = title
        t.isClickable = true
        val icon = SpectreUi.label(c, symbol, 30f, bold = false)
        val spacer = android.view.View(c)
        val name = SpectreUi.label(c, title, 13f)
        val sub = SpectreUi.label(c, "→ dépôt", 11f, bold = false, color = SpectreUi.WHITE_60, mono = true)
        t.addView(icon)
        t.addView(spacer, LinearLayout.LayoutParams(1, 0, 1f))
        t.addView(name)
        t.addView(sub)
        t.gravity = Gravity.START
        t.setOnClickListener {
            fragment.activity?.findViewById<BottomNavigationView>(R.id.btm_nav_main)?.selectedItemId = navItem
        }
        return t
    }
}
