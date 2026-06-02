package com.jawnstoninc.jawnremote

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Two platform channels:
 *
 *  - "jawnremote/volume" captures the hardware volume rocker while the remote is
 *    connected and forwards it to Flutter (which sends the volume keys to the PC).
 *
 *  - "jawnremote/files" exposes the Storage Access Framework for file transfer:
 *    pickFile (ACTION_OPEN_DOCUMENT) and saveFile (ACTION_CREATE_DOCUMENT). SAF
 *    needs no storage permission, so the app stays INTERNET-only. We do this in
 *    the app's own Activity rather than pulling a file-picker plugin (that keeps
 *    the dependency set tiny and dodges plugin/Gradle-toolchain breakage).
 */
class MainActivity : FlutterActivity() {
    private val channelName = "jawnremote/volume"
    private var channel: MethodChannel? = null
    private var intercept = false

    private val fileChannelName = "jawnremote/files"
    private var fileChannel: MethodChannel? = null
    private val reqPick = 9101
    private val reqSave = 9102
    private var pendingResult: MethodChannel.Result? = null
    private var pendingSavePath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setIntercept" -> {
                    intercept = call.arguments as? Boolean ?: false
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        fileChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileChannelName)
        fileChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "cacheDir" -> result.success(cacheDir.absolutePath)
                "pickFile" -> {
                    if (pendingResult != null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                    }
                    try {
                        startActivityForResult(i, reqPick)
                    } catch (e: Exception) {
                        pendingResult = null
                        result.success(null)
                    }
                }
                "saveFile" -> {
                    val src = call.argument<String>("src")
                    val name = call.argument<String>("name") ?: "file"
                    if (src == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    if (pendingResult != null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingSavePath = src
                    val i = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, name)
                    }
                    try {
                        startActivityForResult(i, reqSave)
                    } catch (e: Exception) {
                        pendingResult = null
                        pendingSavePath = null
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != reqPick && requestCode != reqSave) return
        val result = pendingResult
        pendingResult = null
        val savePath = pendingSavePath
        pendingSavePath = null
        if (result == null) return
        val uri: Uri? = if (resultCode == Activity.RESULT_OK) data?.data else null

        if (requestCode == reqPick) {
            if (uri == null) {
                result.success(null)
                return
            }
            // Copy the picked content into our cache on a worker thread (avoids
            // an ANR on large files), then hand Flutter a plain file path.
            Thread {
                val reply: Any? = try {
                    val name = queryName(uri)
                    val dest = File(cacheDir, "pick_${System.currentTimeMillis()}_${sanitize(name)}")
                    contentResolver.openInputStream(uri)!!.use { input ->
                        dest.outputStream().use { out -> input.copyTo(out) }
                    }
                    mapOf("path" to dest.absolutePath, "name" to name, "size" to dest.length())
                } catch (e: Exception) {
                    null
                }
                runOnUiThread { result.success(reply) }
            }.start()
        } else { // reqSave
            if (uri == null || savePath == null) {
                result.success(false)
                return
            }
            Thread {
                val ok = try {
                    File(savePath).inputStream().use { input ->
                        contentResolver.openOutputStream(uri)!!.use { out -> input.copyTo(out) }
                    }
                    true
                } catch (e: Exception) {
                    false
                }
                runOnUiThread { result.success(ok) }
            }.start()
        }
    }

    private fun queryName(uri: Uri): String {
        var name = "file"
        try {
            contentResolver.query(uri, null, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni) ?: "file"
                }
            }
        } catch (e: Exception) {
        }
        return name
    }

    private fun sanitize(n: String): String = n.replace(Regex("[\\\\/:*?\"<>|]"), "_")

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (intercept) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    channel?.invokeMethod("volumeUp", null)
                    return true // consume — don't change the phone's own volume
                }
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    channel?.invokeMethod("volumeDown", null)
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if (intercept &&
            (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)) {
            return true // swallow the matching up-event (suppresses the volume HUD)
        }
        return super.onKeyUp(keyCode, event)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        channel = null
        fileChannel?.setMethodCallHandler(null)
        fileChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
