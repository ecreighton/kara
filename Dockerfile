# Ships its own CUDA 12 runtime, so the platform's driver/CUDA upgrades won't break it.
# Runs on CPU too (falls back automatically when no GPU is present).
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1

# ffmpeg (with libass for burning lyrics into video) + a font for the lyrics
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip ffmpeg fonts-dejavu-core ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# audio-separator = the UVR model engine (MDX, Demucs, Roformer models)
# stable-ts       = Whisper with accurate word timing / lyric alignment
RUN pip3 install --no-cache-dir "audio-separator[gpu]" stable-ts

COPY run.sh lyrics.py /app/
# Strip Windows line endings in case the files were edited on Windows
RUN sed -i 's/\r$//' /app/run.sh /app/lyrics.py && chmod +x /app/run.sh

ENTRYPOINT ["/app/run.sh"]
