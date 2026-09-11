#!/bin/bash
# bundle-licenses.sh -- put the licence texts the .app is obliged to carry
# into `Spektrafilm/Resources/Licenses/`, from their canonical copies.
#
# HANDOFF-DISTRIBUTION §2.3. Three obligations, and the second is the one that
# is easy to miss:
#
#   GPL-3.0-or-later   the application and the C++ engine. Distributing
#                      binaries requires the licence text and an offer of the
#                      corresponding source.
#   CC BY-SA 4.0       the 28 film and paper profiles, and the 8 baked print
#                      LUTs derived from them. They are Andrea Volpato's, and
#                      the licence names "an app's About screen" as a place
#                      the attribution must survive -- so the bundle carries
#                      the text and the app shows the credit.
#   Apache-2.0         vendored metal-cpp, compiled into the binary.
#
# Copied rather than written by hand, and copied by a script rather than once:
# a licence text that drifts from the code it covers is worse than none, and
# the GPL is 674 lines nobody will diff.
#
# The result is checked in, so a fresh clone builds without running this. Run
# it when a source text changes, and `Tools/check-bundle-resources.sh` (the
# app's pre-build phase) fails the build if the directory is missing.
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../.." && pwd)     # the repository
out="$here/../Spektrafilm/Resources/Licenses"
mkdir -p "$out"

cp "$root/LICENSE" "$out/Spektrafilm-GPL-3.0.txt"
cp "$root/SPEKTRAFILM_LICENSE.txt" "$out/Profiles-and-LUTs-CC-BY-SA-4.0.txt"
cp "$root/engine/third_party/metal-cpp/LICENSE.txt" "$out/metal-cpp-Apache-2.0.txt"

# The CC BY-SA text asks that changes to the profiles and LUTs be recorded in
# a CHANGELOG shipped beside them, rather than by editing the licence. This is
# that file, and it is written here rather than checked in on its own so it
# stays next to the reason for it.
cat > "$out/Profiles-and-LUTs-CHANGELOG.txt" <<'CHANGELOG'
Changes to the spektrafilm profiles and LUTs in this application
================================================================

Required by SPEKTRAFILM_LICENSE.txt ("Changes to profiles and LUTs should be
tracked in a separate CHANGELOG.txt file shipped with them").

Original author:  Andrea Volpato
Canonical source: https://github.com/andreavolpato/spektrafilm
Licence:          CC BY-SA 4.0


The 28 film and paper profiles  --  UNMODIFIED
----------------------------------------------

`Resources/engine/profiles/*.json` are byte-for-byte copies of
`src/spektrafilm/data/profiles/*.json` from the upstream project. Nothing in
this application edits them; `engine/tools/bake_resources.py` copies them and
`engine/src/core/profile.cpp` reads them.


The 8 baked print-preview LUTs  --  DERIVED
-------------------------------------------

Inside `Resources/engine/spektrafilm_constants.bin`, as `print_lut/<stock>`
and `print_lut_axes/<stock>`: one 33x33x33x3 float32 table per print stock,
plus its per-channel density axes.

These are derivatives of the profiles, and the licence is explicit that they
are ("LUTs and similar artifacts are interpreted as direct encodings of the
information in the original profiles"). How they were made:

  - `scripts/bake_all_print_luts.py` evaluated this project's own physical
    print+scan simulation over a 33^3 grid of film densities, for each print
    stock paired with one film stock. The pairing is recorded per stock in
    `Resources/engine/print_luts.json` as `paired_film`, along with whether
    the profile data declared that pairing or the bake chose a default
    (`declared_pairing`).
  - `scanning.glare` is deliberately excluded. It is a spatial, stochastic
    veiling field and cannot be represented in a pointwise table.
  - The output is Display P3 with its transfer function applied, stored
    unclamped -- so a print colour outside P3's gamut is a negative
    coordinate rather than a clipped one.

They are not a scanned reference print. They are this simulation's output.

Distributed under CC BY-SA 4.0, the same licence as the profiles they derive
from, as the share-alike condition requires.


The constants that are not derived from the profiles
----------------------------------------------------

The rest of `spektrafilm_constants.bin` -- the 1931 standard observer, the
illuminant SDs, the colourspace primaries and matrices, the CAT cone
matrices, the Mallett basis, the Hanatos irradiance spectra, and the measured
KG3 and lens filter curves -- is published colour-science data, not Andrea
Volpato's profile work, and is not covered by this file.
CHANGELOG

cat > "$out/README.txt" <<'README'
Licences and credits
====================

Spektrafilm is free software. This directory carries the full text of every
licence the application is distributed under, because a binary that ships
without them is not licensed to be shipped.

  Spektrafilm-GPL-3.0.txt
      The application and the C++ render engine, GPL-3.0-or-later. You have
      the right to the corresponding source code:
      https://github.com/andreavolpato/spektrafilm

  Profiles-and-LUTs-CC-BY-SA-4.0.txt
      The 28 film and paper profiles, and the 8 baked print-preview LUTs
      derived from them, by Andrea Volpato, CC BY-SA 4.0.
      https://github.com/andreavolpato/spektrafilm
      Redistribution and derivatives must credit the author, link the
      project, and preserve that licence.

  Profiles-and-LUTs-CHANGELOG.txt
      What this application did and did not change about them. The profiles
      are unmodified; the LUTs are derivatives, and this says how they were
      made.

  metal-cpp-Apache-2.0.txt
      metal-cpp, Apple's C++ bindings for Metal, Apache-2.0, compiled into
      the binary.

The film simulation, the measured profiles and the print+scan model are
Andrea Volpato's work. This application is a native macOS frontend and a C++
render engine built on them.
README

printf 'licences   -> %s\n' "$out"
ls -1 "$out" | sed 's/^/             /'
