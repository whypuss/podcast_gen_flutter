package com.podcastgen.podcast_gen

import android.media.MediaPlayer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.podcastgen.podcast_gen/audio"
    private var mediaPlayer: MediaPlayer? = null
    private var isPrepared = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
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
                                result.success(true) // playback done
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
    }

    override fun onDestroy() {
        mediaPlayer?.release()
        mediaPlayer = null
        super.onDestroy()
    }
}
