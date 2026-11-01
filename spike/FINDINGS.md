# M0 spike findings

Measured on an Apple M2 Pro, 32 GB, macOS 26. **Not measured on the M1 / 8 GB target yet.**
Code: `Sources/Spike` (TextKit 2 editor, images, blocks), `ParseSpike` (cmark-gfm), `MathSpike` (SwiftMath), `MermaidSpike` (WebPage).
Run: `swift build -c release`, then `.build/release/Spike --bench --kb 1024`.

## 1. TextKit 2 live rendering: works
Mechanism: `NSTextContentStorageDelegate.textContentStorage(_:textParagraphWith:)` builds a *display* paragraph per
paragraph, lazily, at layout time. The text storage is never touched, so it always equals the file.
Hidden markers use a 0.01 pt font plus clear color (measured width 0.010 pt). Every transform is length-preserving
(for example the "!" of an image becomes U+FFFC, "|" becomes a tab), so display offsets equal source offsets and the
caret, selection, copy and undo need no mapping.

| Metric (M2 Pro) | Budget | Result |
|---|---|---|
| Typing, p99, 1 MB / 5 MB / 10 MB doc | < 8 ms | 2.1 / 2.1 / 1.8 ms (top), 3.1 / 1.9 / 1.5 ms (end) |
| Caret move incl. reveal/hide | < 4 ms | p99 1.2 to 2.4 ms |
| Open to first paint | < 200 ms | 25 ms (1 MB), 27 ms (10 MB); only ~140 paragraphs styled |
| Memory, 1 MB / 5 MB / 10 MB doc | <= 150 MB at 5 MB | 24 / 32 / 42 MB after 1,800 edits and moves |
| Jump caret far away and back | n/a | 0.8 ms, 1.3 ms |

Latency is independent of document size (cost is the dirty paragraph plus the viewport).
Verified: arrow-key walk has 0 dead stops (reveal at span boundary makes markers visible); copy of a selection
spanning hidden markers puts the exact source on the pasteboard; undo restores the original text; screenshots show
correct hidden and revealed states.

Gotchas found:
- **Invalidate each paragraph in its own `beginEditing/edited/endEditing` transaction.** Two far-apart ranges in one
  transaction are coalesced into one span and TextKit lays out everything between (211 ms, 8,500 paragraphs, +22 MB).
- Bench loops need an `autoreleasepool` per iteration; without it memory looked like a 40 MB leak per 300 keystrokes.
- `NSTextAttachment` only works in TextKit 2 here if it has a placeholder `image` set; then `attachmentBounds` and
  `image(for:attributes:location:textContainer:)` are called for visible fragments only.
- TextKit 2 estimates the height of unlaid paragraphs: a 200-image document reported 18,770 pt at open and 105,682 pt
  after scrolling it. The scroll bar will jump unless we supply better estimates (header sizes are 0.1 ms each).
- `NSTextView.allowsUndo` must be set.

## 2. Images: works
200 JPEGs at 2400x1600, scrolled end to end: step p99 1.65 ms, max 3.1 ms. Header-only size read 0.10 ms/image, so
layout reserves the correct height before any decode. Thumbnails decode off-main (2 concurrent) into a 48 MB
`NSCache`: steady 36 to 60 MB, transient peak 93 MB. With the caret on the line the source shows dimmed under the
image, which stays visible (screenshot checked).

## 3. Blocks: works at spike quality
- Horizontal rule drawn by a custom `NSTextLayoutFragment` (returned from `NSTextLayoutManagerDelegate`): works.
- Table: each row is its own paragraph; tab stops from cached column widths align the columns, the delimiter row is
  collapsed, caret row falls back to raw source. Still missing: borders (needs a custom fragment), `:---:` alignment,
  reveal of the whole table (currently one row), Tab to next cell.

## 4. Parser: cmark-gfm is far cheaper than needed
Full parse of 1 MB: 16.6 ms. One paragraph: 3 microseconds (p50). 2,000-item list: 2.0 ms. 10,000-line fence: 0.35 ms.
Confirmed against the GFM spec: `__x__` is `strong`, `_x_` is `emph`, `<ins>` / `</ins>` are `html_inline` nodes,
`~~x~~` is `strikethrough`. The spike's styler uses a hand-written scanner; swapping in cmark is M1 work.

## 5. Math: native alone is not enough
SwiftMath parsed 26 of 40 test expressions. Unsupported: `align*`, `\dfrac`, `\operatorname`, `\boxed`,
`\underbrace`, `\lVert`, `\pmod`, `\cancel`, `\substack`, `\xrightarrow`, `array`, `\tag`, `\newcommand`, `\ce`.
Render time p50 0.27 ms. Plan: a small preprocessor maps `\dfrac`, `align*`, `\operatorname`, `\lVert`, `\pmod`,
`\boxed` onto supported forms; the rest falls back to KaTeX in the on-demand web view.

## 6. Mermaid on demand: works, but it is the heaviest thing in the app
`WebPage` (WebKit for SwiftUI) supports `load(html:)`, `callJavaScript` and custom URL scheme handlers.
Start and load mermaid.js 156 to 413 ms; render 11 to 38 ms; invalid diagrams throw a catchable error.
Cost while alive: **WebContent process about 100 MB**, plus GPU and Networking helpers (about 20 MB) that linger
after teardown. Releasing the `WebPage` (it must really go out of scope) removes the WebContent process within 2 s.
An empty `WebPage` is about 30 MB WebContent.

## Not done in M0
- IME composition inside a styled span (needs an interactive session).
- Anything on an M1 / 8 GB machine.
- tree-sitter highlighter size and speed; image size syntax; `NSDocument` vs `DocumentGroup`.
- Real cmark integration in the styler; KaTeX fallback; accessibility (VoiceOver with hidden markers).
- Verifying `<ins>` against GitHub's docs.
