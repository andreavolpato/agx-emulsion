"""Every wire field, applied to a live session, rendered.

The render-parity suite opens a *fresh* session per case, so it never exercises
the path a user actually takes: open once, then move sliders. That gap hid a
bug that broke twelve of the print-layer fields -- most of the right-hand panel
-- with a hard error.

The bug: anything outside `LIVE_MUTABLE` replaces the pipeline, but only a
*shoot*-layer change drops the cached negative. So a print-layer rebuild left a
fresh pipeline reprinting a negative it had never rendered, with no pixel pitch
and no way to get one. `parity_render.py` could not see it and neither could
the Swift tests.

So this walks the schema itself: for every field, set it on an already-open
session and render. It asserts three things, all of which the bug broke:

  * the render succeeds;
  * `invalidated` matches the field's declared layer, because that is what
    decides whether the negative is reused -- getting it wrong lets a
    shoot-side edit silently reprint a stale negative;
  * a shoot-layer edit actually re-renders the negative, and a print-layer one
    actually reuses it.

Usage: engine/tests/parity_session.py [--verbose]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

ENGINE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ENGINE.parent / "src"))
sys.path.insert(0, str(ENGINE / "tests"))

# A value that differs from the default for every declared field, so each one
# actually changes something. Stock fields get a real alternative stock.
OVERRIDES: dict[str, object] = {
    "film_stock": "kodak_gold_200",
    "print_stock": "kodak_endura_premier",
    "input_color_space": "sRGB",
    "output_color_space": "sRGB",
    "enlarger_illuminant": "D65",
}


def value_for(field: dict):
    name, kind = field["name"], field["type"]
    if name in OVERRIDES:
        return OVERRIDES[name]
    if kind == "bool":
        return not field["default"]
    if kind == "int":
        lo, hi = field.get("range", [0, 3])
        return int(lo) if field["default"] != lo else int(hi)
    if kind == "float":
        lo, hi = field.get("range", [0.0, 1.0])
        # A third of the way in, which is different from every default in the
        # schema and inside every range.
        candidate = lo + (hi - lo) / 3.0
        return candidate if abs(candidate - field["default"]) > 1e-9 else lo + (hi - lo) * 0.6
    raise AssertionError(f"no value strategy for {name} ({kind})")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    from spk_ctypes import Engine

    rng = np.random.default_rng(11)
    frame = (rng.random((300, 400, 3)) * 0.4).astype(np.float32)

    failures = 0
    with Engine() as engine:
        schema = engine.params_schema()
        fields = schema["fields"]
        print(f"{len(fields)} declared fields, applied one at a time to one open session\n")
        session = engine.open(frame, {"grain_active": False, "glare_active": False,
                                      "auto_exposure": False})
        session.render("live", reprint=True)

        for field in fields:
            name = field["name"]
            value = value_for(field)
            try:
                reply = session.set_params({name: value})
                _, result = session.render("live", reprint=True)
            except Exception as exc:
                print(f"FAIL {name:26s} = {value!r:24} -> {exc}")
                failures += 1
                continue

            want_layer = field["layer"]
            got_layer = reply["invalidated"]
            cached = bool(result.negative_was_cached)
            problems = []
            if got_layer != want_layer:
                problems.append(f"invalidated {got_layer!r}, schema says {want_layer!r}")
            # A shoot edit must re-render the negative; a print edit must not.
            if want_layer == "shoot" and cached:
                problems.append("reused the cached negative after a shoot-layer edit")
            if want_layer == "print" and not cached:
                problems.append("re-rendered the negative after a print-layer edit")

            if problems:
                print(f"FAIL {name:26s} = {value!r:24} -> {'; '.join(problems)}")
                failures += 1
            elif args.verbose:
                print(f"ok   {name:26s} = {value!r:24} {got_layer:5s} "
                      f"{'reused' if cached else 're-rendered'} in {result.elapsed_ms:6.1f} ms")

        session.close()

    if not failures:
        print(f"ok   all {len(fields)} fields applied, rendered, and invalidated the right layer")
    print(f"\n{len(fields)} fields, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
