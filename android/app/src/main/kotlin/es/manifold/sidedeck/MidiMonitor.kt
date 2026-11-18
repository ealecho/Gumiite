package es.manifold.sidedeck

import android.content.Context
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel

/**
 * Debug tool: listens to a USB MIDI device (e.g. the EP-136 K.O. in Multi mode
 * with MIDI on) and streams every message it sends to Dart, so we can see what
 * each knob and button sends before mapping them to deck controls.
 *
 * Events: {"event":"device","name":...}, {"event":"none"},
 * {"event":"msg","status":..,"channel":..,"d1":..,"d2":..,"raw":"B0 15 7F"}.
 */
class MidiMonitor(context: Context) : EventChannel.StreamHandler {
    private val manager = context.getSystemService(Context.MIDI_SERVICE) as MidiManager?
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var device: MidiDevice? = null
    private var port: MidiOutputPort? = null
    private var openId = -1
    private var opening = false

    private val callback = object : MidiManager.DeviceCallback() {
        override fun onDeviceAdded(info: MidiDeviceInfo) {
            if (device == null && !opening) openFirst()
        }

        override fun onDeviceRemoved(info: MidiDeviceInfo) {
            if (info.id == openId) {
                close()
                emit(mapOf("event" to "none"))
                openFirst()
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        val m = manager
        if (m == null) {
            emit(mapOf("event" to "error", "error" to "This phone has no MIDI support."))
            return
        }
        m.registerDeviceCallback(callback, main)
        openFirst()
    }

    override fun onCancel(arguments: Any?) {
        manager?.unregisterDeviceCallback(callback)
        close()
        sink = null
    }

    @Suppress("DEPRECATION")
    private fun usbDevices(m: MidiManager): List<MidiDeviceInfo> {
        val all = if (Build.VERSION.SDK_INT >= 33) {
            m.getDevicesForTransport(MidiManager.TRANSPORT_MIDI_BYTE_STREAM).toList()
        } else {
            m.devices.toList()
        }
        return all.filter { it.type == MidiDeviceInfo.TYPE_USB && it.outputPortCount > 0 }
    }

    private fun nameOf(info: MidiDeviceInfo): String {
        val p = info.properties
        return p.getString(MidiDeviceInfo.PROPERTY_NAME)
            ?: p.getString(MidiDeviceInfo.PROPERTY_PRODUCT)
            ?: "USB MIDI device"
    }

    private fun openFirst() {
        val m = manager ?: return
        val info = usbDevices(m).firstOrNull()
        if (info == null) {
            emit(mapOf("event" to "none"))
            return
        }
        opening = true
        m.openDevice(info, { d ->
            opening = false
            if (d == null) {
                emit(mapOf("event" to "error", "error" to "Could not open ${nameOf(info)}."))
                return@openDevice
            }
            if (sink == null) { // cancelled while opening
                d.close()
                return@openDevice
            }
            // The device's output port is what it sends to us.
            val p = d.openOutputPort(0)
            if (p == null) {
                d.close()
                emit(mapOf("event" to "error", "error" to "${nameOf(info)} has no readable MIDI port."))
                return@openDevice
            }
            p.connect(Parser { msg -> main.post { emit(msg) } })
            device = d
            port = p
            openId = info.id
            Log.i("sidedeck", "midi monitor: listening to ${nameOf(info)}")
            emit(mapOf("event" to "device", "name" to nameOf(info)))
        }, main)
    }

    private fun close() {
        try { port?.close() } catch (_: Exception) {}
        try { device?.close() } catch (_: Exception) {}
        port = null
        device = null
        openId = -1
    }

    private fun emit(map: Map<String, Any>) {
        sink?.success(map)
    }

    /**
     * Turns the raw byte stream into whole channel messages. Handles running
     * status, skips SysEx, and drops clock/active-sensing bytes (they would
     * flood the list).
     */
    private class Parser(private val out: (Map<String, Any>) -> Unit) : MidiReceiver() {
        private var status = 0
        private val data = IntArray(2)
        private var have = 0
        private var inSysex = false

        override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
            for (i in offset until offset + count) feed(msg[i].toInt() and 0xFF)
        }

        private fun needed(s: Int) = when (s and 0xF0) {
            0xC0, 0xD0 -> 1
            else -> 2
        }

        private fun feed(b: Int) {
            if (b >= 0xF8) return // real-time: clock, start/stop, active sensing
            if (b == 0xF0) { inSysex = true; return }
            if (b == 0xF7) { inSysex = false; return }
            if (inSysex) return
            if (b >= 0x80) {
                status = if (b < 0xF0) b else 0 // other system common: ignore
                have = 0
                return
            }
            if (status == 0) return
            data[have++] = b
            if (have < needed(status)) return
            val n = have
            have = 0 // running status: next data bytes reuse the same status
            val bytes = listOf(status) + data.take(n)
            out(
                mapOf(
                    "event" to "msg",
                    "status" to (status and 0xF0),
                    "channel" to (status and 0x0F) + 1,
                    "d1" to data[0],
                    "d2" to if (n > 1) data[1] else 0,
                    "raw" to bytes.joinToString(" ") { "%02X".format(it) },
                ),
            )
        }
    }
}
