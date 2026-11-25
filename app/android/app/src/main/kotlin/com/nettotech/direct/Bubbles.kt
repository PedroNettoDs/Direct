package com.nettotech.direct

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel

/**
 * Bolhas (PLANO §9). Só o id da conversa e o nome do contato saem do Dart: nem
 * chave nem conteúdo de mensagem vão para notificação, extra ou disco em claro.
 */
object Bubbles {
    private const val CHANNEL = "conversas"
    private const val TAG = "bolha"
    private const val PREFS = "direct_bubbles"
    private const val ACTIVE = "active"
    private const val DISMISSED = "dismissed"
    const val PERMISSION_REQUEST = 7001

    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun notifications(c: Context) = c.getSystemService(NotificationManager::class.java)
    private fun set(c: Context, key: String): Set<String> = prefs(c).getStringSet(key, emptySet())!!.toSet()
    private fun save(c: Context, key: String, value: Set<String>) {
        prefs(c).edit().putStringSet(key, value).commit()
    }

    fun active(c: Context) = set(c, ACTIVE)
    fun dismissed(c: Context) = set(c, DISMISSED)
    fun ackDismissed(c: Context, ids: List<String>) = save(c, DISMISSED, dismissed(c) - ids.toSet())

    fun uri(id: String): Uri = Uri.parse("direct://bubble/$id")

    /**
     * Processo novo: esquece bolhas cuja notificação já não existe (reinício,
     * "Forçar parada") e pede a tranca das conversas delas.
     */
    fun prune(c: Context) {
        val shown = notifications(c).activeNotifications.filter { it.tag?.startsWith(TAG) == true }
            .map { it.tag.removePrefix(TAG) }.toSet()
        save(c, DISMISSED, dismissed(c) + (active(c) - shown))
        save(c, ACTIVE, active(c) intersect shown)
    }

    fun status(c: Context): Map<String, Boolean> {
        val nm = notifications(c)
        val bubbles = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            nm.areBubblesEnabled() && nm.bubblePreference != NotificationManager.BUBBLE_PREFERENCE_NONE
        } else {
            @Suppress("DEPRECATION")
            nm.areBubblesAllowed()
        }
        return mapOf("notifications" to nm.areNotificationsEnabled(), "bubbles" to bubbles)
    }

    fun requestNotifications(activity: Activity?, result: MethodChannel.Result) {
        if (activity == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(null)
            return
        }
        CoreEngine.permissionResult?.success(null)
        CoreEngine.permissionResult = result
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
    }

    fun openSettings(activity: Activity) {
        val on = notifications(activity).areNotificationsEnabled()
        val action = if (on) {
            Settings.ACTION_APP_NOTIFICATION_BUBBLE_SETTINGS
        } else {
            Settings.ACTION_APP_NOTIFICATION_SETTINGS
        }
        activity.startActivity(Intent(action).putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName))
    }

    private fun avatar(title: String): Icon {
        val size = 192
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        canvas.drawColor(Color.rgb(63, 81, 181))
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = 80f
            textAlign = Paint.Align.CENTER
        }
        val initial = title.trim().take(1).uppercase().ifEmpty { "?" }
        canvas.drawText(initial, size / 2f, size / 2f - (p.ascent() + p.descent()) / 2, p)
        return Icon.createWithAdaptiveBitmap(bmp)
    }

    fun show(c: Context, id: String, title: String) {
        val nm = notifications(c)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "Chat flutuante", NotificationManager.IMPORTANCE_DEFAULT).apply {
                setSound(null, null)
                enableVibration(false)
                setAllowBubbles(true)
            },
        )
        val icon = avatar(title)
        val person = Person.Builder().setName(title).setKey(id).setIcon(icon).setImportant(true).build()
        c.getSystemService(ShortcutManager::class.java).pushDynamicShortcut(
            ShortcutInfo.Builder(c, id)
                .setLongLived(true)
                .setShortLabel(title.ifEmpty { "Direct" })
                .setPerson(person)
                .setIcon(icon)
                .setIntent(Intent(c, MainActivity::class.java).setAction(Intent.ACTION_VIEW))
                .build(),
        )
        // O PendingIntent da bolha precisa ser mutável (Android 12+).
        val mutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val open = PendingIntent.getActivity(
            c, 0,
            Intent(c, MiniChatActivity::class.java).setAction(Intent.ACTION_VIEW).setData(uri(id)),
            PendingIntent.FLAG_UPDATE_CURRENT or mutable,
        )
        // Bolha arrastada para o lixo ou fechada (D7).
        val removed = PendingIntent.getBroadcast(
            c, 0,
            Intent(c, BubbleDismissReceiver::class.java).setData(uri(id)),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val metadata = Notification.BubbleMetadata.Builder(open, icon)
            .setDesiredHeight(600)
            .setAutoExpandBubble(true)
            .setSuppressNotification(true)
            .setDeleteIntent(removed)
            .build()
        val me = Person.Builder().setName("Eu").build()
        val notification = Notification.Builder(c, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setShortcutId(id)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setStyle(
                Notification.MessagingStyle(me)
                    .addMessage("Conversa em pop-up", System.currentTimeMillis(), person),
            )
            .setBubbleMetadata(metadata)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_SECRET)
            .setContentIntent(
                PendingIntent.getActivity(
                    c, 0, Intent(c, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            .build()
        save(c, ACTIVE, active(c) + id)
        nm.notify(TAG + id, 1, notification)
        c.startForegroundService(Intent(c, BubbleService::class.java))
    }

    /** A bolha abriu a tela: garante o serviço e o escopo. */
    fun attach(c: Context, id: String) {
        if (id !in active(c)) {
            save(c, ACTIVE, active(c) + id)
            CoreEngine.changed()
        }
        c.startForegroundService(Intent(c, BubbleService::class.java))
    }

    private fun remove(c: Context, id: String) {
        notifications(c).cancel(TAG + id, 1)
        // Tira também do "balões recentes" do sistema.
        c.getSystemService(ShortcutManager::class.java).removeLongLivedShortcuts(listOf(id))
    }

    /** Bolha removida pelo usuário: para o serviço e pede a tranca da conversa. */
    fun dismiss(c: Context, id: String) {
        save(c, DISMISSED, dismissed(c) + id)
        save(c, ACTIVE, active(c) - id)
        remove(c, id)
        if (active(c).isEmpty()) c.stopService(Intent(c, BubbleService::class.java))
        CoreEngine.changed()
    }

    /** Tela desligada (B1): a bolha fica, a conversa dela tranca (D7). */
    fun lockAll(c: Context) {
        if (active(c).isEmpty()) return
        save(c, DISMISSED, dismissed(c) + active(c))
        CoreEngine.screenOff()
    }

    fun closeAll(c: Context) {
        for (id in active(c)) remove(c, id)
        prefs(c).edit().clear().commit()
        c.stopService(Intent(c, BubbleService::class.java))
    }
}
