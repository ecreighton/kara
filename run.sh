#!/usr/bin/env bash
# Processes every audio file in /data/in.
# Layout on the mounted Azure file share:
#   /data/in/      <- you upload songs here (optionally "<same name>.txt" with lyrics)
#   /data/out/     <- per song: instrumental + vocal stems, lyrics, karaoke MP4
#   /data/models/  <- model weights cached here so later runs skip the download
#
# Stage 1 (separation) runs once per song.
# Stage 2 (lyrics + video) runs when there's no video yet, or when you upload a
# newer .txt for the song -- that's how you fix wrong lyrics and re-render.
set -uo pipefail

IN=/data/in
OUT=/data/out
MODELS=/data/models
# Strong default for vocals/instrumental. Run `audio-separator --list_models` to see others.
MODEL="${MODEL:-model_bs_roformer_ep_317_sdr_12.9755.ckpt}"

mkdir -p "$IN" "$OUT" "$MODELS"
shopt -s nullglob nocaseglob

for f in "$IN"/*.{flac,wav,mp3,m4a,ogg}; do
  name="$(basename "${f%.*}")"
  dest="$OUT/$name"
  txt="$IN/$name.txt"
  mp4="$dest/$name (Karaoke).mp4"

  # ---- stage 1: separation
  vocals=( "$dest"/*"(Vocals)"*.flac )
  if (( ${#vocals[@]} == 0 )); then
    echo "== separating: $name"
    mkdir -p "$dest"
    # Write stems to local disk first, then copy to the share: the Azure file share
    # doesn't allow the permission changes the separator makes while saving.
    work="$(mktemp -d)"
    if ! audio-separator "$f" \
        --model_filename "$MODEL" \
        --model_file_dir "$MODELS" \
        --output_dir "$work" \
        --output_format FLAC; then
      echo "!! separation failed: $name"; rm -rf "$work"; continue
    fi
    cp "$work"/* "$dest"/ && rm -rf "$work"
    vocals=( "$dest"/*"(Vocals)"*.flac )
  fi
  inst=( "$dest"/*"(Instrumental)"*.flac )
  if (( ${#vocals[@]} == 0 || ${#inst[@]} == 0 )); then
    echo "!! stems missing for $name"; continue
  fi

  # ---- stage 2: lyrics + karaoke video
  # Re-render when: no video yet, a newer .txt was uploaded, or the video settings changed.
  settings="guide=${GUIDE_VOCAL:-0.15}"
  marker="$dest/.render-settings"
  if [[ -f "$mp4" && ! ( -f "$txt" && "$txt" -nt "$mp4" ) \
        && "$(cat "$marker" 2>/dev/null)" == "$settings" ]]; then
    echo "== skip (video done): $name"; continue
  fi
  echo "== lyrics + video: $name ($settings)"
  if python3 /app/lyrics.py --song "$f" --vocals "${vocals[0]}" --instrumental "${inst[0]}" \
      --outdir "$dest" --lyrics-file "$txt"; then
    echo "$settings" > "$marker"
  else
    echo "!! lyrics/video failed: $name"
  fi
done

echo "== all done"
