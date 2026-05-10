#!/usr/bin/env python3
"""
Test Edge TTS using yynag's EXACT parameters:
- Ktor-style URL (no Sec-MS-GEC-Version)
- SHA256 of (rounded_t * 1e9/100 + token)
- Binary frame parsing: data[2:]
"""
import asyncio
import websockets
import json
import hashlib
import struct
import time
from datetime import datetime, timezone
from urllib.parse import urlencode

TRUSTED_CLIENT_TOKEN = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
WS_URL = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
CHROME_FULL = "131.0.2903.51"

def datetime2string():
    now = datetime.now(timezone.utc)
    return now.strftime("%a %b %d %Y %H:%M:%S GMT+0000 (Coordinated Universal Time)")

def gen_sec_ms_gec():
    """yynag's exact Ktor formula"""
    t = time.time()
    t += 11644473600  # Windows epoch offset in seconds
    t -= (t % 300)    # Round to 5-minute window
    t = t * 1e9 / 100  # Convert to Windows FILETIME
    s = "%d%s" % (int(t), TRUSTED_CLIENT_TOKEN)
    digest = hashlib.sha256(s.encode('ascii')).digest()
    return format(int.from_bytes(digest, 'big'), 'x').upper()

def new_uuid():
    import uuid
    return uuid.uuid4().hex

def build_url():
    conn_id = new_uuid()
    sec_gec = gen_sec_ms_gec()
    return (f"{WS_URL}"
            f"?TrustedClientToken={TRUSTED_CLIENT_TOKEN}"
            f"&Sec-MS-GEC={sec_gec}"
            f"&Sec-MS-GEC-Version=1-{CHROME_FULL}"
            f"&ConnectionId={conn_id}")

def build_speech_config():
    ts = datetime2string()
    return (
        f"X-Timestamp:{ts}\r\n"
        f"Content-Type:application/json; charset=utf-8\r\n"
        f"Path:speech.config\r\n\r\n"
        '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}'
    )

def build_ssml(text, voice, rate="+0%", pitch="+0Hz", volume="+0%"):
    ts = datetime2string()
    # Escape XML
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;").replace("'", "&apos;")
    return (
        f"X-RequestId:{new_uuid()}\r\n"
        f"Content-Type:application/ssml+xml\r\n"
        f"X-Timestamp:{ts}\r\n"
        f"Path:ssml\r\n\r\n"
        f"<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='{voice}'><prosody pitch='{pitch}' rate='{rate}' volume='{volume}'>{text}</prosody></voice></speak>"
    )

async def test():
    url = build_url()
    print(f"URL: {url}")

    headers = [
        "Pragma: no-cache",
        "Cache-Control: no-cache",
        "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0",
        "Origin: chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
        "Accept-Encoding: gzip, deflate, br",
        "Accept-Language: en-US,en;q=0.9",
    ]

    try:
        async with websockets.connect(url, extra_headers=headers) as ws:
            print("Connected!")

            # Send speech config
            speech = build_speech_config()
            print(f"Sending speech.config ({len(speech)} chars)")
            await ws.send(speech)
            await asyncio.sleep(0.1)

            # Send SSML
            ssml = build_ssml("Hello world, this is a test.", "en-US-AriaNeural")
            print(f"Sending SSML ({len(ssml)} chars)")
            await ws.send(ssml)

            # Receive
            audio_chunks = []
            frame_count = 0
            async for msg in ws:
                frame_count += 1
                if isinstance(msg, str):
                    print(f"Frame[{frame_count}] TEXT: {msg[:100]}")
                    if "turn.end" in msg:
                        print("Got turn.end — done")
                        break
                elif isinstance(msg, bytes):
                    print(f"Frame[{frame_count}] BINARY: {len(msg)} bytes")
                    if len(msg) > 2:
                        audio = msg[2:]  # yynag's exact: skip first 2 bytes
                        audio_chunks.extend(audio)
                        print(f"  → accumulated {len(audio_chunks)} audio bytes")
            print(f"\nTotal: {len(audio_chunks)} bytes, {frame_count} frames")
            if audio_chunks:
                with open("/tmp/test_yynag.mp3", "wb") as f:
                    f.write(bytes(audio_chunks))
                print("Saved to /tmp/test_yynag.mp3")
            else:
                print("NO AUDIO!")

    except Exception as e:
        import traceback
        print(f"ERROR: {e}")
        traceback.print_exc()
        print(f"ERROR type: {type(e).__name__}")

if __name__ == "__main__":
    asyncio.run(test())
