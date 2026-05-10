package com.podcastgen.podcast_gen

import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.websocket.webSocketSession
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.header
import io.ktor.client.request.url
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.readBytes
import io.ktor.websocket.readText
import io.ktor.websocket.send
import kotlinx.coroutines.*
import java.math.BigInteger
import java.security.MessageDigest
import java.util.UUID

/**
 * Native Edge TTS engine using Ktor — bypasses dart:io WebSocket URL parsing bug on Android.
 * Called from Flutter via MethodChannel "com.podcastgen.podcast_gen/edgetts"
 */
class EdgeTtsEngine {
    private var client: HttpClient? = null
    private var session: io.ktor.client.plugins.websocket.DefaultClientWebSocketSession? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    companion object {
        private const val TRUSTED_CLIENT_TOKEN = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
        private const val WS_URL = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
        private const val CHROME_VERSION = "131.0.0.0"
        private const val CHROME_FULL = "131.0.2903.51"

        fun genSecMsGec(): String {
            // Same algorithm as yynag/edge-tts-android
            var t = System.currentTimeMillis() / 1000.0
            t += 11644473600.0  // Windows epoch offset in seconds
            t -= (t % 300.0)
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
    }

    suspend fun synthesize(
        text: String,
        voice: String,
        rate: String,
        pitch: String,
        volume: String,
        outputFormat: String
    ): ByteArray? = withContext(Dispatchers.IO) {
        try {
            client = HttpClient(CIO) {
                install(io.ktor.client.plugins.websocket.WebSockets) {
                    pingIntervalMillis = 20_000L
                }
            }

            val url = buildUrl()
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

            val speechConfig = buildSpeechConfig(outputFormat)
            val ssml = buildSSML(text, voice, rate, pitch, volume)

            session!!.send(speechConfig)
            delay(50)
            session!!.send(ssml)

            val audioChunks = mutableListOf<Byte>()

            for (frame in session!!.incoming) {
                when (frame) {
                    is Frame.Text -> {
                        val data = frame.readText()
                        if (data.contains("Path:turn.end")) {
                            break
                        }
                    }
                    is Frame.Binary -> {
                        val data = frame.readBytes()
                        // Audio data starts at byte 2 (skip 2-byte header)
                        if (data.size > 2) {
                            for (i in 2 until data.size) {
                                audioChunks.add(data[i])
                            }
                        }
                    }
                    is Frame.Close -> {
                        break
                    }
                    else -> {}
                }
            }

            session!!.close()
            client!!.close()

            if (audioChunks.isEmpty()) null else audioChunks.toByteArray()

        } catch (e: Exception) {
            e.printStackTrace()
            try {
                scope.launch { session?.close() }
                client?.close()
            } catch (_: Exception) {}
            null
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
        scope.cancel()
        try {
            scope.launch { session?.close() }
            client?.close()
        } catch (_: Exception) {}
    }
}
