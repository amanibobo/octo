"""Kokoro-82M text-to-speech on Modal: a natural neural voice with no API key.

    cd services && modal deploy modal_tts.py
    curl -X POST <url>/tts -H 'content-type: application/json' -d '{"text":"hello there"}' -o out.wav

Kokoro is an Apache-2.0 model (hexgrad/Kokoro-82M). The weights are fetched at
image build time so a warm container answers a sentence in well under a second
on 4 CPUs (GPU needs a payment method on Modal); `min_containers=1` keeps one warm during the expo.
"""

import modal

DEFAULT_VOICE = "af_heart"  # warm American-English female voice; "am_michael" for male

image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("espeak-ng", "libsndfile1")
    .pip_install("kokoro>=0.9.4", "soundfile", "numpy", "fastapi", "torch", "misaki[en]")
    .run_commands("python -c \"from kokoro import KPipeline; KPipeline(lang_code='a', repo_id='hexgrad/Kokoro-82M')\"")
)

app = modal.App("sounder-tts", image=image)


@app.cls(cpu=4.0, memory=4096, min_containers=1, scaledown_window=600, timeout=60)
class KokoroSpeaker:
    @modal.enter()
    def load(self):
        from kokoro import KPipeline

        self.pipeline = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")
        # Warm the graph once so the first real request is fast.
        for _ in self.pipeline("ready.", voice=DEFAULT_VOICE):
            pass

    @modal.fastapi_endpoint(method="POST")
    def tts(self, body: dict):
        import io
        import numpy as np
        import soundfile
        from fastapi import Response

        text = (body.get("text") or "").strip()
        if not text:
            return Response(content=b"", status_code=400)
        voice = body.get("voice") or DEFAULT_VOICE
        speed = float(body.get("speed") or 1.05)

        chunks = [audio for _, _, audio in self.pipeline(text, voice=voice, speed=speed)]
        if not chunks:
            return Response(content=b"", status_code=422)
        samples = np.concatenate([np.asarray(chunk, dtype=np.float32) for chunk in chunks])

        buffer = io.BytesIO()
        soundfile.write(buffer, samples, 24000, format="WAV", subtype="PCM_16")
        return Response(content=buffer.getvalue(), media_type="audio/wav")

    @modal.fastapi_endpoint(method="GET")
    def health(self):
        return {"ok": True, "service": "sounder-tts", "voice": DEFAULT_VOICE}
