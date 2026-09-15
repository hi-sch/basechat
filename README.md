# BaseChat

A SwiftUI chat app for local models, in the spirit of Notes and Preview: a sidebar of chats,
a transcript laid out as pages, and a composer. Inference stays on the Mac. The app picks the
first runtime that is actually installed: [Edge0](https://github.com/Edge0-AI/edge0), then
[BaseRT](https://basecompute.co), then in-process [MLX](https://github.com/ml-explore/mlx-swift-lm).

<p align="center">
    <img src="https://raw.githubusercontent.com/hi-sch/basechat/refs/heads/main/BaseChat.png" width="96%" alt="BaseChat Screenshot">
</p>


## What it does

**The transcript is a document.** Turns are paginated onto US Letter sheets with a printable
margin, fitted to the window width. A turn taller than one sheet flows across sheets rather than
being clipped. Measured heights are shared between the screen and the exporter, so both break in
the same places. There is a continuous, non-paginated mode in the ⋯ menu.

**Dictation.** `AVAudioEngine` taps the microphone, buffers are resampled into the format
`SpeechAnalyzer` asks for and pushed through an `AsyncStream` to a `SpeechTranscriber` with
volatile results, so partial text lands in the composer as it is spoken. The on-device model is
downloaded on first use, with progress shown above the composer.

**Markup, the way Preview does it.** Highlight, underline and strike-through behave as text
selections: a drag produces one band per line, snapped to the measured ink of the glyphs, so a
band covers the letters and nothing else — no colour past the last word or above the tallest
letter. They can be recoloured and deleted, not dragged. Shapes — rectangle, ellipse, triangle,
diamond, star, line and arrow — notes and freehand sketches are objects: select, move, resize from
any corner (hold ⇧ to keep proportions), nudge with the arrow keys, duplicate with ⌘D, and restyle
from an inline inspector — any border and fill colour, opacity included, through the system colour
panel. Dragging across bare paper rubber-bands everything it touches into one selection.
Markup is available in both the paginated document and the continuous transcript.

**One button per tool, options underneath.** The tool buttons sit in one pill. Each arms its tool
and drops its own panel under itself: the three text marks and their colour, the shape
list, note colour and type size, pen colour and weight, and whether the tool stays out after it
has drawn — and the model settings hang off the header as one of the same panels. Each tool
remembers what it draws with, so reaching for the pen does not repaint the highlighter. One place
owns the pointer over a sheet and decides it on every move — the armed tool, the resize cursor on a
selection handle, an open hand over a mark, the I-beam over type — because cursors do not nest and
the last view to set one wins. Select text first and the highlighter marks it on the spot, without being armed at
all — it finds the words by laying the turn out again with them washed and reading back where the
colour landed, so the bands hug the glyphs exactly. Ambiguous selections — the same words twice in
one turn — arm the tool instead of guessing.

**PDF export.** Each sheet is drawn into a `CGPDFContext`, so the output is vector with selectable
text. Notes become real PDF text annotations, so they open as notes rather than as a picture of
one.

**Open in Pages.** Any answer can be handed to Apple Pages as a styled RTF document — headings,
lists, quotes and code arrive already formatted.

**Search.** Scoped to all chats or the current one. The sidebar becomes a result list with match
counts and snippets, and every hit in the transcript takes a yellow wash. Hits include message
text, hidden reasoning, model ids, and note annotations. The first hit is brought into view as
soon as the term matches; ↩ walks to the next one and wraps around at the end, with a counter
beside the field saying where you are.

**Three engines.** On launch the app checks for **Edge0**, then **BaseRT**, and falls back to **MLX**
so it still opens with nothing extra installed. The toolbar model menu (and the Models sheet)
lists only the engines that are present. Detection re-runs when the app becomes active, so
installing a CLI does not need a restart.

- **Edge0** — `edge0 serve` for the two shipping MoE tiers, `edge0-8b` and `edge0-35b` ([Edge0/Edge0-8B-A1B-preview](https://huggingface.co/Edge0/Edge0-8B-A1B-preview) and [Edge0/Edge0-35B-A3B-preview](https://huggingface.co/Edge0/Edge0-35B-A3B-preview)). OpenAI-compatible HTTP on loopback. **The Edge0 runtime can run a Qwen-based 35B parameter model with ~2.9 GB peak active memory (on disk ~23GB).**
- **BaseRT** — converts Hugging Face repos to `.base` and serves them over loopback HTTP. **The BaseRT runtime can run LLMs that are optimized for Apple Silicon (M3-M6).**
- **MLX** — loads Hugging Face safetensors on the GPU in-process. No extra CLI. Later turns in a
  chat reuse the KV cache instead of prefilling the whole history.

**Local Server.** In the ⋯ menu. Serves the loaded model over HTTP in the OpenAI format, on a port
you pick, optionally behind a key of your own and loopback-only by default — so a coding agent can
be pointed at one fixed address. MLX answers those calls in-process; Edge0 and BaseRT are proxied.
A bearer key is required if loopback-only is turned off. While it runs the window is covered,
because two drivers on one conversation is a race nobody wins; the curtain has the stop button on it.

**Per-turn metadata.** Each turn carries a timestamp; answers carry the id of the model that wrote
them, so switching models mid-chat leaves the older answers labelled correctly. Assistant turns
can also show tokens/s. Reasoning (`<think>…</think>`) is folded under a Thinking disclosure.
Regenerate rewinds to a prompt and asks again from there. If the prompt would overflow the context
budget, older turns are dropped and the reply says so.

**Composer.** You can type, format, and dictate while a model is still loading; only Send waits
until the engine is ready. Hub downloads have a Cancel button.

**Chats.** Double-click a sidebar title (or Rename in the context menu) to name a chat. Delete
chat and every markup edit — added, deleted, moved, resized, restyled — undo with ⌘Z. A failed write of `chats.json` shows an error above the
composer instead of failing silently.


## Requirements

- macOS 26+, Xcode 26+, Apple silicon for MLX
- Optional: the `edge0` CLI (`pip install` from [Edge0-AI/edge0](https://github.com/Edge0-AI/edge0); auto-detected on `PATH` or as `python3 -m edge0`). Checkpoints via `$EDGE0_8B_MODEL` / `$EDGE0_35B_MODEL`, `~/models/edge0-*`, or a Hub download.
- Optional: the `basert` CLI (auto-detected at `~/.basert/basert`, `/opt/homebrew/bin/basert`, or `/usr/local/bin/basert`)
- At least one of Edge0, BaseRT, or MLX is enough to run. MLX is compiled into the app.
- Dictation asks for microphone and speech recognition access on first use. Under the hardened
  runtime this also needs the `com.apple.security.device.audio-input` entitlement, which is in
  `BaseChat.entitlements`.
- "Open in Pages" uses Apple Pages when it is installed, and otherwise hands the RTF to whichever
  app owns the type.

## Run

A built app is in `dist/BaseChat.app` — double-click it, or drag it to `/Applications`.
`BaseChat-0.4.1.dmg` is the distributable: a 640×400 install window with the app, an Applications
alias, and an arrow between them.

## Packaging

```
xcodebuild -project BaseChat.xcodeproj -scheme BaseChat -configuration Release \
  -derivedDataPath .build build
rm -rf dist && mkdir dist && cp -R .build/Build/Products/Release/BaseChat.app dist/
./packaging/make-dmg.sh
```

The app is signed with **Developer ID Application: Martin Enzinger (JX6ZG43F7U)**, hardened runtime on,
with a secure timestamp — all three are prerequisites for notarization. `packaging/make-dmg.sh` stages the
image, drives Finder to place the icons and set the background (retrying, because Finder snaps the icons to
its grid on the first pass), compresses, and signs the result.

To notarize as well, supply your App Store Connect **Issuer ID** (a UUID from App Store Connect → Users and
Access → Integrations → Keys):

```
NOTARY_ISSUER=<issuer-uuid> ./packaging/make-dmg.sh
```

The key itself (`~/Dev/macos-dev-key/AuthKey_B8Q66JTB96.p8`) and key id are already wired in. Until the DMG
is notarized, `spctl` reports `rejected: Unnotarized Developer ID` and other Macs will refuse the download.

The background is generated by `packaging/make-background.swift` (1× and 2× combined into a hidpi TIFF with
`tiffutil`); re-run it if you change the artwork.

## Build

```
open BaseChat.xcodeproj
```

Press ⌘R. The first build resolves [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)
and Hugging Face packages. Compiling MLX needs Apple’s **Metal toolchain** (the `metal`
compiler). That is a build-time Xcode component — it is not required to *run* a built
`BaseChat.app`, and it cannot be shipped inside the app (Apple does not allow
redistributing the toolchain; the compiled `.metallib` kernels are already inside the
MLX framework once the app has been built).

```
xcodebuild -downloadComponent MetalToolchain
```

Xcode 26 also offers the download under Settings → Platforms. After that, a normal
⌘R or the Release recipe below is enough. No signing team needed for local runs
(signs to run locally).
To rebuild the standalone app:

```
xcodebuild -project BaseChat.xcodeproj -scheme BaseChat -configuration Release \
  -derivedDataPath .build build
rm -rf dist && mkdir dist && cp -R .build/Build/Products/Release/BaseChat.app dist/
codesign --force --deep --sign - dist/BaseChat.app
```

## Shortcuts

| Key | Action |
| --- | --- |
| ⌘N | New chat |
| ⌘↩ | Send |
| ⌘F | Search |
| ⎋ | Close search, then the open tool panel, the selection, and the armed tool — one step per press |
| ⌥⌘1 … ⌥⌘4 | Highlighter, shape, note, pen |
| ⌘B | Bold |
| ⌘I | Italic |
| ⇧ while resizing | Keep a shape's proportions |
| ⇧ while drawing | Square off a shape, or hold a line to 45° |
| ⌘Z | Undo a deleted chat, and any markup added, deleted, moved or restyled |
| ↑ ↓ ← → | Nudge the selected marks (⇧ for ten points) |
| ⌘D | Duplicate the selected marks |
| ↩ (in the search field) | Jump to the next match, wrapping at the end |
| ⌫ | Delete the selected marks, or the selected chats |
| ⇧/⌘-click | Select several chats |
| ⇧-click on a mark | Add it to the selection, or take it back out |
| double-click a sidebar title | Rename the chat |

## Layout

| File | What lives there |
| --- | --- |
| `Pages.swift` | Sheet metrics, pagination, the document view, and the ink scan the highlighter snaps to |
| `Annotations.swift` | Markup state, the layer drawn over each sheet, the figures, and the inline inspector |
| `MarkupToolbar.swift` | The tool buttons and the options panel each one opens |
| `TextSelectionMarkup.swift` | Turning an existing text selection into highlight bands |
| `Dictation.swift` | Microphone capture through `SpeechAnalyzer` |
| `PDFExport.swift` | Sheets to vector PDF, notes to PDF annotations |
| `PagesHandoff.swift` | Markdown to styled RTF for Apple Pages |
| `Search.swift` | Matching, snippets, the toolbar field, and the sidebar row (rename lives here too) |
| `MarkdownView.swift` | The Markdown parser and renderer, including cross-line text selection |
| `Runtime.swift` | Engine pick (Edge0 → BaseRT → MLX), CLI servers, and the shared completion path |
| `Edge0Engine.swift` | edge0 CLI discovery, the two MoE tiers, and checkpoint paths |
| `MLXEngine.swift` | In-process MLX load, Hub download, KV-cached chat sessions, and token stream |
| `Generation.swift` | Reasoning split (`<think>`), context trim, and completion stats |
| `ChatStore.swift` | Persistence, rename, and undo for chats and markup |
| `LocalServer.swift` | Fixed-port OpenAI HTTP front, with a required key when bound beyond loopback |

## Licence

BaseChat is free software under the **GNU Affero General Public License, version 3 or later** —
see [`LICENSE`](LICENSE). If you run a modified version where users interact with it over a
network, section 13 requires you to offer them its source.

## Credits

The app mark is [`ai-content-generator-01`](https://hugeicons.com/icon/ai-content-generator-01?style=stroke-rounded)
(stroke-rounded) from **HugeIcons**, redrawn as a SwiftUI `Shape` in `Logo.swift` and rendered into
`Assets.xcassets/AppIcon.appiconset`. HugeIcons' free set is CC BY 4.0 — keep this attribution if you ship it.
