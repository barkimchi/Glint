#!/bin/bash
# Records the README GIFs from Glint's --demo walkthroughs, on a stage window that covers the region,
# then refuses any clip whose frames show anything but the stage (privacy check) before writing GIFs.
# Usage: docs/demo/record.sh [path/to/Glint] [popup|capture|annotate]   (default: Release build, all three)
set -euo pipefail
cd "$(dirname "$0")/../.."
[ -n "${CAFFEINATED:-}" ] || exec env CAFFEINATED=1 caffeinate -dimsu "$0" "$@"
B="${1:-}"; [ -n "$B" ] || B="$PWD/build/Build/Products/Release/Glint.app/Contents/MacOS/Glint"
R="0,680,1200,760"           # region, top-left origin points (bottom-left corner of the main display)
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
SCENE="$PWD/docs/demo/scene.png"

rec() { # name seconds
  "$B" --demo "$1" "$SCENE" "$R" >/dev/null 2>&1 & local P=$!
  sleep 2.2                   # the stage is fully up before recording starts
  screencapture -x -V "$2" -R"$R" "$T/$1.mov"
  kill "$P" 2>/dev/null || true; sleep 1
  local d; d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$T/$1.mov")
  python3 -c "import sys; sys.exit(0 if float('$d') >= $2 - 0.5 else 1)" || { echo "$1: clip cut short ($d s); is the screen locked?"; exit 1; }
  mkdir -p "$T/$1"; ffmpeg -v error -i "$T/$1.mov" -vf fps=2 "$T/$1/f%03d.png"
  python3 - "$T/$1" "$SCENE" "$1" <<'PY'
import sys, glob
from PIL import Image, ImageChops
d, scene, name = sys.argv[1:]
W, H, E = 1200, 760, 14
ref = Image.open(scene).convert('RGB').resize((W, H))
dim = Image.eval(ref, lambda v: int(v * 0.65))  # the capture overlay dims the frozen screen by 35%
def edges(img):  # the outer E pixels on all four sides, as one list of RGB tuples
    px = img.load()
    return [px[x, y] for y in list(range(E)) + list(range(H - E, H)) for x in range(W)] + \
           [px[x, y] for x in list(range(E)) + list(range(W - E, W)) for y in range(E, H - E)]
R, D = edges(ref), edges(dim)
for f in sorted(glob.glob(d + '/*.png')):
    im = Image.open(f).convert('RGB').resize((W, H))
    if name == 'capture':  # the quick-access thumbnail sits in the bottom-left corner
        im.paste(ref.crop((0, H - 240, 280, H)), (0, H - 240))
    if name == 'annotate':  # the editor's window buttons and title, top-left
        im.paste(Image.new('RGB', (300, E), (35, 35, 35)), (0, 0))
        for cx, cy in [(0, 0), (W - 20, 0), (0, H - 20), (W - 20, H - 20)]:  # rounded window corners
            im.paste(Image.new('RGB', (20, 20), (35, 35, 35)), (cx, cy))
    P = edges(im); bad = 0
    for p, r, q in zip(P, R, D):
        ok = max(abs(a - b) for a, b in zip(p, r)) < 40 or (name == 'capture' and max(abs(a - b) for a, b in zip(p, q)) < 40) \
             or (name == 'annotate' and (max(p) < 70 or (max(p) < 110 and max(p) - min(p) < 12)))  # the editor's dark frame and its gray border
        bad += not ok
    if bad > len(P) * 0.002:
        im.save('/tmp/glint-demo-failed-frame.png')
        sys.exit(f'{name}: frame {f.split("/")[-1]} has {bad} edge pixels that are not the demo; not writing a GIF')
PY
}
# caffeinate keeps the Mac from idling into the lock screen, which stops screen recording.
# Pass a name to record just that one: popup, capture or annotate.
only="${2:-}"
gif() { [ -z "$only" ] || [ "$only" = "$1" ]; }
gif popup && { rec popup 25; docs/demo/to-gif.sh "$T/popup.mov" docs/popup-edit.gif 560 15 640:440:280:160 17; }
gif capture && { rec capture 9; docs/demo/to-gif.sh "$T/capture.mov" docs/capture.gif 800 15; }
gif annotate && { rec annotate 11; docs/demo/to-gif.sh "$T/annotate.mov" docs/annotate.gif 800 15; }
