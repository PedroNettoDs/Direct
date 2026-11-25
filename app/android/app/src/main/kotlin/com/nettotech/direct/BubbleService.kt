package com.nettotech.direct

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Mantém o processo vivo enquanto houver bolha. O WebSocket (só das conversas
 * das bolhas) é do isolate principal, no mesmo processo.
 */
class BubbleService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel("servico", "Conexão do chat flutuante", NotificationManager.IMPORTANCE_LOW),
        )
        val notification = Notification.Builder(this, "servico")
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentTitle("Chat flutuante ativo")
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
        } else {
            startForeground(1, notification)
        }
        CoreEngine.get(this)
        // Sem reinício: processo morto perde as chaves; a bolha pede a senha.
        return START_NOT_STICKY
    }
}
