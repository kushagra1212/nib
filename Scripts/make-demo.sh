#!/usr/bin/env bash
# Cut the screen recordings into the README demo.
#
# Three takes go in, one film comes out. The edit is here rather than in a
# video app so it can be re-run when the interface changes: re-record the same
# three moments, adjust the timings below, run this.
#
#   Scripts/make-demo.sh recording1.mov recording2.mov recording3.mov
#
# Take 1  TextEdit, typing a sentence with three mistakes, then accepting two
#         of the fixes from the hover card.
# Take 2  A sentence selected, the bar appearing, Clearer, then accepting.
# Take 3  Hovering a clean sentence and accepting the clarity rewrite.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/media"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ $# -ne 3 ]]; then
  echo "usage: $(basename "$0") take1.mov take2.mov take3.mov" >&2
  exit 1
fi

# A 2:1 window over the part of the screen anything happens in, inset by a few
# pixels: the recordings catch a sliver of whatever was behind the window.
FRAME1="crop=1196:598:12:12,scale=1280:640:flags=lanczos,setsar=1"
FRAME2="crop=1270:635:12:12,scale=1280:640:flags=lanczos,setsar=1"

cut () { # in, start, end, speed, frame-filter, out
  ffmpeg -v error -ss "$2" -to "$3" -i "$1" -an \
    -vf "$5,setpts=PTS/$4,fps=60" -c:v libx264 -crf 18 -preset slow "$WORK/$6.mp4" -y
}

# Typing runs at 5x. Nobody needs to watch twenty-three seconds of it, and the
# point of the shot is that the underlines arrive while you type.
cut "$1"  1.5 24.5 5    "$FRAME1" a
cut "$1" 24.5 31.0 1.25 "$FRAME1" b
cut "$2"  0.3  9.8 1.15 "$FRAME2" c
cut "$3"  1.6  8.3 1.1  "$FRAME2" d

# A slow push towards whatever the shot is about. Upscaled first, because
# zoompan rounds its offsets to whole pixels and the drift shows as a shudder
# at this speed.
push () { # name, from, to, focus-x, focus-y, frames
  ffmpeg -v error -i "$WORK/$1.mp4" -an -vf \
    "scale=2560:1280:flags=lanczos,zoompan=z='$2+($3-$2)*on/$6':d=1:\
x='(iw-iw/zoom)*$4':y='(ih-ih/zoom)*$5':s=1280x640:fps=60,setsar=1" \
    -c:v libx264 -crf 18 -preset slow "$WORK/${1}z.mp4" -y
}

push a 1.00 1.05 0.35 0.22 276
push b 1.05 1.09 0.32 0.45 308
push d 1.00 1.05 0.45 0.42 365
# The selection bar spans the full width, so that shot is left alone. Pushing
# in on it cuts the Bold and Diff controls off the right-hand end.
cp "$WORK/c.mp4" "$WORK/cz.mp4"

ffmpeg -v error -i "$WORK/az.mp4" -i "$WORK/bz.mp4" \
       -i "$WORK/cz.mp4" -i "$WORK/dz.mp4" -filter_complex "
[0][1]xfade=transition=fade:duration=0.35:offset=4.25[x];
[x][2]xfade=transition=fade:duration=0.35:offset=9.03[y];
[y][3]xfade=transition=fade:duration=0.35:offset=16.93,format=yuv420p[v]" \
  -map "[v]" -c:v libx264 -crf 18 -preset slow "$WORK/joined.mp4" -y

# Captions, since a silent GIF has to say what it is showing.
FONT=/System/Library/Fonts/HelveticaNeue.ttc
caption () { # text, in, out
  printf "drawtext=fontfile=%s:text='%s':fontsize=31:fontcolor=white:\
alpha='if(lt(t\\,%s+0.4)\\,(t-%s)/0.4\\,if(gt(t\\,%s-0.4)\\,(%s-t)/0.4\\,1))':\
shadowcolor=black@0.6:shadowx=0:shadowy=2:x=54:y=h-86:enable='between(t,%s,%s)'" \
    "$FONT" "$1" "$2" "$2" "$3" "$3" "$2" "$3"
}
{
  caption "Catches mistakes as you type" 0.6 4.0;   printf ","
  caption "Accept with one click" 5.2 8.5;          printf ","
  caption "Select anything to rewrite it" 9.8 16.3; printf ","
  caption "And it suggests clearer phrasing" 17.7 22.5
  printf ",format=yuv420p"
} > "$WORK/captions.filter"

mkdir -p "$OUT"
ffmpeg -v error -i "$WORK/joined.mp4" -an -filter_script:v "$WORK/captions.filter" \
  -c:v libx264 -crf 18 -preset slow -movflags +faststart "$OUT/nib-demo.mp4" -y

# GIFs. stats_mode=diff spends the palette on what moves, which for a mostly
# still screen recording is the few hundred pixels that matter. Bayer dithering
# rather than the prettier error-diffusion: diffusion speckles the flat
# background and every speckle is a pixel the next frame has to encode.
gif () { # name, seconds (0 = all), fps, width, colours
  local dur=(); [[ "$2" != 0 ]] && dur=(-t "$2")
  ffmpeg -v error "${dur[@]}" -i "$OUT/nib-demo.mp4" \
    -vf "fps=$3,scale=$4:-1:flags=lanczos,palettegen=stats_mode=diff:max_colors=$5" \
    -y "$WORK/pal.png"
  ffmpeg -v error "${dur[@]}" -i "$OUT/nib-demo.mp4" -i "$WORK/pal.png" \
    -lavfi "fps=$3,scale=$4:-1:flags=lanczos[x];\
[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" -y "$OUT/$1.gif"
}

gif nib-demo 0   10 600 64   # the whole thing, for anyone who wants it
gif nib-hero 9.0 12 640 96   # the first beat only, for the top of the README

echo "wrote:"
du -h "$OUT/nib-demo.mp4" "$OUT/nib-demo.gif" "$OUT/nib-hero.gif"
