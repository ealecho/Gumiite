package es.manifold.sidedeck

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Access to a rekordbox USB stick through the Storage Access Framework.
 *
 * With only READ_MEDIA_AUDIO the app can open audio files by path, but not the
 * stick's PIONEER/ database and analysis files, which are not media. The user
 * picks the stick (or a folder holding a copy of its PIONEER/ and Contents/)
 * once; the tree permission is persisted, and files are then read by their
 * path relative to that root.
 */
class StickAccess(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private var pending: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(result)
            "read" -> background(result) {
                read(call.argument<String>("tree")!!, call.argument<String>("path")!!)
            }
            "copy" -> background(result) {
                copy(
                    call.argument<String>("tree")!!,
                    call.argument<String>("path")!!,
                    call.argument<String>("dest")!!,
                )
            }
            else -> result.notImplemented()
        }
    }

    private fun pick(result: MethodChannel.Result) {
        pending?.success(null)
        pending = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
        )
        activity.startActivityForResult(intent, REQUEST_PICK)
    }

    /** Forwarded from MainActivity. Returns true when the result was ours. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK) return false
        val result = pending ?: return true
        pending = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            result.success(null)
            return true
        }
        try {
            activity.contentResolver.takePersistableUriPermission(
                tree,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        } catch (e: SecurityException) {
            Log.w("sidedeck", "stick: no persistable permission: $e")
        }
        val docId = DocumentsContract.getTreeDocumentId(tree)
        result.success(mapOf("tree" to tree.toString(), "basePath" to (basePathOf(docId) ?: "")))
        return true
    }

    /**
     * A file under the picked tree, by path relative to its root. External
     * storage document ids are "VOLUME:dir/file", so the id is built from the
     * tree's own id instead of walking the tree.
     */
    private fun documentUri(tree: String, relPath: String): Uri {
        val treeUri = Uri.parse(tree)
        val root = DocumentsContract.getTreeDocumentId(treeUri)
        val rel = relPath.trimStart('/')
        val id = if (root.endsWith(":")) root + rel else "$root/$rel"
        return DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
    }

    private fun read(tree: String, relPath: String): ByteArray? = try {
        activity.contentResolver.openInputStream(documentUri(tree, relPath))?.use { it.readBytes() }
    } catch (e: Exception) {
        null // missing file (no .EXT on an old export, say): the caller falls back
    }

    private fun copy(tree: String, relPath: String, dest: String): Boolean = try {
        val out = File(dest)
        out.parentFile?.mkdirs()
        activity.contentResolver.openInputStream(documentUri(tree, relPath))?.use { input ->
            out.outputStream().use { input.copyTo(it) }
        } != null
    } catch (e: Exception) {
        Log.w("sidedeck", "stick: copy $relPath failed: $e")
        false
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            val value = try {
                work()
            } catch (e: Exception) {
                null
            }
            main.post { result.success(value) }
        }.start()
    }

    companion object {
        private const val REQUEST_PICK = 4711

        /**
         * The filesystem path of a tree's root where Android also exposes it
         * by path ("primary:Music" -> /storage/emulated/0/Music, "1A2B-3C4D:"
         * -> /storage/1A2B-3C4D), so audio can be opened directly; null for
         * other providers.
         */
        fun basePathOf(docId: String): String? {
            val colon = docId.indexOf(':')
            if (colon < 0) return null
            val volume = docId.substring(0, colon)
            val sub = docId.substring(colon + 1)
            val root = if (volume == "primary") "/storage/emulated/0" else "/storage/$volume"
            return if (sub.isEmpty()) root else "$root/$sub"
        }
    }
}
