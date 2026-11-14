#!/bin/bash
# Records the README GIFs from Glint's --demo walkthroughs, on a stage window that covers the region,
# then refuses any clip whose frames show anything but the stage (privacy check) before writing GIFs.
# Usage: docs/demo/record.sh [path/to/Glint]   (default: the Release build in build/)
set -euo pipefail
cd "$(dirname "$0")/../.."
B="${1:-$PWD/build/Build/Products/Release/Glint.app/Contents/MacOS/Glint}"
R="0,680,1200,760"           # region, top-left origin points (bottom-left corner of the main display)
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
SCENE="$PWD/docs/demo/scene.png"

rec() { # name seconds
  "$B" --demo "$1" "$SCENE" "$R" >/dev/null 2>&1 & local P=$!
  sleep 1.2                   # the stage is up before recording starts
  screencapture -x -V "$2" -R"$R" "$T/$1.mov"
  kill "$P" 2>/dev/null || true; sleep 1
  local d; d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$T/$1.mov")
  python3 -c "import sys; sys.exit(0 if float('$d') >= $2 - 0.5 else 1)" || { echo "$1: clip cut short ($d s); is the screen locked?"; exit 1; }
  mkdir -p "$T/$1"; ffmpeg -v error -i "$T/$1.mov" -vf fps=2 "$T/$1/f%03d.png"
  python3 - "$T/$1" "$SCENE" "$1" <<'PY'
import sys, glob
from PIL import Image, ImageChops, ImageStat
d, scene, name = sys.argv[1:]
ref = Image.open(scene).convert('RGB').resize((1200, 760))
for f in sorted(glob.glob(d + '/*.png')):
    im = Image.open(f).convert('RGB').resize((1200, 760))
    # The stage (or, for annotate, the editor window) must cover the region: compare a strip that
    # is always the scene header or the editor's dark toolbar.
    strip = im.crop((0, 0, 1200, 70)); diff = sum(ImageStat.Stat(ImageChops.difference(strip, ref.crop((0, 0, 1200, 70)))).mean) / 3
    dark = sum(ImageStat.Stat(strip).mean) / 3 < 80
    if not (diff < 6 or (name == 'annotate' and dark)):
        sys.exit(f'{name}: frame {f.split("/")[-1]} shows something other than the demo; not writing a GIF')
PY
}
rec popup 25; rec capture 9; rec annotate 11
docs/demo/to-gif.sh "$T/popup.mov" docs/popup-edit.gif 560 15 640:440:280:160
docs/demo/to-gif.sh "$T/capture.mov" docs/capture.gif 800 15
docs/demo/to-gif.sh "$T/annotate.mov" docs/annotate.gif 800 15
