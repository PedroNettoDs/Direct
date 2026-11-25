package com.nettotech.direct

import android.app.Activity
import android.os.Build
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import io.flutter.embedding.android.FlutterView

/**
 * Proteções de tela do PLANO §8. Chame em toda Activity do app (a do chat
 * flutuante da F7 também): `onCreate` aplica a janela, `onPostResume` aplica
 * a FlutterView, que só existe depois do primeiro layout.
 */
object SecureWindow {
    /** Print e gravação saem pretos; miniatura do seletor de apps também. */
    fun applyWindow(activity: Activity) {
        activity.window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
        // Esconde sobreposições de outros apps (API 31+, permissão HIDE_OVERLAY_WINDOWS).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            activity.window.setHideOverlayWindows(true)
        }
    }

    /**
     * Ignora toques quando outra janela cobre a FlutterView (tapjacking) e, no
     * Android 14+, esconde o conteúdo de serviços de acessibilidade que não se
     * declaram ferramenta de acessibilidade (o TalkBack se declara).
     */
    fun applyViews(activity: Activity) {
        val view = find(activity.window.decorView) ?: return
        view.filterTouchesWhenObscured = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            view.setAccessibilityDataSensitive(View.ACCESSIBILITY_DATA_SENSITIVE_YES)
        }
    }

    private fun find(v: View): FlutterView? {
        if (v is FlutterView) return v
        if (v is ViewGroup) {
            for (i in 0 until v.childCount) find(v.getChildAt(i))?.let { return it }
        }
        return null
    }
}
