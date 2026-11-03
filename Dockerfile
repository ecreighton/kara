# Ships its own CUDA 12 runtime, so the platform's driver/CUDA upgrades won't break it.
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# audio-separator = the UVR model engine as a CLI/library (MDX, Demucs, Roformer models)
RUN pip3 install --no-cache-dir "audio-separator[gpu]"

COPY run.sh /app/run.sh
# Strip Windows line endings in case the file was edited on Windows
RUN sed -i 's/\r$//' /app/run.sh && chmod +x /app/run.sh

ENTRYPOINT ["/app/run.sh"]
