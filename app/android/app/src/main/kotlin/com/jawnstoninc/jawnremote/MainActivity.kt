package com.jawnstoninc.jawnremote

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Captures the phone's hardware volume rocker while the remote is connected and
 * forwards it to Flutter, which sends the volume keys on to the PC. Flutter turns
 * capture on/off over the "jawnremote/volume" channel (on while connected, off
 * otherwise) so the buttons behave normally — changing the phone's own volume —
 * whenever you're not actively controlling the PC.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "jawnremote/volume"
    private var channel: MethodChannel? = null
    private var intercept = false

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
    }

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
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
