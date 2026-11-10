// SPECTRE Capture — background deposit (WorkManager).
// Runs only with a network; shown as a neutral "data sync" notification while
// uploading (no file name, no folder name). Retries are bounded by the engine.
package org.horizontal.tella.mobile.spectre

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.ForegroundInfo
import androidx.work.Worker
import androidx.work.WorkerParameters
import timber.log.Timber

class SpectreDepositWorker(context: Context, params: WorkerParameters) : Worker(context, params) {

    companion object {
        private const val CHANNEL = "spectre-deposit"
        private const val NOTIFICATION_ID = 0x5bec
    }

    override fun doWork(): Result {
        val engine = SpectreDeposit.engineOrInit(applicationContext) ?: return Result.success()
        if (!engine.hasAutomaticWork()) {
            SpectreDeposit.refreshNow()
            return Result.success()
        }
        try {
            setForegroundAsync(foregroundInfo()).get()
        } catch (t: Throwable) {
            Timber.d(t, "SPECTRE: foreground not granted, continuing in background")
        }
        var rounds = 0
        while (rounds++ < 30 && !isStopped) {
            try {
                engine.processAll()
            } catch (t: Throwable) {
                Timber.e(t, "SPECTRE: processing error")
                break
            }
            val next = engine.nextWakeAt() ?: break
            if (next > System.currentTimeMillis() + 2_000) break   // nothing due right now
        }
        SpectreDeposit.refreshNow()
        SpectreDeposit.scheduleNext(engine.nextWakeAt())
        return Result.success()
    }

    override fun getForegroundInfo(): ForegroundInfo = foregroundInfo()

    private fun foregroundInfo(): ForegroundInfo {
        val nm = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Envoi sécurisé", NotificationManager.IMPORTANCE_LOW))
        }
        val n = NotificationCompat.Builder(applicationContext, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("Envoi sécurisé en cours")
            .setOngoing(true)
            .setSilent(true)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .build()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(NOTIFICATION_ID, n)
        }
    }
}
