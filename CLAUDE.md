# Filmify — read `AGENTS.md` first

This repository is the macOS product **Filmify**: a SwiftUI app with a C++
Metal render engine compiled into it. `README.md` is the map; `AGENTS.md` is
the working notes, and the traps section in it has cost real debugging time.

**This project is not the one the parent directory's `CLAUDE.md` describes.**
That file is about a website/resume task in `Summer 2026/`. Ignore it here.

## The short version

- **No Python.** No `src/`, no `.venv`, no subprocess — not at build time, not
  at run time. If you find yourself reaching for an interpreter to build or run
  this, something is wrong.
- **Build:** `engine/build.sh bundle`, then `xcodebuild` (see `README.md`).
  The bundle step is not optional; a pre-build phase fails without it.
- **The engine is spektrafilm's.** The product is Filmify; the engine, the 28
  profiles and the print LUTs keep the spektrafilm name, and the licence
  requires that split. Don't "fix" it by renaming the engine.
- **`engine/resources/` is tracked** — 15 MB of baked output, deliberately
  committed. Don't gitignore it. Regenerating it needs the Python reference
  tree in the `spektrafilm` fork, which is not here.
- **The Xcode target and scheme are still called `Spektrafilm`** while the
  product is Filmify. That is intentional (schemes reference the target by
  name); `Tools/gen-project.py` carries the distinction as `APP` vs
  `PRODUCT_NAME`.

## Working rules from `AGENTS.md`

`AGENTS.md`, `ARCHITECTURE.md`, `API-SPEC-*` and `CONTRACT-*` belong to nobody
in particular — say so before editing one. The parity harnesses in
`engine/tests/` are the reason the C++ port can be trusted; they need the
Python reference and are documented in `README.md`.
