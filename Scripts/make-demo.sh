#!/usr/bin/env bash
# Cut the screen recordings into the README demo.
#
#   Scripts/make-demo.sh take1.mov take2.mov take3.mov
#
# Take 1  TextEdit, typing a sentence with three mistakes, then accepting two
#         fixes from the hover card.
# Take 2  A sentence selected, the bar appearing, Clearer, then accepting.
# Take 3  Hovering a clean sentence and accepting the clarity rewrite.
#
# Re-record the same three moments after an interface change and adjust the
# timings in `cut` below.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/media"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

[[ $# -eq 3 ]] || { echo "usage: $(basename "$0") take1.mov take2.mov take3.mov" >&2; exit 1; }
mkdir -p "$OUT"

# ---------------------------------------------------------------- framing --
# A 2:1 window over the part of the screen anything happens in, inset a few
# pixels because the recordings catch a sliver of whatever was behind.
F1="crop=1196:598:12:12,scale=1280:640:flags=lanczos,setsar=1"
F2="crop=1270:635:12:12,scale=1280:640:flags=lanczos,setsar=1"

cut () { # in start end speed frame out
  ffmpeg -v error -ss "$2" -to "$3" -i "$1" -an \
    -vf "$5,setpts=PTS/$4,fps=60" -c:v libx264 -crf 18 -preset medium "$W/$6.mp4" -y
}
# Typing runs at 5x. Nobody needs twenty-three seconds of it, and the point of
# the shot is that the underlines arrive while you type.
cut "$1"  1.5 24.5 5    "$F1" a
cut "$1" 24.5 31.0 1.25 "$F1" b
cut "$2"  0.3  9.8 1.15 "$F2" c
cut "$3"  1.6  8.3 1.1  "$F2" d

# ------------------------------------------------------------------ motion --
# Cosine ease, not a linear ramp: a constant-speed zoom is the thing that makes
# a screen recording look like a screen recording.
#
# Anchored near the left edge. The sentence starts there, and a centred zoom
# takes the first word off the front of it.
#
# Upscaled before zoompan, which rounds its offsets to whole pixels; at this
# speed the drift reads as a shudder.
ease () { # name from to focus-x focus-y frames
  ffmpeg -v error -i "$W/$1.mp4" -an -vf \
"scale=2560:1280:flags=lanczos,zoompan=z='$2+($3-$2)*(0.5-0.5*cos(PI*min(on/$6,1)))':\
d=1:x='(iw-iw/zoom)*$4':y='(ih-ih/zoom)*$5':s=1280x640:fps=60,setsar=1" \
    -c:v libx264 -crf 18 -preset medium "$W/${1}z.mp4" -y
}
ease a 1.00 1.05 0.06 0.20 276
ease b 1.05 1.08 0.08 0.42 308
ease d 1.00 1.05 0.12 0.40 365
# The selection bar spans the full width, so that shot stays put. Pushing in
# on it cuts Bold and Diff off the end, which is the row the shot is about.
cp "$W/c.mp4" "$W/cz.mp4"

ffmpeg -v error -i "$W/az.mp4" -i "$W/bz.mp4" -i "$W/cz.mp4" -i "$W/dz.mp4" \
  -filter_complex "
[0][1]xfade=transition=fade:duration=0.5:offset=4.10[x];
[x][2]xfade=transition=fade:duration=0.5:offset=8.73[y];
[y][3]xfade=transition=fade:duration=0.5:offset=16.48,format=yuv420p[v]" \
  -map "[v]" -c:v libx264 -crf 18 -preset medium "$W/joined.mp4" -y

# ------------------------------------------------------------------- stage --
# The window on a flat backdrop with rounded corners and a soft shadow.
#
# Flat, not a gradient: a gradient has to be dithered into 64 colours for the
# GIF and comes back as visible rings behind the window.
R=18 CW=1376 CH=688
python3 - "$CW" "$CH" "$R" > "$W/mask.filter" <<'PY'
import sys
w, h, r = (int(a) for a in sys.argv[1:4])
dx = f"max(max({r}-X,X-({w-1}-{r})),0)"
dy = f"max(max({r}-Y,Y-({h-1}-{r})),0)"
print(f"geq=lum='if(lte(pow({dx},2)+pow({dy},2),{r*r}),255,0)':cb=128:cr=128", end="")
PY
ffmpeg -v error -f lavfi -i "color=c=black:s=${CW}x${CH}:d=0.1" \
  -filter_script:v "$W/mask.filter" -frames:v 1 "$W/mask.png" -y
ffmpeg -v error -i "$W/mask.png" -vf "gblur=sigma=26,format=gray" \
  -frames:v 1 "$W/shadow.png" -y

ffmpeg -v error -i "$W/joined.mp4" -i "$W/mask.png" -i "$W/shadow.png" -filter_complex "
color=c=0x0E1013:s=1600x900:r=60:d=23.1[bg];
[0:v]scale=${CW}:${CH}:flags=lanczos,format=rgba[cnt];
[1:v]format=gray[msk];
[cnt][msk]alphamerge[round];
color=c=black:s=${CW}x${CH}:r=60:d=23.1,format=rgba[blk];
[2:v]format=gray[shd];
[blk][shd]alphamerge,colorchannelmixer=aa=0.5[shadow];
[bg][shadow]overlay=x=112:y=126:shortest=1[bg2];
[bg2][round]overlay=x=112:y=106:shortest=1,format=yuv420p[v]" \
  -map "[v]" -t 22.5 -c:v libx264 -crf 19 -preset medium "$W/staged.mp4" -y

# ---------------------------------------------------------------- captions --
# Below the window, on the backdrop, so they never sit over the app.
FONT=/System/Library/Fonts/HelveticaNeue.ttc
python3 - "$FONT" > "$W/captions.filter" <<'PY'
import sys
font = sys.argv[1]
labels = [("Catches mistakes as you type", 0.7, 4.0),
          ("Accept with one click", 5.0, 8.3),
          ("Select anything to rewrite it", 9.4, 15.9),
          ("And it suggests clearer phrasing", 17.2, 22.0)]
out = []
for text, a, b in labels:
    fade = (f"if(lt(t\\,{a}+0.45)\\,(t-{a})/0.45\\,"
            f"if(gt(t\\,{b}-0.45)\\,({b}-t)/0.45\\,1))")
    out.append(f"drawtext=fontfile={font}:text='{text}':fontsize=30:"
               f"fontcolor=0xE8EAED:alpha='{fade}':"
               f"x=(w-text_w)/2:y=h-96:enable='between(t,{a},{b})'")
out.append("format=yuv420p")
print(",".join(out), end="")
PY
ffmpeg -v error -i "$W/staged.mp4" -an -filter_script:v "$W/captions.filter" \
  -c:v libx264 -crf 19 -preset slow -movflags +faststart "$OUT/nib-demo.mp4" -y

# -------------------------------------------------------------------- gifs --
# stats_mode=diff spends the palette on what moves. dither=none because the
# backdrop is flat: there is nothing to dither, and dithering it would speckle
# every frame with pixels the next frame has to encode.
gif () { # name seconds fps width colours
  local dur=(); [[ "$2" != 0 ]] && dur=(-t "$2")
  ffmpeg -v error "${dur[@]}" -i "$OUT/nib-demo.mp4" \
    -vf "fps=$3,scale=$4:-1:flags=lanczos,palettegen=stats_mode=diff:max_colors=$5" \
    -y "$W/pal.png"
  ffmpeg -v error "${dur[@]}" -i "$OUT/nib-demo.mp4" -i "$W/pal.png" \
    -lavfi "fps=$3,scale=$4:-1:flags=lanczos[x];\
[x][1:v]paletteuse=dither=none:diff_mode=rectangle" -y "$OUT/$1.gif"
}
gif nib-demo 0   10 620 64   # all four beats
gif nib-hero 8.8 12 660 80   # the first beat, for the top of the README

echo "wrote:"
du -h "$OUT/nib-demo.mp4" "$OUT/nib-demo.gif" "$OUT/nib-hero.gif"
