package com.pocketdev.paynuxagent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class TerminalSessionService : Service() {
    companion object {
        const val NOTIFICATION_ID = 2
        const val ACTION_WAKELOCK = "com.pocketdev.paynuxagent.TOGGLE_WAKELOCK"
        const val ACTION_EXIT = "com.pocketdev.paynuxagent.EXIT_TERMINAL"

        var isRunning = false
            private set

        fun start(context: Context) {
            val intent = Intent(context, TerminalSessionService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, TerminalSessionService::class.java))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_WAKELOCK -> {
                if (wakeLock?.isHeld == true) {
                    releaseWakeLock()
                } else {
                    acquireWakeLock()
                }
                updateNotification()
                return START_STICKY
            }

            ACTION_EXIT -> {
                isRunning = false
                releaseWakeLock()
                stopForeground(true)
                stopSelf()
                android.os.Process.killProcess(android.os.Process.myPid())
                return START_NOT_STICKY
            }
        }

        startForeground(NOTIFICATION_ID, buildNotification())
        if (!isRunning) {
            isRunning = true
            acquireWakeLock()
            updateNotification()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        releaseWakeLock()
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        releaseWakeLock()
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "PayNux Agent::TerminalWakeLock"
        ).apply {
            setReferenceCounted(false)
            acquire(24 * 60 * 60 * 1000L)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null
    }

    private fun actionIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, TerminalSessionService::class.java).setAction(action)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(this, requestCode, intent, flags)
        } else {
            PendingIntent.getService(this, requestCode, intent, flags)
        }
    }

    private fun updateNotification() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                GatewayService.CHANNEL_ID,
                "PayNux Agent • Terminal",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps the PayNux Agent terminal session active"
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, GatewayService.CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("PayNux Agent • Terminal")
            .setContentText("Terminal session active")
            .setSmallIcon(R.drawable.ic_stat_paynux)
            .setContentIntent(openIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(
                android.R.drawable.ic_lock_idle_lock,
                if (wakeLock?.isHeld == true) "WakeLock ON" else "WakeLock",
                actionIntent(ACTION_WAKELOCK, 10)
            )
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Exit",
                actionIntent(ACTION_EXIT, 11)
            )
            .build()
    }
}
