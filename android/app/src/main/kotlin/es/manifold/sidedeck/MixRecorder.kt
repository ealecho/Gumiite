package es.manifold.sidedeck

import android.annotation.SuppressLint
import android.content.ContentValues
import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Records a USB mixer's return: the stereo mix it sends back to the phone
 * (on the EP-136 K.O., input channels 1-2, effects included).
 *
 * While recording, the pair is written untouched as 32-bit float to a temp
 * WAV in the app's cache (its header kept current, so a crash leaves a
 * usable file). On stop it is raised to just under full scale (the K.O.
 * sends it ~25-30 dB down), converted to 16-bit and saved as a WAV in
 * Music/Gumiite, then the temp file is deleted.
 */
object MixRecorder {
    private const val TAG = "sidedeck"
    private const val TEMP = "mix_recording.tmp.wav"
    private const val TARGET_PEAK = 0.891f // -1 dBFS
    private val MAX_GAIN = 10f.pow(36f / 20f) // never more than +36 dB

    @Volatile private var running = false
    private var thread: Thread? = null
    @Volatile private var peak = 0f
    @Volatile private var frames = 0L
    @Volatile private var error = ""
    private var startedAtMs = 0L
    private var rate = 48000
    private var deviceName = ""

    fun status(): Map<String, Any> = mapOf(
        "recording" to running,
        "seconds" to frames.toDouble() / rate,
        "startedAtMs" to startedAtMs,
        "peakDb" to if (peak <= 1e-9f) -120.0 else 20 * kotlin.math.log10(peak.toDouble()),
        "error" to error,
        "device" to deviceName,
    )

    private fun usbInput(am: AudioManager): AudioDeviceInfo? =
        am.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull {
            it.type == AudioDeviceInfo.TYPE_USB_DEVICE || it.type == AudioDeviceInfo.TYPE_USB_HEADSET
        }

    /** All of the device's input channels by index, widest that opens first. */
    @SuppressLint("MissingPermission") // checked by the caller
    private fun open(device: AudioDeviceInfo, rate: Int): AudioRecord? {
        val widest = max(
            device.channelCounts.maxOrNull() ?: 0,
            Integer.bitCount(device.channelIndexMasks.maxOrNull() ?: 0),
        )
        for (ch in listOf(widest, 8, 4, 2).filter { it in 2..16 }.distinct()) {
            for (src in listOf(MediaRecorder.AudioSource.UNPROCESSED, MediaRecorder.AudioSource.DEFAULT)) {
                try {
                    val format = AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                        .setSampleRate(rate)
                        .setChannelIndexMask((1 shl ch) - 1)
                        .build()
                    val r = AudioRecord.Builder()
                        .setAudioSource(src)
                        .setAudioFormat(format)
                        .setBufferSizeInBytes(rate * ch * 4 * 2) // 2 s
                        .build()
                    if (r.state == AudioRecord.STATE_INITIALIZED) {
                        r.setPreferredDevice(device)
                        return r
                    }
                    r.release()
                } catch (_: Exception) {
                }
            }
        }
        return null
    }

    @Synchronized
    fun start(context: Context): Map<String, Any> {
        if (running) return mapOf("ok" to true)
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val device = usbInput(am)
            ?: return mapOf("ok" to false, "error" to "No USB audio input. Plug in the mixer first.")
        // A float take runs ~23 MB a minute until it is saved.
        if (context.cacheDir.usableSpace < 1_000_000_000L) {
            return mapOf("ok" to false, "error" to "Less than 1 GB free: not enough room to record.")
        }
        rate = device.sampleRates.firstOrNull { it == 48000 } ?: 48000
        val r = open(device, rate)
            ?: return mapOf("ok" to false, "error" to "Could not open the mixer's USB input.")
        val channels = r.channelCount
        deviceName = device.productName?.toString() ?: ""
        val temp = File(context.cacheDir, TEMP)
        val out = RandomAccessFile(temp, "rw")
        out.setLength(0)
        out.write(header(0, 2, rate, 4))
        peak = 0f
        frames = 0
        error = ""
        startedAtMs = System.currentTimeMillis()
        running = true
        try {
            r.startRecording()
        } catch (e: Exception) {
            running = false
            r.release()
            out.close()
            temp.delete()
            return mapOf("ok" to false, "error" to "Could not start recording: ${e.message}")
        }
        Log.i(TAG, "mix recorder: ${channels}ch from ${r.routedDevice?.productName} @$rate")
        thread = Thread({ loop(r, out, channels) }, "sidedeck-rec").apply { start() }
        return mapOf("ok" to true, "channels" to channels, "device" to deviceName)
    }

    private fun loop(r: AudioRecord, out: RandomAccessFile, channels: Int) {
        // Below playback (URGENT_AUDIO): a late recorder only risks its own
        // buffer, which holds 2 s; a late player is a tick on the mixer.
        try {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
        } catch (_: Exception) {}
        val chunkFrames = rate / 20
        val inBuf = FloatArray(chunkFrames * channels)
        // Storage writes on their own thread, so a slow write never makes the
        // reader miss audio.
        val queue = java.util.concurrent.ArrayBlockingQueue<ByteArray>(400) // 20 s
        val end = ByteArray(0)
        val writer = Thread({
            var written = 0L
            var sinceHeader = 0L
            try {
                while (true) {
                    val chunk = queue.take()
                    if (chunk === end) break
                    out.write(chunk)
                    written += chunk.size / 8
                    sinceHeader += chunk.size / 8
                    if (sinceHeader >= rate * 5L) {
                        // Keep the header current so the temp file plays after a crash.
                        sinceHeader = 0
                        val pos = out.filePointer
                        out.seek(0)
                        out.write(header(dataBytes(written, 2, 4), 2, rate, 4))
                        out.seek(pos)
                    }
                }
            } catch (e: Exception) {
                error = "Could not write the recording: ${e.message}"
                running = false
            } finally {
                try {
                    out.seek(0)
                    out.write(header(dataBytes(written, 2, 4), 2, rate, 4))
                    out.close()
                } catch (_: Exception) {}
            }
        }, "sidedeck-rec-write").apply { start() }
        val startNs = System.nanoTime()
        var lastCheck = startNs
        var worstLagMs = 0.0
        try {
            while (running) {
                val got = r.read(inBuf, 0, inBuf.size, AudioRecord.READ_BLOCKING)
                if (got < 0) {
                    error = "The mixer's USB input stopped (error $got)."
                    break
                }
                if (got == 0) continue
                val n = got / channels
                val outBuf = ByteBuffer.allocate(n * 2 * 4).order(ByteOrder.LITTLE_ENDIAN)
                var p = peak
                for (i in 0 until n) {
                    val l = inBuf[i * channels]
                    val rr = inBuf[i * channels + 1]
                    p = max(p, max(abs(l), abs(rr)))
                    outBuf.putFloat(l).putFloat(rr)
                }
                peak = p
                if (!queue.offer(outBuf.array())) {
                    Log.w(TAG, "mix recorder: writer behind, dropped ${n} frames at ${"%.2f".format(frames.toDouble() / rate)} s")
                }
                frames += n
                // Audio missing from the input shows as frames falling behind the clock.
                val now = System.nanoTime()
                if (now - lastCheck > 1_000_000_000L) {
                    lastCheck = now
                    val lagMs = (now - startNs) / 1e6 - frames * 1000.0 / rate
                    if (lagMs > worstLagMs + 20) {
                        Log.w(TAG, "mix recorder: input fell behind by ${"%.0f".format(lagMs)} ms at ${"%.2f".format(frames.toDouble() / rate)} s")
                        worstLagMs = lagMs
                    }
                }
            }
        } catch (e: Exception) {
            error = "Recording failed: ${e.message}"
        } finally {
            try { r.stop() } catch (_: Exception) {}
            r.release()
            queue.put(end)
            writer.join()
            running = false
        }
    }

    /** Stop and save. Blocking (the save pass reads the whole take): call off the UI thread. */
    fun stop(context: Context): Map<String, Any> {
        running = false
        thread?.join(15000) // the writer flushes its queue first
        thread = null
        return finish(context)
    }

    /** A take left in the cache by a crash or a killed app: save it now. */
    fun recoverLeftover(context: Context): Map<String, Any>? {
        if (running) return null
        val temp = File(context.cacheDir, TEMP)
        if (!temp.exists() || temp.length() <= 44) {
            temp.delete()
            return null
        }
        return finish(context, recovered = true)
    }

    private fun finish(context: Context, recovered: Boolean = false): Map<String, Any> {
        val temp = File(context.cacheDir, TEMP)
        if (!temp.exists()) return mapOf("ok" to false, "error" to (error.ifEmpty { "Nothing was recorded." }))
        val bytes = temp.length() - 44
        val n = bytes / 8 // stereo float frames
        if (n < rate / 2) {
            temp.delete()
            return mapOf("ok" to false, "error" to "The recording was too short to keep.")
        }
        // A recovered take's peak isn't known: one quick pass finds it.
        var pk = if (recovered) scanPeak(temp) else peak
        if (pk <= 1e-6f) pk = 1f
        val gain = min(MAX_GAIN, TARGET_PEAK / pk)
        val name = "Gumiite mix " +
            SimpleDateFormat("yyyy-MM-dd HHmm", Locale.US).format(Date(temp.lastModified() - n * 1000 / rate)) +
            ".wav"
        return try {
            val (stream, where, done) = openOutput(context, name)
            stream.use { os ->
                os.write(header(dataBytes(n, 2, 2), 2, rate, 2))
                convert(temp, n, gain, os)
            }
            done()
            temp.delete()
            Log.i(TAG, "mix recorder: saved $name, ${n / rate} s, gain ${"%.1f".format(20 * kotlin.math.log10(gain))} dB")
            mapOf(
                "ok" to true,
                "name" to name,
                "where" to where,
                "seconds" to n.toDouble() / rate,
                "gainDb" to 20 * kotlin.math.log10(gain.toDouble()),
                "recovered" to recovered,
                "error" to error,
            )
        } catch (e: Exception) {
            // Keep the temp file so the take isn't lost; it is retried next time.
            mapOf("ok" to false, "error" to "Could not save the recording: ${e.message}")
        }
    }

    private fun scanPeak(temp: File): Float {
        var p = 0f
        BufferedInputStream(FileInputStream(temp), 1 shl 16).use { ins ->
            ins.skip(44)
            val buf = ByteArray(1 shl 16)
            val bb = ByteBuffer.wrap(buf).order(ByteOrder.LITTLE_ENDIAN)
            while (true) {
                val got = ins.read(buf)
                if (got <= 0) break
                bb.clear()
                for (i in 0 until got / 4) p = max(p, abs(bb.getFloat(i * 4)))
            }
        }
        return p
    }

    private fun convert(temp: File, n: Long, gain: Float, os: OutputStream) {
        BufferedInputStream(FileInputStream(temp), 1 shl 16).use { ins ->
            ins.skip(44)
            val inBuf = ByteArray(1 shl 16)
            val inBb = ByteBuffer.wrap(inBuf).order(ByteOrder.LITTLE_ENDIAN)
            val outBuf = ByteArray(inBuf.size / 2)
            val outBb = ByteBuffer.wrap(outBuf).order(ByteOrder.LITTLE_ENDIAN)
            var left = n * 2 // samples
            while (left > 0) {
                var got = ins.read(inBuf, 0, min(inBuf.size.toLong(), left * 4).toInt())
                if (got <= 0) break
                got -= got % 4
                outBb.clear()
                for (i in 0 until got / 4) {
                    val v = (inBb.getFloat(i * 4) * gain).coerceIn(-1f, 1f)
                    outBb.putShort((v * 32767f).roundToInt().toShort())
                }
                os.write(outBuf, 0, outBb.position())
                left -= got / 4
            }
        }
    }

    /** Music/Gumiite through MediaStore (Android 10+), else the app's Music folder. */
    private fun openOutput(context: Context, name: String): Triple<OutputStream, String, () -> Unit> {
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Audio.Media.DISPLAY_NAME, name)
                put(MediaStore.Audio.Media.MIME_TYPE, "audio/wav")
                put(MediaStore.Audio.Media.RELATIVE_PATH, Environment.DIRECTORY_MUSIC + "/Gumiite")
                put(MediaStore.Audio.Media.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore refused the file")
            val os = resolver.openOutputStream(uri) ?: throw IllegalStateException("Cannot write $uri")
            return Triple(os, "Music/Gumiite", {
                resolver.update(uri, ContentValues().apply { put(MediaStore.Audio.Media.IS_PENDING, 0) }, null, null)
            })
        }
        val dir = File(context.getExternalFilesDir(Environment.DIRECTORY_MUSIC), "Gumiite").apply { mkdirs() }
        val f = File(dir, name)
        return Triple(f.outputStream(), dir.absolutePath, {})
    }

    private fun dataBytes(frames: Long, channels: Int, bytesPer: Int): Int =
        min(frames * channels * bytesPer, 0xFFFFFFFFL - 36).toInt()

    private fun header(len: Int, channels: Int, rate: Int, bytesPer: Int): ByteArray {
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
