# Visual iteration — the snapshot harness

| | |
|---|---|
| **What this is** | The loop that lets the interface be checked against the drawing without a human looking at it. |
| **One command** | `design/snapshot.sh [image]` → `design/snapshots/window-*.png` |
| **Measure it** | `Spektrafilm/Tools/compare-layout.py design/snapshots/window-16x9.png` |
| **Date** | 2026-09-08 |

## How it works

The app itself has a snapshot mode:

```
Spektrafilm --snapshot 1920x1080 out.png [--open file.NEF --wait 90]
```

It opens its own `NSWindow` at that size, hosts the real `EditorWindow`, and
in `--open` mode runs the whole pipeline (Core Image decode → linear TIFF →
service `open` → `reprint` → texture) and waits for the print to land before
capturing. The Metal canvas is replaced by an offscreen render through the
same `Renderer` (`SnapshotCanvas`), so the capture shows the real render path
including Layer 2 and the histogram. `Tools/snapshot.sh` runs it at the three
shapes that matter: MacBook Pro 14" (1512×982), 16:9 (1920×1080) and the 21:9
display (3360×1418).

`compare-layout.py` finds the four card-coloured regions in the 1920×1080
capture and prints their rectangles against the SVG's (÷2). Under 2.5 pt of
drift is a pass; the run recorded on 2026-09-08 was within 2 pt on every card.

## What it cannot capture — and the harness that can

Hover, focus and drag: no pointer exists. Menus and sheets are not opened.

**The canvas.** `cacheDisplay` cannot see a `CAMetalLayer`, so snapshot mode
substitutes an offscreen render through the same `Renderer`. That covers the
render path and misses everything between it and the screen — which is where
two shipped defects lived at once: a drawable pixel format `CAMetalLayer`
rejects (the app crashed on launch) and a redraw that never reached the view
(the canvas stayed blank while every number behind it was right).

```
Spektrafilm/Tools/capture-live.sh [image.NEF]   # → design/snapshots/live-window.png
```

launches the real app, opens a frame, waits for the print, and asks the window
server for the pixels. It needs Screen Recording permission. It is the only
capture that proves the canvas draws — run it before believing it does.

## Two more things the harness itself got wrong

- **A titled window is clamped to the screen.** Asking for 1920×1080 on a
  smaller display quietly produced an 1800-point-wide capture, and every
  measurement against it was wrong by that ratio. The snapshot window is now
  borderless and never centred, so the capture does not depend on which
  display is attached.
- **A capture inherited persisted UI state.** A filmstrip collapsed in some
  earlier session removed a whole card, and `compare-layout.py` matched the
  missing card against the nearest one and reported drift instead of absence.
  Snapshot mode now resets the collapse flags, and the matcher requires a
  region of about the right size before it will call it a match.

## Reference

`modern_UI/reference_layout/SVG_link/sample_frontend.svg` is the drawing;
`Theme.swift` carries every number from it, divided by two.
