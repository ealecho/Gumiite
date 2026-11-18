package es.manifold.sidedeck

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var usbHotplug: UsbHotplug? = null
    private var stickAccess: StickAccess? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    // startAndVerify() can sleep; keep that off the Flutter/UI thread.
    private val usbExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "sidedeck-usb-ctrl")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        keepScreenOn()
    }

    override fun onResume() {
        super.onResume()
        keepScreenOn()
    }

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        keepScreenOn()
    }

    private fun keepScreenOn() {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.decorView.keepScreenOn = true
        findViewById<android.view.View>(android.R.id.content)?.keepScreenOn = true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "sidedeck/audio")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "usbOutputDevice" -> result.success(findUsbOutput(this))
                    "startUsbPlayback" -> {
                        val handle = (call.argument<Number>("handle") ?: 0).toLong()
                        val deviceId = call.argument<Int>("deviceId") ?: 0
                        val channels = call.argument<Int>("channels") ?: 4
                        val appCtx = applicationContext
                        usbExecutor.execute {
                            val map = UsbPlayer.start(appCtx, handle, deviceId, channels)
                            mainHandler.post { result.success(map) }
                        }
                    }
                    "stopUsbPlayback" -> {
                        usbExecutor.execute {
                            UsbPlayer.stop()
                            mainHandler.post { result.success(null) }
                        }
                    }
                    // Record the USB mixer's return (its mix, effects included).
                    "startRecording" -> {
                        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 4712)
                            result.success(mapOf("ok" to false, "permission" to true))
                        } else {
                            val appCtx = applicationContext
                            usbExecutor.execute {
                                val map = MixRecorder.start(appCtx)
                                mainHandler.post { result.success(map) }
                            }
                        }
                    }
                    "stopRecording" -> {
                        val appCtx = applicationContext
                        Thread({
                            val map = MixRecorder.stop(appCtx)
                            mainHandler.post { result.success(map) }
                        }, "sidedeck-rec-save").start()
                    }
                    "recordingStatus" -> result.success(MixRecorder.status())
                    "recoverRecording" -> {
                        val appCtx = applicationContext
                        Thread({
                            val map = MixRecorder.recoverLeftover(appCtx)
                            mainHandler.post { result.success(map) }
                        }, "sidedeck-rec-recover").start()
                    }
                    // Debug: record a few seconds from a USB mixer's input.
                    "testUsbInput" -> {
                        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 4711)
                            result.success(
                                mapOf(
                                    "ok" to false,
                                    "permission" to true,
                                    "error" to "Allow recording audio, then tap the test again.",
                                ),
                            )
                        } else {
                            val seconds = call.argument<Int>("seconds") ?: 10
                            val appCtx = applicationContext
                            Thread({
                                val map = try {
                                    UsbInputTest.record(appCtx, seconds)
                                } catch (e: Exception) {
                                    mapOf("ok" to false, "error" to (e.message ?: e.toString()))
                                }
                                mainHandler.post { result.success(map) }
                            }, "sidedeck-usb-in-test").start()
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        val hotplug = UsbHotplug(this)
        usbHotplug = hotplug
        UsbPlayer.setUnexpectedStopListener { id, name ->
            hotplug.emit(
                mapOf(
                    "event" to "playback_stopped",
                    "id" to id,
                    "channels" to 0,
                    "name" to name,
                ),
            )
        }
        EventChannel(messenger, "sidedeck/usb").setStreamHandler(hotplug)
        val stick = StickAccess(this)
        stickAccess = stick
        MethodChannel(messenger, "sidedeck/stick").setMethodCallHandler(stick)
        // Debug: stream what a USB MIDI device (the K.O.'s knobs/buttons) sends.
        EventChannel(messenger, "sidedeck/midi").setStreamHandler(MidiMonitor(this))
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (stickAccess?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        UsbPlayer.setUnexpectedStopListener(null)
        usbHotplug?.stop()
        usbHotplug = null
        UsbPlayer.stop()
        usbExecutor.shutdownNow()
        super.onDestroy()
    }

    /** Android 14+ reports the configurations a USB output stream can be opened with. */
    private fun mixerAttributesOf(am: AudioManager, device: AudioDeviceInfo): String {
        if (Build.VERSION.SDK_INT < 34) return ""
        return try {
            am.getSupportedMixerAttributes(device).joinToString("; ") {
                "${it.format.channelCount}ch enc=${it.format.encoding} sr=${it.format.sampleRate}"
            }
        } catch (_: Exception) {
            ""
        }
    }

    private fun findUsbOutput(context: Context): Map<String, Any> {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Log.isLoggable("sidedeck", Log.DEBUG)) {
            for (d in am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
                Log.d(
                    "sidedeck",
                    "audio out id=${d.id} type=${d.type} name=${d.productName} " +
                        "maxCh=${UsbDevices.maxChannels(am, d)} " +
                        "counts=[${d.channelCounts.joinToString()}] " +
                        "indexMasks=[${d.channelIndexMasks.joinToString { "0x" + Integer.toHexString(it) }}] " +
                        "rates=[${d.sampleRates.joinToString()}] usb=${UsbDevices.isUsbOutput(d)} " +
                        "mixer=[${mixerAttributesOf(am, d)}]",
                )
            }
        }
        val best = UsbDevices.findBest(am)
        return mapOf(
            "id" to (best?.first?.id ?: 0),
            "channels" to (best?.second ?: 0),
            "name" to (best?.first?.productName?.toString() ?: ""),
        )
    }
}
