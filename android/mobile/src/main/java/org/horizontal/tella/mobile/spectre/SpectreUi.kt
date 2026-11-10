// SPECTRE Capture — small black & white UI kit (programmatic views, French labels).
package org.horizontal.tella.mobile.spectre

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import org.spectre.capture.core.CaptureRecord
import org.spectre.capture.core.CaptureStage
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

internal object SpectreUi {
    const val WHITE = Color.WHITE
    const val BLACK = Color.BLACK
    val WHITE_60 = Color.argb(0x99, 0xff, 0xff, 0xff)
    val RED = Color.rgb(0xff, 0x3b, 0x30)

    fun dp(c: Context, v: Int): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), c.resources.displayMetrics).toInt()

    fun outline(c: Context, fill: Int = BLACK, stroke: Int = WHITE): GradientDrawable = GradientDrawable().apply {
        setColor(fill); setStroke(dp(c, 1), stroke); cornerRadius = 0f
    }

    fun label(c: Context, text: String, sizeSp: Float = 13f, bold: Boolean = true, color: Int = WHITE, mono: Boolean = false) =
        TextView(c).apply {
            this.text = text
            setTextColor(color)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
            typeface = when {
                mono -> Typeface.MONOSPACE
                bold -> Typeface.DEFAULT_BOLD
                else -> Typeface.DEFAULT
            }
            letterSpacing = if (bold && !mono) 0.08f else 0f
        }

    fun button(c: Context, text: String, filled: Boolean = false, onClick: () -> Unit) = Button(c).apply {
        this.text = text
        isAllCaps = true
        letterSpacing = 0.08f
        setTextColor(if (filled) BLACK else WHITE)
        background = outline(c, if (filled) WHITE else BLACK)
        setPadding(dp(c, 16), dp(c, 12), dp(c, 16), dp(c, 12))
        setOnClickListener { onClick() }
    }

    fun column(c: Context, padDp: Int = 16) = LinearLayout(c).apply {
        orientation = LinearLayout.VERTICAL
        val p = dp(c, padDp)
        setPadding(p, p, p, p)
    }

    fun spacer(c: Context, hDp: Int) = View(c).apply { layoutParams = LinearLayout.LayoutParams(1, dp(c, hDp)) }

    fun lp(c: Context, topDp: Int = 0) = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
    ).apply { topMargin = dp(c, topDp) }

    fun kindLabel(r: CaptureRecord) = if (r.isAudio) "AUDIO" else "VIDÉO"

    fun date(r: CaptureRecord): String = SimpleDateFormat("dd.MM.yyyy HH:mm", Locale.FRANCE).format(Date(r.createdAt))

    fun isProblem(r: CaptureRecord) = r.stage == CaptureStage.blocked || (r.failure != null && r.failure?.nextAttemptAt == null)

    fun gravityCenter(v: TextView) = v.apply { gravity = Gravity.CENTER }
}
