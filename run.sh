#!/usr/bin/env bash
# Processes every audio file in /data/in that hasn't been done yet.
# Layout on the mounted Azure file share:
#   /data/in/      <- you upload songs here
#   /data/out/     <- instrumental + vocal stems land here (one folder per song)
#   /data/models/  <- model weights cached here so later runs skip the download
set -euo pipefail

IN=/data/in
OUT=/data/out
MODELS=/data/models
# Strong default for vocals/instrumental. Run `audio-separator --list_models` to see others
# (e.g. a MelBand "karaoke" model that removes only the lead vocal, keeping backing vocals).
MODEL="${MODEL:-model_bs_roformer_ep_317_sdr_12.9755.ckpt}"

mkdir -p "$IN" "$OUT" "$MODELS"
shopt -s nullglob nocaseglob

count=0
for f in "$IN"/*.{flac,wav,mp3,m4a,ogg}; do
  name="$(basename "${f%.*}")"
  dest="$OUT/$name"
  if [[ -d "$dest" ]]; then
    echo "skip (already done): $name"
    continue
  fi
  echo "separating: $name"
  mkdir -p "$dest"
  audio-separator "$f" \
    --model_filename "$MODEL" \
    --model_file_dir "$MODELS" \
    --output_dir "$dest" \
    --output_format FLAC
  count=$((count + 1))
done

echo "done: $count new song(s)"
