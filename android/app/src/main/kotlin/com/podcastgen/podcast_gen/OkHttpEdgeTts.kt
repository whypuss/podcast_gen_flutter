package com.podcastgen.podcast_gen

import android.content.Context
import android.util.Log
import okhttp3.*
import okio.ByteString
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Edge TTS WebSocket implementation using OkHttp.
 * Tries multiple TLS/connection strategies to get Chrome-like fingerprint.
 */
class OkHttpEdgeTts(private val context: Context) {

    companion object {
        private const val TAG = "OkHttpEdgeTts"

        // Real 32-char token (NOT redacted)
        private const val TRUSTED_CLIENT_TOKEN = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"

        private const val WSS_URL_BASE = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
        private const val CHROME_FULL = "143.0.3650.75"
        private const val CHROME_MAJOR = "143"
        private const val SYNTH_TIMEOUT_MS = 30000L

        // Windows epoch (1601-01-01) in seconds
        private const val WIN_EPOCH_SEC = 11644473600.0
        // 100-nanosecond intervals per second
        private const val SEC_TO_100NS = 10_000_000.0
        // 5 minutes in 100ns intervals
        private const val FIVE_MIN_100NS = 5 * 60 * SEC_TO_100NS  // 3_000_000_000

        // Chrome TLS 1.3 cipher suites (in preferred order)
        private val TLS_1_3_CIPHERS = listOf(
            "TLS_AES_128_GCM_SHA256",
            "TLS_AES_256_GCM_SHA384",
            "TLS_CHACHA20_POLY1305_SHA256"
        )

        // Chrome TLS 1.2 cipher suites
        private val TLS_1_2_CIPHERS = listOf(
            "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
            "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
            "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
            "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
            "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
            "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
            "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA",
            "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA",
            "TLS_RSA_WITH_AES_128_GCM_SHA256",
            "TLS_RSA_WITH_AES_256_GCM_SHA384"
        )
    }

    // Build client with Chrome-like TLS cipher suites
    // Strategy 1: Try with TLS 1.3 first, then fall back
    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .connectTimeout(15, TimeUnit.SECONDS)
            .protocols(listOf(Protocol.HTTP_1_1))
            // Use the default TLS config — Conscrypt on Android has Chrome-like cipher suite order
            .build()
    }

    private var webSocket: WebSocket? = null
    private val isConnected = AtomicBoolean(false)
    private val rng = SecureRandom()

    /**
     * Synthesize text to audio bytes using Edge TTS.
     * Returns MP3 audio bytes on success, null on failure.
     */
    fun synthesize(
        text: String,
        voice: String,
        rate: String,
        pitch: String,
        volume: String,
        outputFormat: String
    ): ByteArray? {
        log("synthesize START: text_len=${text.length} voice=$voice")

        val secMsGec = generateSecMsGec()
        val muid = generateMuid()
        val connectionId = generateConnectionId()

        // Full WebSocket URL with ALL parameters (Sec-MS-GEC is in URL, not header)
        val fullUrl = (
            "${WSS_URL_BASE}" +
            "?TrustedClientToken=$TRUSTED_CLIENT_TOKEN" +
            "&ConnectionId=$connectionId" +
            "&Sec-MS-GEC=$secMsGec" +
            "&Sec-MS-GEC-Version=1-$CHROME_FULL"
        )

        // Headers matching rany2/edge-tts WSS_HEADERS + BASE_HEADERS
        val request = Request.Builder()
            .url(fullUrl)
            .addHeader("Pragma", "no-cache")
            .addHeader("Cache-Control", "no-cache")
            .addHeader("Origin", "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold")
            .addHeader("Sec-WebSocket-Version", "13")
            .addHeader(
                "User-Agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/$CHROME_MAJOR.0.0.0 Safari/537.36 Edg/$CHROME_MAJOR.0.0.0"
            )
            .addHeader("Accept-Encoding", "gzip, deflate, br, zstd")
            .addHeader("Accept-Language", "en-US,en;q=0.9")
            .addHeader("Cookie", "muid=$muid;")
            .build()

        // SSML matching rany2/edge-tts mkssml() + ssml_headers_plus_data()
        val ssml = buildSsmlMessage(text, voice, rate, pitch, volume)
        // Config message matching rany2/edge-tts __stream() send_command_request
        val config = buildConfigMessage()

        log("URL: $fullUrl")
        log("Sec-MS-GEC: $secMsGec")
        log("muid: $muid")
        log("connectionId: $connectionId")

        val doneLatch = CountDownLatch(1)
        val audioData = mutableListOf<ByteArray>()
        var errorMsg: String? = null

        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                log("WebSocket OPEN")
                isConnected.set(true)

                // Send speech.config (MUST be first, before SSML)
                webSocket.send(config)
                log("Sent config (${config.length} chars)")

                // Send SSML
                webSocket.send(ssml)
                log("Sent SSML (${ssml.length} chars)")
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                val headerEnd = text.indexOf("\r\n\r\n")
                val headers = if (headerEnd >= 0) text.substring(0, headerEnd) else text
                val body = if (headerEnd >= 0) text.substring(headerEnd + 4) else ""

                val pathMatch = Regex("Path:([^\r\n]+)").find(headers)
                val path = pathMatch?.groupValues?.get(1) ?: "unknown"
                val requestId = Regex("X-RequestId:([^\r\n]+)").find(headers)?.groupValues?.get(1) ?: "?"

                log("TEXT ($path) ReqId=$requestId body(${body.length}): ${body.take(300)}")

                if (text.contains("turn.end")) {
                    log("==> turn.end — stream complete")
                    doneLatch.countDown()
                }
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                val data = bytes.toByteArray()
                // Binary format: first 2 bytes = header length (big-endian)
                if (data.size < 2) {
                    log("Binary msg too short: ${data.size} bytes")
                    return
                }

                val headerLen = (data[0].toInt() and 0xFF) * 256 + (data[1].toInt() and 0xFF)
                if (headerLen >= data.size) {
                    log("Invalid headerLen=$headerLen dataLen=${data.size}")
                    return
                }

                // Parse headers: each line is "Key:Value\r\n"
                val headerSection = data.copyOfRange(0, headerLen)
                val headers = mutableMapOf<String, String>()
                for (line in headerSection.toString(Charsets.UTF_8).split("\r\n")) {
                    val colonIdx = line.indexOf(':')
                    if (colonIdx > 0) {
                        headers[line.substring(0, colonIdx)] = line.substring(colonIdx + 1)
                    }
                }

                val path = headers["Path"]
                val audioStart = 2 + headerLen
                val payload = data.copyOfRange(audioStart, data.size)

                when (path) {
                    "audio" -> {
                        val contentType = headers["Content-Type"]
                        if (payload.isNotEmpty() && contentType?.startsWith("audio/") == true) {
                            synchronized(audioData) {
                                audioData.add(payload)
                            }
                            log("Audio chunk: ${payload.size} bytes (total chunks: ${audioData.size})")
                        }
                    }
                    "audio.metadata" -> {
                        log("Metadata: ${String(payload, Charsets.UTF_8).take(80)}")
                    }
                    "turn.start" -> log("turn.start")
                    "response" -> log("response")
                    else -> log("Unknown path: $path")
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                errorMsg = t.message ?: "Unknown"
                log("!!! onFailure: $errorMsg")
                if (response != null) {
                    log("Response code: ${response.code} ${response.message}")
                    try {
                        log("Body: ${response.body?.string()?.take(200)}")
                    } catch (_: Exception) {}
                }
                isConnected.set(false)
                doneLatch.countDown()
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                log("CLOSED: code=$code reason=$reason")
                isConnected.set(false)
                doneLatch.countDown()
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                log("onClosing: $code $reason")
                webSocket.close(code, reason)
            }
        }

        try {
            webSocket = client.newWebSocket(request, listener)

            val waited = doneLatch.await(SYNTH_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            if (!waited) {
                log("!!! TIMEOUT after ${SYNTH_TIMEOUT_MS}ms")
                webSocket?.close(1000, "Timeout")
                return null
            }

            if (errorMsg != null) {
                log("!!! FAILED: $errorMsg")
                return null
            }

            if (audioData.isEmpty()) {
                log("!!! No audio data received")
                return null
            }

            val totalSize = audioData.sumOf { it.size }
            log("Concatenating ${audioData.size} chunks, total=$totalSize bytes")

            val result = ByteArray(totalSize)
            var offset = 0
            for (chunk in audioData) {
                chunk.copyInto(result, offset)
                offset += chunk.size
            }

            log("Audio ready: ${result.size} bytes")
            return result

        } catch (e: Exception) {
            log("!!! Exception: ${e.message}")
            e.printStackTrace()
            return null
        }
    }

    fun close() {
        try {
            webSocket?.close(1000, "Closing")
            webSocket = null
        } catch (_: Exception) {}
    }

    // ─── Sec-MS-GEC (mirrors rany2/edge-tts drm.py generate_sec_ms_gec) ───────

    /**
     * Generates the Sec-MS-GEC token.
     * Algorithm (Python equivalent):
     *   ticks = unix_time_sec + 11644473600
     *   ticks -= ticks % 300  # floor to 5 min
     *   ticks_100ns = ticks * 10_000_000
     *   hash = SHA256(f"{ticks_100ns:.0f}{TRUSTED_CLIENT_TOKEN}")
     *   return hash.upper()
     */
    private fun generateSecMsGec(): String {
        return try {
            // Unix time in SECONDS (float, like Python time.time())
            val unixSec = System.currentTimeMillis() / 1000.0

            // Convert to Windows file time (100ns intervals since 1601-01-01)
            val windowsFileTime = (unixSec + WIN_EPOCH_SEC) * SEC_TO_100NS

            // Floor to nearest 5 minutes (300 seconds)
            val fiveMinIntervals = (windowsFileTime / FIVE_MIN_100NS).toLong() * FIVE_MIN_100NS

            // String to hash: integer string (no decimal) + token (NO separator!)
            val strToHash = "${fiveMinIntervals.toLong()}$TRUSTED_CLIENT_TOKEN"

            val digest = MessageDigest.getInstance("SHA-256")
            val hash = digest.digest(strToHash.toByteArray(Charsets.UTF_8))
            hash.joinToString("") { "%02X".format(it) }
        } catch (e: Exception) {
            Log.e(TAG, "Sec-MS-GEC failed: ${e.message}")
            ""
        }
    }

    // ─── IDs (mirrors rany2/edge-tts) ────────────────────────────────────────

    /**
     * Generates a connection ID — 32 lowercase hex chars, no dashes.
     * Python: uuid.uuid4().hex (32 chars)
     */
    private fun generateConnectionId(): String {
        return java.util.UUID.randomUUID().toString().replace("-", "")
    }

    /**
     * Generates muid — 32 uppercase hex chars.
     * Python: secrets.token_hex(16).upper() (32 chars uppercase)
     */
    private fun generateMuid(): String {
        val bytes = ByteArray(16)
        rng.nextBytes(bytes)
        return bytes.joinToString("") { "%02X".format(it) }
    }

    // ─── Messages matching rany2/edge-tts exactly ──────────────────────────────

    /**
     * Builds the speech.config message.
     * Must be sent BEFORE SSML — matches rany2/edge-tts __stream() send_command_request().
     */
    private fun buildConfigMessage(): String {
        val timestamp = dateToString()
        return (
            "X-Timestamp:$timestamp\r\n" +
            "Content-Type:application/json; charset=utf-8\r\n" +
            "Path:speech.config\r\n\r\n" +
            "{" +
            "\"context\":{" +
            "\"synthesis\":{" +
            "\"audio\":{" +
            "\"metadataoptions\":{" +
            "\"sentenceBoundaryEnabled\":\"true\"," +
            "\"wordBoundaryEnabled\":\"false\"" +
            "}," +
            "\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"" +
            "}}" +
            "}" +
            "}\r\n"
        )
    }

    /**
     * Builds the SSML message with headers.
     * Matches rany2/edge-tts ssml_headers_plus_data() + mkssml().
     * NOTE: X-Timestamp has 'Z' suffix — this is intentional (Microsoft Edge bug).
     */
    private fun buildSsmlMessage(text: String, voice: String, rate: String, pitch: String, volume: String): String {
        // Note: Python's ssml_headers_plus_data adds 'Z' suffix to timestamp:
        // f"X-Timestamp:{timestamp}Z\r\n" — this is the Microsoft Edge bug
        val timestamp = dateToString() + "Z"
        val requestId = generateConnectionId()
        val ssml = buildSsml(text, voice, rate, pitch, volume)

        return (
            "X-RequestId:$requestId\r\n" +
            "Content-Type:application/ssml+xml\r\n" +
            "X-Timestamp:$timestamp\r\n" +
            "Path:ssml\r\n\r\n" +
            ssml
        )
    }

    /**
     * Builds SSML — matches rany2/edge-tts mkssml() EXACTLY.
     * Rate/pitch/volume passed AS-IS (no re-parsing/reformatting).
     */
    private fun buildSsml(text: String, voice: String, rate: String, pitch: String, volume: String): String {
        // Python mkssml does direct string interpolation, no transformation
        return (
            "<speak version='1.0' " +
            "xmlns='http://www.w3.org/2001/10/synthesis' " +
            "xml:lang='en-US'>" +
            "<voice name='$voice'>" +
            "<prosody pitch='$pitch' rate='$rate' volume='$volume'>" +
            "$text" +
            "</prosody>" +
            "</voice>" +
            "</speak>"
        )
    }

    /**
     * Returns a JavaScript-style date string.
     * Matches rany2/edge-tts date_to_string().
     */
    private fun dateToString(): String {
        val gmt = java.util.GregorianCalendar(java.util.TimeZone.getTimeZone("UTC"))
        val f = java.text.SimpleDateFormat("EEE MMM dd yyyy HH:mm:ss", java.util.Locale.US)
        f.timeZone = java.util.TimeZone.getTimeZone("UTC")
        return f.format(gmt.time) + " GMT+0000 (Coordinated Universal Time)"
    }

    private fun log(msg: String) {
        Log.d(TAG, msg)
    }
}
