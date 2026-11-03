package ai.local.receptionist

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.util.Log

/**
 * A persisted periodic job that restarts the receptionist service (and with
 * it the call-audio helper) when they are not running. JobScheduler restores
 * it after a reboot, which covers phones whose launch managers drop the
 * BOOT_COMPLETED broadcast (seen on nubia) or kill the app.
 */
class KeepAliveJob : JobService() {
    companion object {
        private const val JOB_ID = 4201

        fun schedule(context: Context) {
            val scheduler = context.getSystemService(JobScheduler::class.java)
            if (scheduler.getPendingJob(JOB_ID) != null) return
            val job = JobInfo.Builder(JOB_ID, ComponentName(context, KeepAliveJob::class.java))
                .setPersisted(true)
                .setPeriodic(15 * 60_000L)
                .build()
            val result = runCatching { scheduler.schedule(job) }.getOrDefault(JobScheduler.RESULT_FAILURE)
            if (result != JobScheduler.RESULT_SUCCESS) Log.w("KeepAliveJob", "could not schedule")
        }
    }

    override fun onStartJob(params: JobParameters?): Boolean {
        ReceptionistService.start(this)
        return false
    }

    override fun onStopJob(params: JobParameters?) = false
}
