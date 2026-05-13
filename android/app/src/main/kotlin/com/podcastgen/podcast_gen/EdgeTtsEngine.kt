package com.podcastgen.podcast_gen

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.util.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Native Android TTS engine using built-in TextToSpeech API.
 * Works completely offline — no proxy, no network, no Ktor needed.
 *
 * Uses UtteranceProgressListener to reliably detect synthesis completion
 * (no more Thread.sleep hacks).
 */
class EdgeTtsEngine(private val context: Context) {
    @Volatile private var tts: TextToSpeech? = null
    @Volatile private var isTtsReady = false
    private val ttsInitLock = CountDownLatch(1)
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        private const val TAG = "EdgeTtsEngine"
        private const val INIT_TIMEOUT_MS = 10000L
        private const val SYNTH_TIMEOUT_MS = 30000L
    }

    init {
        tts = TextToSpeech(context) { status ->
            if (status == TextToSpeech.SUCCESS) {
                isTtsReady = true
                log("TTS init SUCCESS")
            } else {
                log("!!! TTS init FAILED status=$status")
                isTtsReady = false
            }
            ttsInitLock.countDown()
        }

        Thread {
            val awaitSuccess = ttsInitLock.await(INIT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            if (!awaitSuccess) {
                log("!!! init latch TIMEOUT after ${INIT_TIMEOUT_MS}ms")
            } else {
                log("init latch released, isTtsReady=$isTtsReady")
            }
        }.start()
    }

    /**
     * Synthesize speech using Android native TTS.
     * Returns absolute file path on success, null on failure.
     */
    fun synthesize(
        text: String,
        voice: String,
        rate: String,
        pitch: String,
        volume: String,
        outputFormat: String
    ): String? {
        // Wait for TTS init to complete on IO thread (no-op if already done)
        try {
            val awaitSuccess = ttsInitLock.await(INIT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            if (!awaitSuccess) {
                log("!!! synthesize: init latch TIMEOUT")
                return null
            }
        } catch (e: Exception) {
            log("!!! synthesize: latch await exception: ${e.message}")
            return null
        }

        if (!isTtsReady || tts == null) {
            log("!!! synthesize: TTS not ready (isTtsReady=$isTtsReady tts=${tts==null})")
            return null
        }

        log("synthesize START: text_len=${text.length} voice=$voice")

        // Parse rate: "+0%" or "-10%" → Android TTS rate (0.25-4.0, 1.0=normal)
        val rateFloat = try {
            val rawRate = rate.trim().removeSuffix("%").toFloat()
            val sign = if (rate.trim().startsWith("+")) +1f else if (rate.trim().startsWith("-")) -1f else 0f
            val pct = kotlin.math.abs(rawRate)
            (100f + sign * pct) / 100f
        } catch (e: Exception) { 1.0f }.coerceIn(0.25f, 4.0f)

        // Parse pitch: "+0Hz" or "-10Hz" → Android TTS pitch (0.5-2.0, 1.0=normal)
        val pitchFloat = try {
            val rawPitch = pitch.trim().removeSuffix("Hz").toFloat()
            (1.0f + rawPitch / 50f).coerceIn(0.5f, 2.0f)
        } catch (e: Exception) { 1.0f }

        log("rate=$rateFloat pitch=$pitchFloat")

        // Map voice shortName to TTS locale
        val localeStr = voiceLocale(voice)
        val ttsLocale = try {
            Locale.forLanguageTag(localeStr)
        } catch (e: Exception) { Locale.US }

        // Synchronization for async callback
        val synthDone = CountDownLatch(1)
        val synthSuccess = AtomicBoolean(false)
        var synthError: String? = null
        var tempFile: File? = null  // defined at function scope, set inside post { }

        // Set up utterance progress listener BEFORE synthesizing
        // Must be set on main thread
        mainHandler.post {
            tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(uttId: String?) {
                    log("utterance START: $uttId")
                }

                override fun onDone(uttId: String?) {
                    log("utterance DONE: $uttId")
                    synthSuccess.set(true)
                    synthDone.countDown()
                }

                @Deprecated("Deprecated in Java", ReplaceWith("onError(uttId, errorCode)"))
                override fun onError(uttId: String?) {
                    log("!!! utterance ERROR: $uttId")
                    synthError = "error_utt_$uttId"
                    synthDone.countDown()
                }

                override fun onError(uttId: String?, errorCode: Int) {
                    log("!!! utterance ERROR[$errorCode]: $uttId")
                    synthError = "error_code_$errorCode"
                    synthDone.countDown()
                }
            })

            // Apply voice settings
            tts?.setSpeechRate(rateFloat)
            tts?.setPitch(pitchFloat)

            val langResult = tts?.setLanguage(ttsLocale)
            log("setLanguage($ttsLocale) = $langResult (available=${langResult == TextToSpeech.LANG_AVAILABLE})")

            // Try to select Neural/Premium voice
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                try {
                    val voices = tts?.voices
                    if (!voices.isNullOrEmpty()) {
                        val shortName = voiceShortName(voice)
                        val matched = voices.firstOrNull { v ->
                            v.locale == ttsLocale && (
                                v.name.contains(shortName, ignoreCase = true) ||
                                v.name.contains("Neural", ignoreCase = true) ||
                                v.name.contains("Premium", ignoreCase = true)
                            )
                        }
                        if (matched != null) {
                            tts?.voice = matched
                            log("Voice set: ${matched.name}")
                        } else {
                            log("No Neural voice match for '$shortName', available: ${voices.take(3).map { it.name }}")
                        }
                    }
                } catch (e: Exception) {
                    log("Voice lookup failed: ${e.message}")
                }
            }

            // Build output file (accessible outside post block via tempFile var)
            val cacheDir = context.cacheDir
            tempFile = File(cacheDir, "tts_out_${System.currentTimeMillis()}.wav")
            val utteranceId = "utt_${System.currentTimeMillis()}"

            // synthesizeToFile — works on all Android versions including 13+
            @Suppress("DEPRECATION")
            val result = tts?.synthesizeToFile(text, null, tempFile, utteranceId)
            log("synthesizeToFile result=$result file=${tempFile?.absolutePath}")

            if (result != TextToSpeech.SUCCESS) {
                synthError = "result_$result"
                synthDone.countDown()
            }
            // If SUCCESS, callback (onDone/onError) will countDown
        }

        // Wait for callback with timeout
        val waited = synthDone.await(SYNTH_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        if (!waited) {
            log("!!! synthesize TIMEOUT after ${SYNTH_TIMEOUT_MS}ms")
            return null
        }
        if (!synthSuccess.get()) {
            log("!!! synthesize FAILED: $synthError")
            return null
        }

        // Settle time for file system
        Thread.sleep(150)

        val f = tempFile
        return if (f != null && f.exists() && f.length() > 100) {
            val size = f.length()
            log("Audio ready: ${size} bytes → ${f.absolutePath}")
            // Copy to a permanent location before Flutter deletes the original
            try {
                val downloadsDir = android.os.Environment.getExternalStoragePublicDirectory(
                    android.os.Environment.DIRECTORY_DOWNLOADS)
                val permFile = File(downloadsDir, "PodcastGen_test_${System.currentTimeMillis()}.wav")
                f.copyTo(permFile, overwrite = true)
                log("Saved copy to: ${permFile.absolutePath}")
            } catch (e: Exception) {
                log("Copy to Downloads failed: ${e.message}")
            }
            f.absolutePath
        } else {
            log("!!! File missing or too small: exists=${f?.exists()} size=${f?.length()}")
            null
        }
    }

    private fun voiceShortName(voice: String): String {
        val parts = voice.split("-")
        return if (parts.size >= 3) parts[parts.size - 1].removeSuffix("Neural") else voice
    }

    private fun voiceLocale(voice: String): String {
        val parts = voice.split("-")
        return if (parts.size >= 2) "${parts[0]}-${parts[1]}" else "en-US"
    }

    fun close() {
        try {
            tts?.stop()
            tts?.shutdown()
        } catch (_: Exception) {}
    }

    private fun log(msg: String) {
        android.util.Log.d(TAG, msg)
        try {
            val f = File("/data/data/com.podcastgen.podcast_gen/cache/edge_tts_log.txt")
            FileOutputStream(f, true).use {
                it.write(("[${java.text.SimpleDateFormat("HH:mm:ss.SSS").format(java.util.Date())}] $msg\n").toByteArray())
            }
        } catch (_: Exception) {}
    }
}
