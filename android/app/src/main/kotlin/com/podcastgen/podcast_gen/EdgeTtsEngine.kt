package com.podcastgen.podcast_gen

import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.websocket.DefaultClientWebSocketSession
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.plugins.websocket.webSocketSession
import io.ktor.client.request.header
import io.ktor.client.request.url
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.readBytes
import io.ktor.websocket.readReason
import io.ktor.websocket.readText
import io.ktor.websocket.send
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.File
import java.io.FileOutputStream
import java.math.BigInteger
import java.security.MessageDigest
import java.util.UUID

/**
 * Native Edge TTS engine using Ktor — bypasses dart:io WebSocket URL parsing bug on Android.
 * Uses test_ws4.py's EXACT parameters (verified working on Mac aiohttp).
 */
class EdgeTtsEngine {
    private var client: HttpClient? = null
    private var session: DefaultClientWebSocketSession? = null
    private val scope = kotlinx.coroutines.CoroutineScope(Dispatchers.IO + SupervisorJob())

    companion object {
        private const val TAG = "EdgeTtsEngine"
        private const val TRUSTED_CLIENT_TOKEN = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
        private const val WS_URL = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4"
        private const val CHROME_MAJOR = "143"
        private const val CHROME_FULL = "143.0.3650.75"
        private const val WIN_EPOCH_OFFSET = 11644473600000L  // ms
        private const val CONNECT_TIMEOUT_MS = 15000L
        private const val SYNTHESIS_TIMEOUT_MS = 30000L

        // test_ws4.py's EXACT formula (verified working)
        fun genSecMsGec(): String {
            val unixMs = System.currentTimeMillis()
            val winTicks = (unixMs + WIN_EPOCH_OFFSET) * 10000
            val rounded = (winTicks / 3000000000) * 3000000000
            val s = "$rounded$TRUSTED_CLIENT_TOKEN"
            val digest = MessageDigest.getInstance("SHA-256").digest(s.toByteArray(Charsets.UTF_8))
            return digest.joinToString("") { "%02X".format(it) }
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
            android.util.Log.d(TAG, msg)
            try {
                val f = File("/data/data/com.podcastgen.podcast_gen/cache/edge_tts_log.txt")
                FileOutputStream(f, true).use {
                    it.write(("[$TAG] ${java.text.SimpleDateFormat("HH:mm:ss.SSS").format(java.util.Date())} $msg\n").toByteArray())
                }
            } catch (_: Exception) {}
        }
    }

    private fun voiceLocale(voiceShortName: String): String {
        // Extract locale from voice shortName like "zh-CN-XiaoxiaoNeural" → "zh-CN"
        val parts = voiceShortName.split("-")
        return if (parts.size >= 2) "${parts[0]}-${parts[1]}" else "en-US"
    }

    suspend fun synthesize(
        text: String,
        voice: String,
        rate: String,
        pitch: String,
        volume: String,
        outputFormat: String
    ): ByteArray? = withContext(Dispatchers.IO) {
        log("=== synthesize START ===")
        log("text=$text")
        log("voice=$voice rate=$rate pitch=$pitch vol=$volume")

        try {
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
                header("Accept-Encoding", "gzip, deflate, br, zstd")
                header("Accept-Language", "en-US,en;q=0.9")
                header(
                    "User-Agent",
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$CHROME_MAJOR.0.0.0 Safari/537.36 Edg/$CHROME_MAJOR.0.0.0"
                )
                header("Origin", "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold")
                header("Sec-WebSocket-Version", "13")
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

            withTimeout(SYNTHESIS_TIMEOUT_MS) {
                for (frame in session!!.incoming) {
                    frameCount++
                    when (frame) {
                        is Frame.Text -> {
                            val data = frame.readText()
                            log("Frame[$frameCount] TEXT: ${data.take(80)}")
                            if (data.contains("Path:turn.end")) {
                                log("Got turn.end")
                                break
                            }
                        }
                        is Frame.Binary -> {
                            val data = frame.readBytes()
                            log("Frame[$frameCount] BINARY: ${data.size} bytes")
                            if (data.size > 2) {
                                // test_ws4.py: header_len = struct.unpack(">H", data[:2])[0]
                                val headerLen = ((data[0].toInt() and 0xFF) shl 8) or (data[1].toInt() and 0xFF)
                                val audio = data.copyOfRange(2 + headerLen, data.size)
                                audioChunks.addAll(audio.toList())
                                log("  → headerLen=$headerLen audioLen=${audio.size} total=${audioChunks.size}")
                            }
                        }
                        is Frame.Close -> {
                            log("Frame[$frameCount] CLOSE: ${frame.readReason()?.message}")
                            break
                        }
                        else -> {
                            log("Frame[$frameCount] ${frame::class.simpleName}")
                        }
                    }
                }
            }

            log("Receive done. frames=$frameCount audioBytes=${audioChunks.size}")
            session!!.close()
            client!!.close()

            if (audioChunks.isEmpty()) {
                log("!!! ERROR: No audio chunks")
                null
            } else {
                audioChunks.toByteArray()
            }

        } catch (e: TimeoutCancellationException) {
            log("!!! TIMEOUT: ${e.message}")
            try { session?.close(); client?.close() } catch (_: Exception) {}
            null
        } catch (e: Exception) {
            log("!!! ERROR: ${e.message}")
            e.printStackTrace()
            try { session?.close(); client?.close() } catch (_: Exception) {}
            null
        } finally {
            log("=== synthesize END ===")
        }
    }

    private fun buildUrl(): String {
        val connId = newUUID()
        val secGec = genSecMsGec()
        val version = "1-$CHROME_FULL"
        return "$WS_URL&ConnectionId=$connId&Sec-MS-GEC=$secGec&Sec-MS-GEC-Version=$version"
    }

    // FIXED: no leading newline (was trimIndent which kept the leading \n from indentation)
    private fun buildSpeechConfig(outputFormat: String): String {
        val timestamp = datetime2String()
        val reqId = newUUID()
        return "${reqId}\r\n" +
            "Content-Type:application/json; charset=utf-8\r\n" +
            "X-Timestamp:$timestamp\r\n" +
            "Path:speech.config\r\n\r\n" +
            "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"$outputFormat\"}}}}"
    }

    private fun buildSSML(text: String, voice: String, rate: String, pitch: String, volume: String): String {
        val timestamp = datetime2String()
        val reqId = newUUID()
        val locale = voiceLocale(voice)
        val escaped = text
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;")
            .replace("'", "&apos;")
        return "$reqId\r\n" +
            "Content-Type:application/ssml+xml\r\n" +
            "X-Timestamp:$timestamp\r\n" +
            "Path:ssml\r\n\r\n" +
            "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='$locale'><voice name='$voice'><prosody pitch='$pitch' rate='$rate' volume='$volume'>$escaped</prosody></voice></speak>"
    }

    fun close() {
        try {
            scope.launch { session?.close() }
            client?.close()
        } catch (_: Exception) {}
        scope.cancel()
    }
}
