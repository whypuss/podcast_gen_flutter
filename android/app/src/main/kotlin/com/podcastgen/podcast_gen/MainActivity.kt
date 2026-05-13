package com.podcastgen.podcast_gen

import android.media.MediaPlayer
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val AUDIO_CHANNEL = "com.podcastgen.podcast_gen/audio"
    private val TTS_CHANNEL = "com.podcastgen.podcast_gen/edgetts"
    private var mediaPlayer: MediaPlayer? = null
    private var isPrepared = false
    private var ttsEngine: OkHttpEdgeTts? = null
    private val ttsScope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Audio playback channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "play" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath == null) {
                        result.error("INVALID_ARGUMENT", "filePath is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        mediaPlayer?.release()
                        mediaPlayer = MediaPlayer().apply {
                            setDataSource(filePath)
                            setOnPreparedListener {
                                isPrepared = true
                                start()
                                result.success(true)
                            }
                            setOnCompletionListener {
                                result.success(true)
                            }
                            setOnErrorListener { _, what, extra ->
                                android.util.Log.e("AudioPlayer", "MediaPlayer error: $what, $extra")
                                result.error("PLAYBACK_ERROR", "MediaPlayer error: $what", null)
                                true
                            }
                            prepareAsync()
                        }
                    } catch (e: Exception) {
                        result.error("PLAYBACK_ERROR", e.message, null)
                    }
                }
                "stop" -> {
                    mediaPlayer?.apply {
                        if (isPlaying) stop()
                        release()
                    }
                    mediaPlayer = null
                    isPrepared = false
                    result.success(true)
                }
                "pause" -> {
                    mediaPlayer?.pause()
                    result.success(true)
                }
                "resume" -> {
                    mediaPlayer?.start()
                    result.success(true)
                }
                "isPlaying" -> {
                    result.success(mediaPlayer?.isPlaying == true)
                }
                "getDuration" -> {
                    result.success(if (isPrepared) mediaPlayer?.duration ?: 0 else 0)
                }
                "getCurrentPosition" -> {
                    result.success(if (isPrepared) mediaPlayer?.currentPosition ?: 0 else 0)
                }
                else -> result.notImplemented()
            }
        }

        // Edge TTS native channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TTS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "synthesize" -> {
                    val text = call.argument<String>("text") ?: ""
                    val voice = call.argument<String>("voice") ?: "en-US-AriaNeural"
                    val rate = call.argument<String>("rate") ?: "+0%"
                    val pitch = call.argument<String>("pitch") ?: "+0Hz"
                    val volume = call.argument<String>("volume") ?: "+0%"
                    val outputFormat = call.argument<String>("outputFormat") ?: "audio-24khz-48kbitrate-mono-mp3"

                    ttsScope.launch(Dispatchers.IO) {
                        val engine = OkHttpEdgeTts(this@MainActivity)
                        ttsEngine = engine
                        // synthesize() returns ByteArray on success
                        val audioBytes = engine.synthesize(text, voice, rate, pitch, volume, outputFormat)
                        engine.close()
                        ttsEngine = null

                        withContext(Dispatchers.Main) {
                            if (audioBytes != null && audioBytes.isNotEmpty()) {
                                println("MainActivity: result.success returning ${audioBytes.size} bytes")
                                result.success(audioBytes)
                            } else {
                                println("MainActivity: result.error TTS_ERROR No audio generated")
                                result.error("TTS_ERROR", "No audio generated", null)
                            }
                        }
                    }
                }
                "stop" -> {
                    ttsEngine?.close()
                    ttsEngine = null
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        mediaPlayer?.release()
        mediaPlayer = null
        ttsEngine?.close()
        ttsScope.cancel()
        super.onDestroy()
    }
}
