package com.nettotech.direct

import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity

/**
 * Janela da bolha: engine próprio, só de tela, na entrada `miniChatMain`.
 * FragmentActivity por causa do prompt de digital.
 */
class MiniChatActivity : FlutterFragmentActivity() {
    private val conversationId get() = intent.data?.lastPathSegment ?: ""

    override fun onCreate(savedInstanceState: Bundle?) {
        SecureWindow.applyWindow(this)
        CoreEngine.get(this)
        super.onCreate(savedInstanceState)
        if (conversationId.isEmpty()) finish() else Bubbles.attach(applicationContext, conversationId)
    }

    override fun onPostResume() {
        super.onPostResume()
        SecureWindow.applyViews(this)
    }

    override fun getDartEntrypointFunctionName(): String = "miniChatMain"

    override fun getDartEntrypointArgs(): List<String> = listOf(conversationId)
}
