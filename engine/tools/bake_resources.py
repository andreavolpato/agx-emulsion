"""Bake every run-time constant the C++ engine needs into `engine/resources/`.

RFC-014 §6 step 3, the data half. The engine ships with no Python, no
colour-science and no numpy, so everything those supply as *named data* --
the standard observer, the illuminant SDs, the colourspace primaries, the
Mallett basis, the Hanatos irradiance spectra, the measured filter curves --
is written here once, in a format a C++ reader can mmap.

The arithmetic over that data is **not** baked: it is ported to C++ in
`engine/src/core/`, and `engine/tests/parity_setup.py` re-derives every
value from the Python reference and compares. A silently-wrong constant is
RFC-012 §4.1's named failure mode; a baked table that nothing checks is the
same failure with an extra step.

Blob format (little-endian, the only byte order this ships on):

    magic   "SPKR"                4 bytes
    version u32 = 1
    count   u32                   number of entries
    pad     u32
    entry[count]:
        name     char[64]         NUL-padded
        dtype    u32              0=f64 1=f32 2=f16 3=i32 4=u8
        ndim     u32
        dims     u32[4]
        offset   u64              from the start of the file, 8-byte aligned
        nbytes   u64
    data ...

Run: engine/tools/bake_resources.py [--out engine/resources]
"""
from __future__ import annotations

import argparse
import importlib.resources
import json
import shutil
import struct
import sys
from pathlib import Path

import numpy as np

MAGIC = b"SPKR"
VERSION = 1
NAME_LEN = 64
DTYPES = {"float64": 0, "float32": 1, "float16": 2, "int32": 3, "uint8": 4}
ENTRY_FMT = f"<{NAME_LEN}sIIIIIIQQ"
ENTRY_SIZE = struct.calcsize(ENTRY_FMT)
assert ENTRY_SIZE == NAME_LEN + 4 * 6 + 8 * 2


class Blob:
    def __init__(self) -> None:
        self._entries: list[tuple[str, np.ndarray]] = []

    def add(self, name: str, array, dtype=None) -> None:
        arr = np.ascontiguousarray(np.asarray(array) if dtype is None
                                   else np.asarray(array, dtype=dtype))
        if arr.dtype.name not in DTYPES:
            raise TypeError(f"{name}: unsupported dtype {arr.dtype}")
        if arr.ndim > 4:
            raise ValueError(f"{name}: {arr.ndim} dimensions, max 4")
        if len(name.encode()) >= NAME_LEN:
            raise ValueError(f"{name}: name too long")
        if any(n == name for n, _ in self._entries):
            raise ValueError(f"{name}: duplicate entry")
        self._entries.append((name, arr))

    def write(self, path: Path) -> int:
        header = len(MAGIC) + 4 * 3 + ENTRY_SIZE * len(self._entries)
        offset = (header + 7) & ~7
        table, data, cursor = [], [], offset
        for name, arr in self._entries:
            dims = list(arr.shape) + [0] * (4 - arr.ndim)
            table.append(struct.pack(ENTRY_FMT, name.encode(), DTYPES[arr.dtype.name],
                                     arr.ndim, *dims, cursor, arr.nbytes))
            data.append((cursor, arr))
            cursor = (cursor + arr.nbytes + 7) & ~7
        with open(path, "wb") as fh:
            fh.write(MAGIC)
            fh.write(struct.pack("<III", VERSION, len(self._entries), 0))
            for row in table:
                fh.write(row)
            for want, arr in data:
                fh.write(b"\0" * (want - fh.tell()))
                fh.write(arr.tobytes())
        return path.stat().st_size


def bake_colour(blob: Blob) -> None:
    """`model/colour_baked.py`'s npz, entry for entry.

    Keys keep their slashes (`cs/sRGB/matrix_RGB_to_XYZ`); the C++ reader
    looks them up by the same string, so a renamed key is a load-time error
    rather than a wrong picture.
    """
    from spektrafilm.model import colour_baked as cb

    with np.load(cb._NPZ, allow_pickle=False) as z:
        for key in z.files:
            blob.add(f"colour/{key}", z[key], dtype=np.float64)


def bake_spectra(blob: Blob) -> None:
    """Hanatos irradiance spectra, (192, 192, 81).

    Kept as float16 -- that is how the reference stores it and how
    `_load_hanatos2025_spectra_lut` reads it before widening to float64, so
    shipping float32 would be *more* bits than the reference has and still
    not a different number. 5.97 MB, the largest single resource.
    """
    path = importlib.resources.files(
        "spektrafilm.data.luts.spectral_upsampling").joinpath("irradiance_xy_tc.npy")
    with path.open("rb") as fh:
        lut = np.load(fh)
    if lut.dtype != np.float16:
        raise SystemExit(f"spectra lut dtype changed: {lut.dtype}")
    blob.add("hanatos/spectra_lut", lut)


def bake_filters(blob: Blob) -> None:
    """The measured filter curves `model/color_filters.py` loads from CSV.

    Only the two the render path can reach are baked: KG3 (every `TH-KG3`
    illuminant, which is the enlarger default) and the Canon lens
    transmission (`TH-KG3-L`). The dichroic set the enlarger actually grades
    with is `custom_dichroic_filters`, which is *analytic* (four erfs) and is
    therefore ported rather than baked -- `parity_setup.py` checks the port
    against this baked copy.
    """
    from spektrafilm.model.color_filters import (
        custom_dichroic_filters, generic_lens_transmission, schott_kg3_heat_filter,
    )
    blob.add("filters/kg3", schott_kg3_heat_filter.transmittance, dtype=np.float64)
    blob.add("filters/lens_canon", generic_lens_transmission.transmittance, dtype=np.float64)
    blob.add("filters/dichroic_custom_ref", custom_dichroic_filters.filters, dtype=np.float64)


def bake_shape(blob: Blob) -> None:
    from spektrafilm.config import SPECTRAL_SHAPE
    blob.add("spectral/wavelengths", SPECTRAL_SHAPE.wavelengths, dtype=np.float64)


def copy_json(src_dir: Path, dst_dir: Path, pattern: str) -> int:
    dst_dir.mkdir(parents=True, exist_ok=True)
    n = 0
    for path in sorted(src_dir.glob(pattern)):
        shutil.copy2(path, dst_dir / path.name)
        n += 1
    return n


def main() -> int:
    ap = argparse.ArgumentParser()
    here = Path(__file__).resolve().parents[1]
    ap.add_argument("--out", type=Path, default=here / "resources")
    args = ap.parse_args()
    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)

    blob = Blob()
    bake_shape(blob)
    bake_colour(blob)
    bake_spectra(blob)
    bake_filters(blob)
    size = blob.write(out / "spektrafilm_constants.bin")

    data = Path(__import__("spektrafilm").__file__).parent / "data"
    n_profiles = copy_json(data / "profiles", out / "profiles", "*.json")
    shutil.copy2(data / "filters/neutral_print_filters.json", out / "neutral_print_filters.json")

    print(f"constants  {size/1e6:7.3f} MB")
    print(f"profiles   {n_profiles} JSON files, "
          f"{sum(p.stat().st_size for p in (out/'profiles').glob('*.json'))/1e6:.3f} MB")
    print(f"-> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
