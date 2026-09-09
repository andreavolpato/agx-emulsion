#!/usr/bin/env python3
"""Make the 1 MP linear-ProPhoto smoke image the integration tests use.

    .venv/bin/python modern_UI/Spektrafilm/Tools/make-smoke.py [source.NEF]

Writes tests/Test_image/_smoke_1mp.tif (float32, linear ProPhoto RGB) — the
engine's stated input form, the same artifact the app's decoder produces.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "src"))
from spektrafilm.utils.io import save_image_oiio  # noqa: E402
from spektrafilm.utils.preview import resize_for_preview  # noqa: E402
from spektrafilm.utils.raw_file_processor import load_and_process_raw_file  # noqa: E402

src = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "tests/Test_image/Nikon Z7ii/_DSC2663.NEF"
out = REPO / "tests/Test_image/_smoke_1mp.tif"
img = load_and_process_raw_file(str(src), white_balance="as_shot", lens_correction=False,
                                output_colorspace="ProPhoto RGB", output_cctf_encoding=False)
small = resize_for_preview(np.asarray(img, dtype=np.float32), 1200)
save_image_oiio(str(out), small.astype(np.float32), bit_depth=32, cctf_encoding=False)
print(f"wrote {out} {small.shape}")
