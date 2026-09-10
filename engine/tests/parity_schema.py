"""Diff the C++ transport schema and digested params against the Python service.

RFC-014 keeps the wire unchanged (contract §2), and "unchanged" has to mean
something checkable. This compares, field for field:

  * `params_schema` -- name, path, type, layer, default, live flag, range.
    A row added on one side and not the other is a failure here rather than a
    slider that silently does nothing.
  * `read_params` for six stock pairs, which is what every reply carries.
  * the *digested internals* -- the stock-specific DIR-coupler gammas, the
    halation preset, the neutral filter pack from the database, and the
    nanmin/nanmax of each profile's density curves. None of these cross the
    wire, and all of them decide the picture, so the wire cannot show them
    wrong.

Usage: engine/tests/parity_schema.py [--binary path]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

ENGINE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ENGINE.parent / "src"))

STOCK_PAIRS = [
    ("kodak_portra_400", "kodak_portra_endura"),
    ("kodak_gold_200", "kodak_endura_premier"),
    ("fujifilm_velvia_100", "kodak_portra_endura"),
    ("fujifilm_provia_100f", "kodak_portra_endura"),
    ("kodak_ektachrome_100", "kodak_ektacolor_edge"),
    ("kodak_portra_800", "kodak_portra_endura"),
]


def close(a, b, tol=1e-12) -> bool:
    if isinstance(a, bool) or isinstance(b, bool):
        return bool(a) == bool(b)
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(float(a) - float(b)) <= tol * max(1.0, abs(float(a)))
    if isinstance(a, (list, tuple)) and isinstance(b, (list, tuple)):
        return len(a) == len(b) and all(close(x, y, tol) for x, y in zip(a, b))
    return a == b


def check_schema(got: dict) -> int:
    from spektrafilm.service import schema as pyschema

    want = pyschema.transport_schema()
    failures = 0
    if got["schema_version"] != want["schema_version"]:
        print(f"FAIL schema_version: C++ {got['schema_version']}, Python {want['schema_version']}")
        failures += 1

    g = {f["name"]: f for f in got["fields"]}
    w = {f["name"]: f for f in want["fields"]}
    for name in sorted(set(g) | set(w)):
        if name not in g:
            print(f"FAIL field {name!r}: declared by the Python service, missing from the engine")
            failures += 1
            continue
        if name not in w:
            print(f"FAIL field {name!r}: declared by the engine, missing from the Python service")
            failures += 1
            continue
        for key in ("path", "type", "layer", "default", "live", "range"):
            a, b = g[name].get(key), w[name].get(key)
            if not close(a, b):
                print(f"FAIL field {name!r}.{key}: C++ {a!r}, Python {b!r}")
                failures += 1

    order_cpp = [f["name"] for f in got["fields"]]
    order_py = [f["name"] for f in want["fields"]]
    if order_cpp != order_py:
        print("FAIL field order differs")
        print(f"     C++:    {order_cpp}")
        print(f"     Python: {order_py}")
        failures += 1
    if not failures:
        print(f"schema: {len(w)} fields, identical")
    return failures


def python_internals(film_stock: str, print_stock: str):
    from spektrafilm.runtime.params_builder import digest_params, init_params
    from spektrafilm.service import schema as pyschema

    p = digest_params(init_params(film_profile=film_stock, print_profile=print_stock))
    dc = p.film_render.dir_couplers
    hal = p.film_render.halation

    def minmax(profile):
        curves = np.asarray(profile.data.density_curves)
        normalized = curves - np.nanmin(curves, axis=0)
        return list(np.nanmin(curves, axis=0)), list(np.nanmax(normalized, axis=0))

    film_min, film_max = minmax(p.film)
    print_min, print_max = minmax(p.print)
    return pyschema.read_params(p), {
        "dir_couplers.gamma_samelayer_rgb": list(dc.gamma_samelayer_rgb),
        "dir_couplers.gamma_interlayer_r_to_gb": list(dc.gamma_interlayer_r_to_gb),
        "dir_couplers.gamma_interlayer_g_to_rb": list(dc.gamma_interlayer_g_to_rb),
        "dir_couplers.gamma_interlayer_b_to_rg": list(dc.gamma_interlayer_b_to_rg),
        "halation.halation_first_sigma_um": list(hal.halation_first_sigma_um),
        "halation.halation_strength": list(hal.halation_strength),
        "grain.micro_structure": list(p.film_render.grain.micro_structure),
        "scanner.unsharp_mask": list(p.scanner.unsharp_mask),
        "enlarger.c_filter_neutral": float(p.enlarger.c_filter_neutral),
        "enlarger.m_filter_neutral": float(p.enlarger.m_filter_neutral),
        "enlarger.y_filter_neutral": float(p.enlarger.y_filter_neutral),
        "profile.film.type": p.film.info.type,
        "profile.film.use": p.film.info.use,
        "profile.film.antihalation": p.film.info.antihalation,
        "profile.film.reference_illuminant": p.film.info.reference_illuminant,
        "profile.print.viewing_illuminant": p.print.info.viewing_illuminant,
        "profile.film.density_min": film_min,
        "profile.film.density_max": film_max,
        "profile.print.density_min": print_min,
        "profile.print.density_max": print_max,
    }


def check_pairs(got: dict) -> int:
    failures = 0
    for film, print_stock in STOCK_PAIRS:
        key = f"{film}|{print_stock}"
        if key not in got:
            print(f"FAIL {key}: the engine produced no entry")
            failures += 1
            continue
        want_params, want_internals = python_internals(film, print_stock)
        g = got[key]
        for name in sorted(set(g["params"]) | set(want_params)):
            a, b = g["params"].get(name), want_params.get(name)
            if not close(a, b):
                print(f"FAIL {key} params.{name}: C++ {a!r}, Python {b!r}")
                failures += 1
        for name in sorted(want_internals):
            a, b = g["internals"].get(name), want_internals[name]
            if not close(a, b):
                print(f"FAIL {key} internals.{name}: C++ {a!r}, Python {b!r}")
                failures += 1
    if not failures:
        print(f"params + internals: {len(STOCK_PAIRS)} stock pairs, identical")
    return failures


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", type=Path, default=ENGINE / "build" / "dump_json")
    args = ap.parse_args()
    out = subprocess.run([str(args.binary), str(ENGINE / "resources")],
                         check=True, capture_output=True, text=True).stdout
    got = json.loads(out)
    failures = check_schema(got["schema"]) + check_pairs(got["pairs"])
    print(f"\n{failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
