package com.nettotech.direct

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** `deleteIntent` da bolha. Não exportado. */
class BubbleDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.data?.lastPathSegment ?: return
        Bubbles.dismiss(context.applicationContext, id)
    }
}
