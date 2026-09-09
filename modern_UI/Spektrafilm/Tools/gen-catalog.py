#!/usr/bin/env python3
"""Build Resources/StockCatalog.json and Resources/FilmCovers/ from the engine's
profile library, so the app never parses the 5.6 MB of sensitometric JSON.

    Tools/gen-catalog.py
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
REPO = HERE.parents[1]
PROFILES = REPO / "src/spektrafilm/data/profiles"
LUTS = REPO / "src/spektrafilm/data/luts/print_preview"
COVERS_SRC = REPO / "modern_UI/film_covers"
OUT = HERE / "Spektrafilm/Resources"

# stock id -> substring of the cover filename
COVERS = {
    "kodak_portra_400": "Kodak_Portra_400",
    "kodak_portra_160": "Kodak_Portra_160",
    "kodak_portra_800": "Kodak_Portra_800",
    "kodak_portra_800_push1": "Kodak_Portra_800",
    "kodak_portra_800_push2": "Kodak_Portra_800",
    "kodak_gold_200": "Kodak_Gold_200",
    "kodak_ektachrome_100": "Kodak_Ektachrome_100",
    "kodak_ultramax_400": "Kodak_UltraMax_400",
    "fujifilm_provia_100f": "Fujifilm_Provia_100F",
    "fujifilm_velvia_100": "Fujifilm_Velvia_100",
    "fujifilm_xtra_400": "Fujifilm_Color_400",
}


def main() -> None:
    (OUT / "FilmCovers").mkdir(parents=True, exist_ok=True)
    stocks = []
    for path in sorted(PROFILES.glob("*.json")):
        info = json.loads(path.read_text())["info"]
        sid = path.stem
        cover = None
        if sid in COVERS:
            src = next(COVERS_SRC.glob(f"*{COVERS[sid]}*"), None)
            if src:
                cover = f"{sid}.jpg"
                dst = OUT / "FilmCovers" / cover
                if not dst.exists():
                    subprocess.run(["sips", "-Z", "160", str(src), "--out", str(dst)],
                                   check=True, capture_output=True)
        stocks.append({
            "id": sid,
            "name": info.get("name", sid),
            "stage": info.get("stage"),            # filming | printing
            "use": info.get("use", "still"),       # still | cine
            "type": info.get("type"),
            "targetPrint": info.get("target_print"),
            "hasPreviewLUT": (LUTS / f"{sid}.npz").exists(),
            "pairedFilm": json.loads((LUTS / f"{sid}.json").read_text())["paired_film"]
            if (LUTS / f"{sid}.json").exists() else None,
            "cover": cover,
        })
    (OUT / "StockCatalog.json").write_text(json.dumps({"stocks": stocks}, indent=1))
    print(f"wrote {len(stocks)} stocks")


if __name__ == "__main__":
    main()
