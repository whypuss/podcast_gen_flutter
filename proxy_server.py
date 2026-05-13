#!/usr/bin/env python3
"""Edge TTS HTTP proxy for Android emulator.
Android app calls POST http://localhost:8898/tts with JSON body,
this script calls edge-tts Python library and returns MP3 audio.
"""
import json
import sys
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Optional
import asyncio
import edge_tts

PORT = 8898

class TTSHandler(BaseHTTPRequestHandler):
    async def _synthesize(self, text: str, voice: str, rate: str, pitch: str, volume: str) -> Optional[bytes]:
        try:
            communicate = edge_tts.Communicate(
                text,
                voice=voice,
                rate=rate,
                pitch=pitch,
                volume=volume,
            )
            mp3_data = b""
            async for chunk in communicate.stream():
                if chunk["type"] == "audio":
                    mp3_data += chunk["data"]
            return mp3_data if mp3_data else None
        except Exception as e:
            print(f"[TTSProxy] edge-tts error: {e}", file=sys.stderr)
            return None

    def do_POST(self):
        if self.path != "/tts":
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"Not found")
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            data = json.loads(body)
            text = data.get("text", "")
            voice = data.get("voice", "zh-CN-XiaoxiaoNeural")
            rate = data.get("rate", "+0%")
            pitch = data.get("pitch", "+0Hz")
            volume = data.get("volume", "+0%")

            if not text:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"Missing text")
                return

            print(f"[TTSProxy] Synthesizing: voice={voice} rate={rate} pitch={pitch} text={text[:30]}...", file=sys.stderr)

            audio = asyncio.run(self._synthesize(text, voice, rate, pitch, volume))

            if audio:
                self.send_response(200)
                self.send_header("Content-Type", "audio/mpeg")
                self.send_header("Content-Length", str(len(audio)))
                self.end_headers()
                self.wfile.write(audio)
                print(f"[TTSProxy] Success: {len(audio)} bytes", file=sys.stderr)
            else:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(b"TTS synthesis failed")

        except Exception as e:
            print(f"[TTSProxy] Error: {e}", file=sys.stderr)
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"Edge TTS Proxy running. POST /tts with JSON body.")

    def log_message(self, format, *args):
        pass  # Suppress default logging

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), TTSHandler)
    print(f"[TTSProxy] Starting on http://0.0.0.0:{PORT}", file=sys.stderr)
    sys.stderr.flush()
    server.serve_forever()
