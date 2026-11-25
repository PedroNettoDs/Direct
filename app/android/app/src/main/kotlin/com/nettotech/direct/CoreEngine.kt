package com.nettotech.direct

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.SystemClock
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * Engine principal, único no processo e mantido no cache: o isolate dele é o
 * dono das chaves, do banco e do WebSocket, e continua vivo sem a
 * `MainActivity` enquanto houver bolha. A bolha usa outro engine, só de tela.
 */
object CoreEngine {
    const val ID = "core"
    var activity = WeakReference<Activity>(null)
    var permissionResult: MethodChannel.Result? = null
    private var channel: MethodChannel? = null

    fun get(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ID)?.let { return it }
        val app = context.applicationContext
        Bubbles.prune(app)
        val engine = FlutterEngine(app)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "direct/bubble").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(Bubbles.status(app))
                    "show" -> try {
                        Bubbles.show(app, call.argument<String>("id")!!, call.argument<String>("title")!!)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("bubble", e.javaClass.simpleName, null)
                    }
                    "active" -> result.success(Bubbles.active(app).toList())
                    "dismissed" -> result.success(Bubbles.dismissed(app).toList())
                    "ackDismissed" -> {
                        Bubbles.ackDismissed(app, call.arguments<List<String>>()!!)
                        result.success(null)
                    }
                    // Conversa escondida (D12): fecha como a D7 e tira notificação e atalho.
                    "close" -> {
                        Bubbles.dismiss(app, call.arguments<String>()!!)
                        result.success(null)
                    }
                    "closeAll" -> {
                        Bubbles.closeAll(app)
                        result.success(null)
                    }
                    "requestNotifications" -> Bubbles.requestNotifications(activity.get(), result)
                    "openSettings" -> {
                        activity.get()?.let { Bubbles.openSettings(it) }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "direct/clock").setMethodCallHandler { call, result ->
            if (call.method == "uptime") result.success(SystemClock.elapsedRealtime()) else result.notImplemented()
        }
        // Aviso do sistema: só chega registrado em código, com o processo vivo.
        app.registerReceiver(
            object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) = Bubbles.lockAll(app)
            },
            IntentFilter(Intent.ACTION_SCREEN_OFF),
        )
        FlutterEngineCache.getInstance().put(ID, engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return engine
    }

    fun screenOff() {
        channel?.invokeMethod("screenOff", null)
    }

    /** Avisa o Dart que o conjunto de bolhas (ou de trancas) mudou. */
    fun changed() {
        channel?.invokeMethod("changed", null)
    }
}
