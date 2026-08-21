package com.clippy.clippy_companion

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL

private const val AUDIO_CHANNEL = "clippy.audio"

class MainActivity : FlutterActivity() {
    private var audioThread: Thread? = null
    @Volatile private var audioRunning = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val url = call.argument<String>("url")
                        if (url == null) {
                            result.error("missing_url", "Audio URL is required", null)
                        } else {
                            startAudio(url)
                            result.success(null)
                        }
                    }
                    "stop" -> {
                        stopAudio()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startAudio(url: String) {
        stopAudio()
        audioRunning = true
        audioThread = Thread {
            var connection: HttpURLConnection? = null
            var track: AudioTrack? = null
            try {
                val bufferSize = AudioTrack.getMinBufferSize(
                    16_000,
                    AudioFormat.CHANNEL_OUT_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                ).coerceAtLeast(2048)
                track = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build(),
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setSampleRate(16_000)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .build(),
                    )
                    .setBufferSizeInBytes(bufferSize)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()
                track.play()

                connection = URL(url).openConnection() as HttpURLConnection
                connection.connectTimeout = 3_000
                connection.readTimeout = 0
                connection.connect()
                if (connection.responseCode != HttpURLConnection.HTTP_OK) return@Thread

                connection.inputStream.use { input ->
                    val buffer = ByteArray(4096)
                    while (audioRunning) {
                        val count = input.read(buffer)
                        if (count <= 0) break
                        track.write(buffer, 0, count, AudioTrack.WRITE_BLOCKING)
                    }
                }
            } catch (_: Exception) {
                // A later tap retries the connection cleanly.
            } finally {
                audioRunning = false
                try { track?.stop() } catch (_: IllegalStateException) { }
                track?.release()
                connection?.disconnect()
            }
        }.apply { start() }
    }

    private fun stopAudio() {
        audioRunning = false
        audioThread?.interrupt()
        audioThread = null
    }

    override fun onDestroy() {
        stopAudio()
        super.onDestroy()
    }
}
