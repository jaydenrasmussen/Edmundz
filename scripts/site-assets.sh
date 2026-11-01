#!/bin/sh
# Regenerates the landing page's pictures from the real app: dark-mode 2x screenshots of each fragment, and the hero loop.
# Needs `task bench`'s executable (built here) and ffmpeg.
set -eu
cd "$(dirname "$0")/../site"
swift build -c release --product EdmundzBench --package-path .. >/dev/null
B=../.build/release/EdmundzBench
export EDMUNDZ_RESOURCES="$PWD/../Resources"
shot() { "$B" shot "$@" >/dev/null; }
mkdir -p assets frames
shot ../examples/sample.md assets/hero.png   --dark --scale 2 --width 1180 --height 640 --wait 2
shot shots/open.md    assets/open.png        --dark --scale 2 --width 900 --height 300 --wait 1
shot shots/open.md    assets/caret.png       --dark --scale 2 --width 900 --height 300 --caret "rendered**" --wait 1
shot shots/math.md    assets/math.png        --dark --scale 2 --width 900 --height 330 --wait 4
shot shots/diagram.md assets/diagram.png     --dark --scale 2 --width 900 --height 330 --wait 5
shot shots/table.md   assets/table.png       --dark --scale 2 --width 900 --height 250 --wait 1
shot shots/table.md   assets/table-raw.png   --dark --scale 2 --width 900 --height 250 --caret "Underline" --wait 1
shot shots/callout.md assets/callout.png     --dark --scale 2 --width 900 --height 330 --wait 1
shot shots/image.md   assets/image.png       --dark --scale 2 --width 900 --height 430 --wait 2
# phone-width variants: rendered at 400 pt so text keeps its true size on a phone
shot shots/open.md    assets/open-m.png      --dark --scale 2 --width 400 --height 380 --wait 1
shot shots/open.md    assets/caret-m.png     --dark --scale 2 --width 400 --height 380 --caret "rendered**" --wait 1
shot shots/math.md    assets/math-m.png      --dark --scale 2 --width 400 --height 400 --wait 4
shot shots/diagram.md assets/diagram-m.png   --dark --scale 2 --width 400 --height 260 --wait 5
shot shots/table.md   assets/table-m.png     --dark --scale 2 --width 400 --height 230 --wait 1
shot shots/table.md   assets/table-raw-m.png --dark --scale 2 --width 400 --height 230 --caret "Underline" --wait 1
shot shots/callout.md assets/callout-m.png   --dark --scale 2 --width 400 --height 420 --wait 1
shot shots/image.md   assets/image-m.png     --dark --scale 2 --width 400 --height 420 --wait 2
i=1
for c in "" "rendered**" "finished page" "nothing changes" "Click anywhere"; do
  if [ -z "$c" ]; then shot shots/open.md frames/f$i.png --dark --scale 2 --width 900 --height 300 --wait 1
  else shot shots/open.md frames/f$i.png --dark --scale 2 --width 900 --height 300 --caret "$c" --wait 1; fi
  i=$((i + 1))
done
ffmpeg -y -loglevel error -framerate 0.6 -i frames/f%d.png -c:v libx264 -pix_fmt yuv420p -r 30 -movflags +faststart -crf 22 assets/loop.mp4
cp frames/f1.png assets/loop-poster.png
rm -rf frames
mkdir -p frames
i=1
for c in "" "rendered**" "finished page" "nothing changes" "Click anywhere"; do
  if [ -z "$c" ]; then shot shots/open.md frames/f$i.png --dark --scale 2 --width 400 --height 380 --wait 1
  else shot shots/open.md frames/f$i.png --dark --scale 2 --width 400 --height 380 --caret "$c" --wait 1; fi
  i=$((i + 1))
done
ffmpeg -y -loglevel error -framerate 0.6 -i frames/f%d.png -c:v libx264 -pix_fmt yuv420p -r 30 -movflags +faststart -crf 22 assets/loop-m.mp4
cp frames/f1.png assets/loop-poster-m.png
rm -rf frames
echo "site assets regenerated"
