package ai.local.receptionist.sms

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File

/**
 * Hands the phone's MMS service a file to download a message into (or read a
 * response from). Not exported; access is granted per URI by the platform.
 */
class MmsFileProvider : ContentProvider() {
    companion object {
        private const val AUTHORITY = "ai.local.receptionist.mmsfiles"

        fun file(context: Context, name: String): File = File(File(context.cacheDir, "mms").apply { mkdirs() }, name)
        fun uri(name: String): Uri = Uri.parse("content://$AUTHORITY/$name")
    }

    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val name = uri.lastPathSegment ?: throw IllegalArgumentException("no file")
        require(name.matches(Regex("[A-Za-z0-9._-]+"))) { "bad file name" }
        val target = file(context!!, name)
        return ParcelFileDescriptor.open(target, ParcelFileDescriptor.parseMode(mode) or
            if (mode.contains('w')) ParcelFileDescriptor.MODE_CREATE else 0)
    }

    override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? = null
    override fun getType(uri: Uri): String = "application/octet-stream"
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?) = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?) = 0
}
