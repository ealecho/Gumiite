package es.manifold.sidedeck

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Debug tool: record a few seconds from a USB mixer's input (e.g. the EP-136
 * K.O. offers 8 channels back to the phone) so we can tell which channels
 * carry the master mix. Writes a WAV to the app's files and returns each
 * channel's peak and RMS level.
 */
object UsbInputTest {
    private const val TAG = "sidedeck"

    private fun usbInput(am: AudioManager): AudioDeviceInfo? =
        am.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull {
            it.type == AudioDeviceInfo.TYPE_USB_DEVICE || it.type == AudioDeviceInfo.TYPE_USB_HEADSET
        }

    @SuppressLint("MissingPermission") // checked by the caller
    fun record(context: Context, seconds: Int): Map<String, Any> {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val device = usbInput(am) ?: return mapOf("ok" to false, "error" to "No USB audio input found.")
        val rate = device.sampleRates.firstOrNull { it == 48000 } ?: 48000
        val counts = device.channelCounts.toList()
        val maxCh = (counts.maxOrNull() ?: 0).coerceAtLeast(
            Integer.bitCount(device.channelIndexMasks.maxOrNull() ?: 0),
        )
        // Widest first: all channels by index, then fewer.
        val tries = listOf(maxCh, 8, 4, 2).filter { it in 1..16 }.distinct()
        val encodings = listOf(AudioFormat.ENCODING_PCM_FLOAT, AudioFormat.ENCODING_PCM_16BIT)
        val sources = listOf(MediaRecorder.AudioSource.UNPROCESSED, MediaRecorder.AudioSource.DEFAULT)
        var rec: AudioRecord? = null
        var channels = 0
        var encoding = 0
        val attempts = mutableListOf<String>()
        loop@ for (ch in tries) for (enc in encodings) for (src in sources) {
            try {
                val format = AudioFormat.Builder()
                    .setEncoding(enc)
                    .setSampleRate(rate)
                    .setChannelIndexMask((1 shl ch) - 1)
                    .build()
                val minBuf = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_STEREO, enc)
                val r = AudioRecord.Builder()
                    .setAudioSource(src)
                    .setAudioFormat(format)
                    .setBufferSizeInBytes(max(minBuf, rate * ch * 4 / 5))
                    .build()
                if (r.state != AudioRecord.STATE_INITIALIZED) {
                    r.release()
                    attempts += "${ch}ch enc=$enc src=$src: not initialized"
                    continue
                }
                r.setPreferredDevice(device)
                rec = r
                channels = r.channelCount
                encoding = enc
                break@loop
            } catch (e: Exception) {
                attempts += "${ch}ch enc=$enc src=$src: ${e.message}"
            }
        }
        val r = rec ?: return mapOf(
            "ok" to false,
            "error" to "Could not open the USB input. ${attempts.joinToString("; ")}",
        )
        val bytesPer = if (encoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
        val totalFrames = rate * seconds
        // Streamed to the file (a minute of 8ch float is ~92 MB); the header's
        // sizes are filled in at the end.
        val file = File(context.filesDir, "usb_input_test.wav")
        val out = RandomAccessFile(file, "rw")
        out.setLength(0)
        out.write(ByteArray(44))
        val chunkBytes = ByteBuffer.allocate((rate / 20) * channels * bytesPer).order(ByteOrder.LITTLE_ENDIAN)
        val peak = DoubleArray(channels)
        val sumSq = DoubleArray(channels)
        var frames = 0
        try {
            r.startRecording()
            val routed = r.routedDevice
            Log.i(TAG, "usb input test: ${channels}ch enc=$encoding rate=$rate routed=${routed?.productName}")
            val chunkFrames = rate / 20
            val f = FloatArray(chunkFrames * channels)
            val s = ShortArray(chunkFrames * channels)
            while (frames < totalFrames) {
                val want = minOf(chunkFrames, totalFrames - frames) * channels
                val got = if (bytesPer == 4) {
                    r.read(f, 0, want, AudioRecord.READ_BLOCKING)
                } else {
                    r.read(s, 0, want)
                }
                if (got <= 0) break
                chunkBytes.clear()
                for (i in 0 until got) {
                    val v = if (bytesPer == 4) f[i].toDouble() else s[i] / 32768.0
                    val c = i % channels
                    peak[c] = max(peak[c], abs(v))
                    sumSq[c] += v * v
                    if (bytesPer == 4) chunkBytes.putFloat(f[i]) else chunkBytes.putShort(s[i])
                }
                out.write(chunkBytes.array(), 0, chunkBytes.position())
                frames += got / channels
            }
        } finally {
            try { r.stop() } catch (_: Exception) {}
            r.release()
        }
        out.seek(0)
        out.write(wavHeader(frames * channels * bytesPer, channels, rate, bytesPer))
        out.close()
        fun db(x: Double) = if (x <= 1e-9) -120.0 else 20 * log10(x)
        return mapOf(
            "ok" to true,
            "channels" to channels,
            "sampleRate" to rate,
            "float" to (bytesPer == 4),
            "seconds" to frames.toDouble() / rate,
            "path" to file.absolutePath,
            "device" to (device.productName?.toString() ?: ""),
            "peakDb" to peak.map { db(it) },
            "rmsDb" to (0 until channels).map { db(sqrt(sumSq[it] / max(1, frames))) },
        )
    }

    private fun wavHeader(len: Int, channels: Int, rate: Int, bytesPer: Int): ByteArray {
        val h = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        h.put("RIFF".toByteArray()).putInt(36 + len).put("WAVE".toByteArray())
        h.put("fmt ".toByteArray()).putInt(16)
        h.putShort((if (bytesPer == 4) 3 else 1).toShort()) // 3 = IEEE float
        h.putShort(channels.toShort()).putInt(rate)
        h.putInt(rate * channels * bytesPer).putShort((channels * bytesPer).toShort())
        h.putShort((bytesPer * 8).toShort())
        h.put("data".toByteArray()).putInt(len)
        return h.array()
    }
}
