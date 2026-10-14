package com.clipitllc.clipitapp.services

import android.Manifest
import android.app.AlarmManager
import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.clipitllc.clipitapp.R
import com.clipitllc.clipitapp.ui.ClipsViewModel
import com.clipitllc.clipitapp.ui.Session

object RetentionScheduler {
    private const val ACTION_DELETE = "com.clipitllc.clipitapp.DELETE_ORIGINALS"
    private const val ACTION_REMIND = "com.clipitllc.clipitapp.REMIND_ORIGINALS"
    private const val CHANNEL_ID = "original_video_reminders"

    fun clipReady(context: Context, count: Int) {
        val prefs = context.getSharedPreferences("clipit_settings", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("notifications_enabled", false)) return
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val notifications = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notifications.createNotificationChannel(NotificationChannel(CHANNEL_ID, "ClipIt notifications", NotificationManager.IMPORTANCE_DEFAULT))
        notifications.notify(2102, NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.clipit_icon)
            .setContentTitle("ClipIt Ready! 🎬")
            .setContentText(if (count > 1) "Your highlights have finished processing and are ready to watch!" else "Your highlight has finished processing and is ready to watch!")
            .setAutoCancel(true)
            .build())
    }

    fun schedule(context: Context, sessions: List<Session>, days: Int, notificationsEnabled: Boolean) {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val now = System.currentTimeMillis()
        val deletionTimes = if (days > 0) sessions.filter { session ->
            !session.originalVideoAutoDeleteDisabled && session.clips.any { it.highlightIndex == null && !it.isReel }
        }.map { it.createdAt + days * 86_400_000L } else emptyList()
        val nextDeletion = deletionTimes.filter { it > now }.minOrNull()
        val nextReminder = if (notificationsEnabled) deletionTimes.map { it - 8 * 3_600_000L }.filter { it > now }.minOrNull() else null
        listOf(ACTION_DELETE to nextDeletion, ACTION_REMIND to nextReminder).forEach { (action, at) ->
            val pending = PendingIntent.getBroadcast(context, action.hashCode(), Intent(context, RetentionReceiver::class.java).setAction(action), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            manager.cancel(pending)
            if (at != null) manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        }
    }

    fun onReceive(context: Context, action: String?) {
        val model = ClipsViewModel(context.applicationContext as Application)
        if (action == ACTION_DELETE) model.applyOriginalVideoRetention()
        if (action == ACTION_REMIND) {
            val allowed = Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
            if (allowed) {
                val notifications = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                notifications.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Original video reminders", NotificationManager.IMPORTANCE_DEFAULT))
                val message = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.clipit_icon)
                    .setContentTitle("Original Video Auto-Delete Reminder")
                    .setContentText("Your raw footage is going to auto delete in 8 hours. Make sure any edits are made to your highlights!")
                    .setAutoCancel(true)
                    .build()
                notifications.notify(2101, message)
            }
        }
        val prefs = context.getSharedPreferences("clipit_settings", Context.MODE_PRIVATE)
        schedule(context, model.sessions.value, model.retentionDays(), prefs.getBoolean("notifications_enabled", false))
    }
}

class RetentionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        RetentionScheduler.onReceive(context, intent.action)
    }
}

class RetentionBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) RetentionScheduler.onReceive(context, null)
    }
}
