package com.pocketdev.paynuxagent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import io.flutter.plugin.common.EventChannel

class TerminalSessionService : Service() {
    companion object {
        const val NOTIFICATION_ID = 2
        const val ACTION_WAKELOCK = "com.pocketdev.paynuxagent.TOGGLE_WAKELOCK"
        const val ACTION_EXIT = "com.pocketdev.paynuxagent.EXIT_TERMINAL"
        const val CONTROL_EVENT_CHANNEL = "com.pocketdev.paynuxagent/terminal_control"

        var isRunning = false
            private set

        private var instance: TerminalSessionService? = null
        private val mainHandler = Handler(Looper.getMainLooper())
        var controlSink: EventChannel.EventSink? = null
        @Volatile private var shutdownPending = false
        @Volatile private var shutdownTimedOut = false
        private var shutdownTimeout: Runnable? = null

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

        /** Called by MainActivity when Dart reports that every session is down.
         *  The service is stopped only after that verified reply. */
        fun shutdownComplete(verified: Boolean) {
            mainHandler.post {
                shutdownTimeout?.let { mainHandler.removeCallbacks(it) }
                shutdownTimeout = null
                shutdownPending = false
                val service = instance
                if (verified && service != null) {
                    service.stopForeground(Service.STOP_FOREGROUND_REMOVE)
                    service.stopSelf()
                } else {
                    service?.releaseWakeLock()
                    service?.updateNotification(
                        "Terminal shutdown incomplete - sessions may still be running"
                    )
                }
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
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
                // Native owns the shutdown: it can clean every registered
                // terminal tree even when no Flutter isolate is available.
                requestNativeShutdown()
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

    /** Native-owned ACTION_EXIT. Dart is only notified to sync its UI; the
     *  process trees are verified and signalled here, so no isolate is needed. */
    private fun requestNativeShutdown() {
        if (shutdownPending) return
        shutdownPending = true
        shutdownTimedOut = false
        val timeout = Runnable {
            if (!shutdownPending) return@Runnable
            shutdownPending = false
            shutdownTimedOut = true
            releaseWakeLock()
            updateNotification("Terminal shutdown timed out - app remains open")
        }
        shutdownTimeout = timeout
        mainHandler.postDelayed(timeout, 20_000L)

        try {
            controlSink?.success("trees_terminated_by_native")
        } catch (_: Exception) {}

        TerminalProcessController.shared.terminateAll { verified ->
            mainHandler.post {
                shutdownTimeout?.let { mainHandler.removeCallbacks(it) }
                shutdownTimeout = null
                if (shutdownTimedOut) {
                    updateNotification("Terminal shutdown finished after timeout")
                    return@post
                }
                shutdownComplete(verified)
            }
        }
    }

    override fun onDestroy() {
        isRunning = false
        shutdownTimeout?.let { mainHandler.removeCallbacks(it) }
        shutdownTimeout = null
        shutdownPending = false
        instance = null
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

    private fun updateNotification(text: String = "Terminal session active") {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(text))
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

    private fun buildNotification(text: String = "Terminal session active"): Notification {
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
            .setContentText(text)
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
