package com.podcastgen.podcast_gen

import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.websocket.DefaultClientWebSocketSession
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.plugins.websocket.webSocketSession
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.header
import io.ktor.client.request.url
import io.ktor.util.decodeString
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.readBytes
import io.ktor.websocket.readReason
import io.ktor.websocket.readText
import io.ktor.websocket.send
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.math.BigInteger
import java.security.MessageDigest
import java.util.UUID
import java.nio.ByteBuffer

/**
 * Native Edge TTS engine using Ktor — bypasses dart:io WebSocket URL parsing bug on Android.
 * Called from Flutter via MethodChannel "com.podcastgen.podcast_gen/edgetts"
 */
class EdgeTtsEngine {
    private var client: HttpClient? = null
    private var session: DefaultClientWebSocketSession? = null
    private val scope = kotlinx.coroutines.CoroutineScope(Dispatchers.IO + SupervisorJob())

    companion object {
        private const val TAG = "EdgeTtsEngine"
        private const val TRUSTED_CLIENT_TOKEN = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
        private const val WS_URL = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
        private const val CHROME_VERSION = "131.0.0.0"
        private const val CHROME_FULL = "131.0.2903.51"

        // Debug flag — write logs to file so we can read on Android without ADB
        private const val DEBUG = true

        fun genSecMsGec(): String {
            // Ktor formula: unix_s + 10000000 (Windows epoch), rounded to 300s, then * 1e9/100
            var t = System.currentTimeMillis() / 1000.0
            t += 11644473600.0  // Windows epoch offset in seconds
            t -= (t % 300.0)    // Round to 5-minute window
            t = t * 1e9 / 100   // Convert to Windows FILETIME (100-nanosecond intervals)
            val s = ("%d$TRUSTED_CLIENT_TOKEN").format(t.toLong()).toByteArray(Charsets.US_ASCII)
            val digest = MessageDigest.getInstance("SHA-256").digest(s)
            return BigInteger(1, digest).toString(16).uppercase()
        }

        fun newUUID(): String = UUID.randomUUID().toString().replace("-", "")

        private fun datetime2String(): String {
            val now = java.time.ZonedDateTime.now(java.time.ZoneOffset.UTC)
            val formatter = java.time.format.DateTimeFormatter.ofPattern(
                "EEE MMM dd yyyy HH:mm:ss 'GMT+0000' '(Coordinated Universal Time)'",
                java.util.Locale.ENGLISH
            )
            return now.format(formatter)
        }

        private fun log(msg: String) {
            if (DEBUG) {
                android.util.Log.d(TAG, msg)
                try {
                    val f = File("/data/data/com.podcastgen.podcast_gen/cache/edge_tts_log.txt")
                    FileOutputStream(f, true).use { it.write(("[$TAG] ${java.text.SimpleDateFormat("HH:mm:ss.SSS").format(java.util.Date())} $msg\n").toByteArray()) }
                } catch (_: Exception) {}
            }
        }
    }

    suspend fun synthesize(
        text: String,
        voice: String,
        rate: String,
        pitch: String,
        volume: String,
        outputFormat: String
    ): ByteArray? = withContext(Dispatchers.IO) {
        var errorMsg = "unknown"
        try {
            log("=== synthesize START ===")
            log("text=$text")
            log("voice=$voice rate=$rate pitch=$pitch vol=$volume")

            client = HttpClient(CIO) {
                install(WebSockets) {
                    pingIntervalMillis = 20_000L
                }
            }

            val url = buildUrl()
            log("URL=$url")

            session = client!!.webSocketSession {
                url(url)
                header("Pragma", "no-cache")
                header("Cache-Control", "no-cache")
                header(
                    "User-Agent",
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$CHROME_VERSION Safari/537.36 Edg/$CHROME_VERSION"
                )
                header("Origin", "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold")
                header("Accept-Encoding", "gzip, deflate, br")
                header("Accept-Language", "en-US,en;q=0.9")
            }

            log("WebSocket session opened")

            val speechConfig = buildSpeechConfig(outputFormat)
            val ssml = buildSSML(text, voice, rate, pitch, volume)

            log("Sending speech.config (${speechConfig.length} chars)")
            session!!.send(Frame.Text(speechConfig))
            delay(100)
            log("Sending SSML (${ssml.length} chars)")
            session!!.send(Frame.Text(ssml))

            val audioChunks = mutableListOf<Byte>()
            var frameCount = 0
            var turnEndSeen = false

            log("Starting receive loop...")
            for (frame in session!!.incoming) {
                frameCount++
                when (frame) {
                    is Frame.Text -> {
                        val data = frame.readText()
                        log("Frame[$frameCount] TEXT: ${data.take(100)}")
                        if (data.contains("Path:turn.end")) {
                            log("Got turn.end — breaking")
                            turnEndSeen = true
                            break
                        }
                    }
                    is Frame.Binary -> {
                        val data = frame.readBytes()
                        log("Frame[$frameCount] BINARY: ${data.size} bytes, first bytes=${data.take(8).joinToString()}")
                        // Audio data starts at byte 2 (skip 2-byte header)
                        if (data.size > 2) {
                            val audio = data.sliceArray(2 until data.size)
                            audioChunks.addAll(audio.toList())
                            log("  → added ${audio.size} audio bytes, total so far: ${audioChunks.size}")
                        }
                    }
                    is Frame.Close -> {
                        log("Frame[$frameCount] CLOSE: ${frame.readReason()?.message}")
                        break
                    }
                    else -> {
                        log("Frame[$frameCount] OTHER: ${frame::class.simpleName}")
                    }
                }
            }

            log("Receive loop done. frames=$frameCount turnEnd=$turnEndSeen audioBytes=${audioChunks.size}")

            session!!.close()
            client!!.close()

            if (audioChunks.isEmpty()) {
                errorMsg = "No audio chunks collected"
                null
            } else {
                audioChunks.toByteArray()
            }

        } catch (e: Exception) {
            errorMsg = e.message ?: "exception"
            log("!!! EXCEPTION: $errorMsg")
            e.printStackTrace()
            try {
                scope.launch { session?.close() }
                client?.close()
            } catch (_: Exception) {}
            null
        } finally {
            log("=== synthesize END (errorMsg=$errorMsg) ===")
        }
    }

    private fun buildUrl(): String {
        return String.format(
            "%s?TrustedClientToken=%s&Sec-MS-GEC=%s&Sec-MS-GEC-Version=1-%s&ConnectionId=%s",
            WS_URL, TRUSTED_CLIENT_TOKEN, genSecMsGec(), CHROME_FULL, newUUID()
        )
    }

    private fun buildSpeechConfig(outputFormat: String): String {
        val timestamp = datetime2String()
        return """
            X-Timestamp:$timestamp
            Content-Type:application/json; charset=utf-8
            Path:speech.config
            
            {"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"$outputFormat"}}}}
        """.trimIndent().replace("\n", "\r\n")
    }

    private fun buildSSML(text: String, voice: String, rate: String, pitch: String, volume: String): String {
        val timestamp = datetime2String()
        val escaped = text
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;")
            .replace("'", "&apos;")
        return """
            X-RequestId:${newUUID()}
            Content-Type:application/ssml+xml
            X-Timestamp:$timestamp
            Path:ssml
            
            <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="en-US"><voice name="$voice"><prosody pitch="$pitch" rate="$rate" volume="$volume">$escaped</prosody></voice></speak>
        """.trimIndent().replace("\n", "\r\n")
    }

    fun close() {
        try {
            scope.launch { session?.close() }
            client?.close()
        } catch (_: Exception) {}
        scope.cancel()
    }
}
