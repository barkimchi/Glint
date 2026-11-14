#!/bin/bash
# Turns a screen recording into a README-sized GIF.
# Usage: docs/demo/to-gif.sh input.mov output.gif [width=960] [fps=15] [crop=w:h:x:y]
set -euo pipefail
IN="$1"; OUT="$2"; W="${3:-960}"; FPS="${4:-15}"; CROP="${5:-}"
F="${CROP:+crop=$CROP,}fps=$FPS,scale=$W:-1:flags=lanczos"
ffmpeg -v error -y -i "$IN" -vf "$F,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" "$OUT"
ls -lh "$OUT" | awk '{print $5, $9}'
