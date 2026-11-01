#!/bin/sh
# Downloads the pinned JavaScript used by the on-demand renderers into Resources/.
# mermaid: diagrams. katex: fallback for LaTeX the native renderer cannot draw.
set -eu
cd "$(dirname "$0")/../Resources"
MERMAID=11.4.1
KATEX=0.16.11
CDN=https://cdn.jsdelivr.net/npm

fetch() { curl -fsSL --retry 3 "$1" -o "$2"; }

[ -f mermaid.min.js ] || fetch "$CDN/mermaid@$MERMAID/dist/mermaid.min.js" mermaid.min.js
[ -f katex.min.js ]   || fetch "$CDN/katex@$KATEX/dist/katex.min.js" katex.min.js
[ -f katex.min.css ]  || fetch "$CDN/katex@$KATEX/dist/katex.min.css" katex.min.css
mkdir -p fonts licenses
for f in $(grep -o 'fonts/[A-Za-z0-9_-]*\.woff2' katex.min.css | sort -u); do
  [ -f "$f" ] || fetch "$CDN/katex@$KATEX/dist/$f" "$f"
done
[ -f licenses/mermaid.txt ] || fetch "$CDN/mermaid@$MERMAID/LICENSE" licenses/mermaid.txt
[ -f licenses/katex.txt ]   || fetch "$CDN/katex@$KATEX/LICENSE" licenses/katex.txt
echo "vendored mermaid $MERMAID, katex $KATEX into Resources/"
