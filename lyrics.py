#!/usr/bin/env python3
"""Lyrics stage: get lyrics, time every word against the isolated vocal stem,
and render a karaoke MP4 (instrumental audio, words highlight as they're sung).

Lyrics source, in order:
  1. a .txt next to the song in /data/in (same name)  <- your own lyrics always win;
     if it contains only an LRCLIB link (https://lrclib.net/tracks/12345), that entry is used
  2. LRCLIB (free lyrics database), looked up by tags or "Artist - Title" filename
  3. fallback: transcribe the vocal stem with Whisper
"""
import argparse, json, os, re, subprocess, sys, urllib.parse, urllib.request

LEAD_IN = 1.5      # seconds a line appears before it's sung
HOLD = 1.0         # seconds a line stays after it's sung (if there's a gap)
W, H = 1920, 1080


# ---------------------------------------------------------------- metadata
def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", path],
        capture_output=True, text=True, check=True).stdout
    fmt = json.loads(out)["format"]
    tags = {k.lower(): v for k, v in fmt.get("tags", {}).items()}
    return tags.get("artist", ""), tags.get("title", ""), float(fmt.get("duration", 0))


def guess_artist_title(song_path):
    artist, title, duration = probe(song_path)
    if not title:
        stem = os.path.splitext(os.path.basename(song_path))[0].replace("_", " ")
        if " - " in stem:
            artist, title = [s.strip() for s in stem.split(" - ", 1)]
        else:
            title = stem.strip()
    return artist, title, duration


# ---------------------------------------------------------------- lyrics
def lrclib_lookup(artist, title, duration):
    params = {"track_name": title}
    if artist:
        params["artist_name"] = artist
    url = "https://lrclib.net/api/search?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": "karaoke-sep personal (lrclib client)"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            hits = json.load(r)
    except Exception as e:
        print(f"  LRCLIB lookup failed: {e}")
        return None
    hits = [h for h in hits if h.get("plainLyrics") or h.get("syncedLyrics")]
    if not hits:
        return None
    hits.sort(key=lambda h: abs((h.get("duration") or 0) - duration))
    best = hits[0]
    # Without an artist, only trust a hit whose length matches the recording
    if not artist and abs((best.get("duration") or 0) - duration) > 8:
        print(f"  LRCLIB: no confident match for '{title}' (no artist; durations differ)")
        return None
    print(f"  LRCLIB match: {best.get('artistName')} - {best.get('trackName')}")
    text = best.get("plainLyrics") or re.sub(r"\[\d+:\d+(?:\.\d+)?\]", "", best["syncedLyrics"])
    return text


LRCLIB_LINK = re.compile(r"^\s*(?:https?://)?lrclib\.net/(?:tracks|api/get)/(\d+)\s*$", re.I)


def lrclib_by_id(track_id):
    url = f"https://lrclib.net/api/get/{track_id}"
    req = urllib.request.Request(url, headers={"User-Agent": "karaoke-sep personal (lrclib client)"})
    with urllib.request.urlopen(req, timeout=20) as r:
        rec = json.load(r)
    print(f"  LRCLIB #{track_id}: {rec.get('artistName')} - {rec.get('trackName')}")
    text = rec.get("plainLyrics") or re.sub(r"\[\d+:\d+(?:\.\d+)?\]", "", rec.get("syncedLyrics") or "")
    return text, rec.get("artistName") or "", rec.get("trackName") or ""


def clean_lines(text):
    lines = []
    for line in text.splitlines():
        line = re.sub(r"\[[^\]]*\]", "", line).strip()   # drop [Chorus], [Verse 2] ...
        if line:
            lines.append(line)
    return lines


# ---------------------------------------------------------------- alignment
def load_whisper():
    import torch, stable_whisper
    device = "cuda" if torch.cuda.is_available() else "cpu"
    name = os.environ.get("WHISPER_MODEL", "small")
    print(f"  whisper model '{name}' on {device}")
    return stable_whisper.load_model(name, device=device,
                                     download_root=os.environ.get("WHISPER_CACHE", "/data/models/whisper"))


def words_of(result):
    return [(w.word.strip(), float(w.start), float(w.end))
            for seg in result.segments for w in seg.words if w.word.strip()]


def align_lines(model, vocals, lines, lang):
    result = model.align(vocals, "\n".join(lines), language=lang)
    words = words_of(result)
    counts = [len(l.split()) for l in lines]
    if sum(counts) == len(words):
        out, i = [], 0
        for c in counts:
            out.append(words[i:i + c]); i += c
        return out
    print("  word count mismatch after alignment; using Whisper's own line breaks")
    return [words_of_seg for words_of_seg in
            ([(w.word.strip(), float(w.start), float(w.end)) for w in seg.words if w.word.strip()]
             for seg in result.segments) if words_of_seg]


def transcribe_lines(model, vocals, lang):
    result = model.transcribe(vocals, language=lang)
    return [ws for ws in
            ([(w.word.strip(), float(w.start), float(w.end)) for w in seg.words if w.word.strip()]
             for seg in result.segments) if ws]


# ---------------------------------------------------------------- output
def ts_ass(t):
    t = max(t, 0)
    cs = int(round(t * 100))
    return f"{cs // 360000}:{cs // 6000 % 60:02d}:{cs // 100 % 60:02d}.{cs % 100:02d}"


def ts_lrc(t):
    cs = int(round(max(t, 0) * 100))
    return f"[{cs // 6000:02d}:{cs // 100 % 60:02d}.{cs % 100:02d}]"


def esc(s):
    return s.replace("\\", "/").replace("{", "(").replace("}", ")")


def build_ass(lines, title_text):
    # Fix up timings: monotonic, minimum word length
    fixed, last = [], 0.0
    for ws in lines:
        cur = []
        for w, s, e in ws:
            s = max(s, last); e = max(e, s + 0.05)
            cur.append((w, s, e)); last = s
        fixed.append(cur)
    lines = [l for l in fixed if l]

    header = f"""[Script Info]
ScriptType: v4.00+
PlayResX: {W}
PlayResY: {H}
WrapStyle: 0
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Sing,DejaVu Sans,72,&H0000D7FF,&H00FFFFFF,&H00000000,&H64000000,-1,0,0,0,100,100,0,0,1,4,2,5,80,80,0,1
Style: Next,DejaVu Sans,56,&H00A0A0A0,&H00A0A0A0,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,3,1,5,80,80,0,1
Style: Title,DejaVu Sans,80,&H00FFFFFF,&H00FFFFFF,&H00000000,&H64000000,-1,0,0,0,100,100,0,0,1,4,2,5,80,80,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
    ev = []
    if not lines:
        return header
    first = lines[0][0][1]
    if title_text and first > 4:
        ev.append(f"Dialogue: 0,{ts_ass(0)},{ts_ass(min(first - LEAD_IN, 6))},Title,,0,0,0,,{{\\fad(400,400)}}{esc(title_text)}")

    show_start = max(0.0, first - LEAD_IN)
    for i, ws in enumerate(lines):
        line_end = ws[-1][2]
        if i + 1 < len(lines):
            next_start = max(lines[i + 1][0][1] - LEAD_IN, line_end)
            show_end = min(line_end + HOLD, next_start)
        else:
            next_start, show_end = None, line_end + 2.0

        # karaoke fill: \k before first word, then one \kf per word
        parts = [f"{{\\k{int(round((ws[0][1] - show_start) * 100))}}}"]
        for j, (w, s, e) in enumerate(ws):
            nxt = ws[j + 1][1] if j + 1 < len(ws) else e
            parts.append(f"{{\\kf{max(int(round((nxt - s) * 100)), 1)}}}{esc(w)} ")
        ev.append(f"Dialogue: 1,{ts_ass(show_start)},{ts_ass(show_end)},Sing,,0,0,0,,"
                  f"{{\\pos({W // 2},{int(H * 0.45)})}}" + "".join(parts).rstrip())
        if i + 1 < len(lines):
            nxt_text = " ".join(w for w, _, _ in lines[i + 1])
            ev.append(f"Dialogue: 0,{ts_ass(show_start)},{ts_ass(show_end)},Next,,0,0,0,,"
                      f"{{\\pos({W // 2},{int(H * 0.62)})}}{esc(nxt_text)}")
            show_start = max(next_start, show_end)
    return header + "\n".join(ev) + "\n"


def build_lrc(lines):
    return "\n".join(ts_lrc(ws[0][1]) + " ".join(w for w, _, _ in ws) for ws in lines if ws) + "\n"


def render(instrumental, vocals, ass_path, out_mp4, guide):
    """guide = guide-vocal volume (0 = none, 0.15 = quiet, 1 = original level).
    With a guide vocal, the MP4 gets two audio tracks: the guide mix (default)
    and the pure instrumental, switchable in players like VLC."""
    vf = f"[0:v]ass={ass_path}[vout]"
    dur = probe(instrumental)[2]   # give the background an exact length (filter graphs ignore -shortest)
    cmd = ["ffmpeg", "-y", "-v", "error", "-stats",
           "-f", "lavfi", "-i", f"color=c=0x12121c:s={W}x{H}:r=30:d={dur:.3f}",
           "-i", instrumental]
    if guide > 0:
        cmd += ["-i", vocals,
                "-filter_complex",
                f"{vf};[2:a]volume={guide}[gv];[1:a][gv]amix=inputs=2:duration=first:normalize=0[mix]",
                "-map", "[vout]", "-map", "[mix]", "-map", "1:a",
                # MP4 players show track names from handler_name
                "-metadata:s:a:0", f"handler_name=With guide vocal ({int(guide * 100)}%)",
                "-metadata:s:a:1", "handler_name=Instrumental only",
                "-disposition:a:0", "default", "-disposition:a:1", "0"]
    else:
        cmd += ["-filter_complex", vf, "-map", "[vout]", "-map", "1:a"]
    cmd += ["-shortest",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart", out_mp4]
    subprocess.run(cmd, check=True)


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--song", required=True)
    ap.add_argument("--vocals", required=True)
    ap.add_argument("--instrumental", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--lyrics-file")
    a = ap.parse_args()
    lang = os.environ.get("LYRICS_LANG", "en")
    name = os.path.splitext(os.path.basename(a.song))[0]

    artist, title, duration = guess_artist_title(a.song)
    title_text = f"{artist} - {title}" if artist else title

    text, source = None, None
    if a.lyrics_file and os.path.isfile(a.lyrics_file):
        text = open(a.lyrics_file, encoding="utf-8-sig").read()
        link = LRCLIB_LINK.match(text)
        if link:   # the .txt just holds an LRCLIB link -> fetch that exact entry
            text, l_artist, l_title = lrclib_by_id(link.group(1))
            source = f"LRCLIB #{link.group(1)}"
            if l_title:
                title_text = f"{l_artist} - {l_title}" if l_artist else l_title
        else:
            source = "your .txt"
    else:
        text = lrclib_lookup(artist, title, duration)
        source = "LRCLIB" if text else None

    model = load_whisper()
    lines = clean_lines(text) if text else []
    if lines:
        print(f"  aligning {len(lines)} lines from {source}")
        timed = align_lines(model, a.vocals, lines, lang)
    else:
        print("  no lyrics found; transcribing the vocal stem (check the result!)")
        timed = transcribe_lines(model, a.vocals, lang)

    base = os.path.join(a.outdir, name)
    with open(base + ".lyrics.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(" ".join(w for w, _, _ in ws) for ws in timed) + "\n")
    with open(base + ".lrc", "w", encoding="utf-8") as f:
        f.write(build_lrc(timed))
    ass_path = base + ".ass"
    with open(ass_path, "w", encoding="utf-8") as f:
        f.write(build_ass(timed, title_text))

    guide = max(0.0, min(1.0, float(os.environ.get("GUIDE_VOCAL", "0.15"))))
    print(f"  rendering video (guide vocal {int(guide * 100)}%)")
    render(a.instrumental, a.vocals, ass_path, base + " (Karaoke).mp4", guide)
    print(f"  done: {name} (Karaoke).mp4  [lyrics: {source or 'transcribed'}]")


if __name__ == "__main__":
    sys.exit(main())
