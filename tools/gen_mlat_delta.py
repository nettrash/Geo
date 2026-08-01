#!/usr/bin/env python3
"""
gen_mlat_delta.py — generate `mlat_delta_2026.bin`, the AACGM-v2-minus-dipole
magnetic-latitude correction grid bundled with the Geo apps.

WHY THIS FILE EXISTS
--------------------
The Magnetic Conditions card needs the user's *magnetic* latitude to decide
whether the auroral oval can reach them. The cheap way to get one is the
centred-dipole rotation, which is three lines of trigonometry and needs no
data. It is also badly wrong exactly where our users are:

    London     dipole 53.34   AACGM-v2 47.71   +5.63 too optimistic
    Lancaster  dipole 56.22   AACGM-v2 50.86   +5.36
    Edinburgh  dipole 58.11   AACGM-v2 53.14   +4.97
    Reykjavik  dipole 68.79   AACGM-v2 64.21   +4.59
    Hobart     dipole -49.56  AACGM-v2 -53.72  +4.16

Five degrees is 2.5 whole Kp steps. Dipole-only, Geo would promise a hiker in
Britain an aurora at about Kp 2.5 when the truth is Kp 5+. This 4,680-byte
table buys that error back.

The apps compute `dipole mlat + grid.delta(lat, lon)`. The grid therefore
stores AACGM-v2 *minus the app's own dipole value*, which means it also
absorbs the geodetic-vs-geocentric discrepancy: the on-device code feeds the
GPS geodetic latitude straight into the spherical dipole formula, so the
generator must do exactly the same thing when it computes the term it
subtracts. Do not "fix" that by converting to geocentric here — it would put
a systematic ~0.19 deg error back into the shipped numbers.

THE LOW-LATITUDE TAPER
----------------------
AACGM-v2 is undefined near the magnetic equator: field lines from those
locations never reach the 110 km reference altitude, so the conversion fails
outright (150 of 4,680 nodes here, all at |dipole mlat| < 30.4), and for a
band just outside the failure region it returns wild values — at 25N 0E it
gives 6.76 against a dipole 27.38, a -20.6 deg delta that would overflow the
Int8 encoding on its own.

So the correction is tapered to zero with a smoothstep between
TAPER_START_MLAT and TAPER_FULL_MLAT. Below the start the app shows plain
dipole magnetic latitude, which is a well-defined standard quantity and the
only meaningful one available there. This costs nothing in practice: the
auroral oval does not reach |mlat| 35 at Kp 9 (its equatorward edge bottoms
out near 48, and even the horizon-glow rule only extends that to 40), so
every location in the tapered band is `notVisible` at any Kp regardless of
which model produced its magnetic latitude.

The taper is what makes the Int8-tenths encoding safe (peak |delta| 9.88 deg
against a 12.7 deg ceiling, 28 counts of headroom) and it guarantees no
AACGM failure node ever carries weight.

USAGE
-----
    python3 -m venv env && ./env/bin/pip install aacgmv2==2.7.1 numpy
    ./env/bin/python tools/gen_mlat_delta.py --verify-only
    ./env/bin/python tools/gen_mlat_delta.py --write

`--write` emits the asset to BOTH repos and fails if the two copies do not
come out byte-identical. Regenerate at the 2030 IGRF epoch; until then the
secular drift of the dipole moves computed magnetic latitude by about
0.06 deg over five years, which is far below the grid's own 0.5 deg budget.
"""

import argparse
import datetime as dt
import hashlib
import logging
import math
import os
import sys
import warnings

warnings.filterwarnings("ignore")
logging.disable(logging.CRITICAL)  # aacgmv2 logs an ERROR per equatorial miss

try:
    import numpy as np
    import aacgmv2
except ImportError:  # pragma: no cover
    sys.exit("need `pip install aacgmv2==2.7.1 numpy` (see the docstring)")

# ── IGRF-14 degree-1 Gauss coefficients ────────────────────────────────────
# Values at epoch 2025.0 plus one year of the published 2025-30 secular
# variation, i.e. epoch 2026.0. Read straight off igrf14coeffs.txt as shipped
# inside aacgmv2 2.7.1 — these three rows:
#   g 1 0  ... -29350.0   12.6
#   g 1 1  ...  -1410.3   10.0
#   h 1 1  ...   4545.5  -21.5
G10 = -29350.0 + 12.6
G11 = -1410.3 + 10.0
H11 = 4545.5 - 21.5

# ── Grid geometry — MUST match Geomagnetic.swift / Geomagnetic.kt ──────────
LAT_MIN, LAT_STEP, ROWS = -80.0, 2.5, 65
LON_MIN, LON_STEP, COLS = -180.0, 5.0, 72
SCALE_DEG = 0.1  # Int8 counts are tenths of a degree
BYTE_COUNT = ROWS * COLS  # 4680

# ── Model parameters ──────────────────────────────────────────────────────
EPOCH = dt.datetime(2026, 1, 1)  # epoch 2026.0
HEIGHT_KM = 110.0  # auroral emission base, the AACGM convention
TAPER_START_MLAT = 35.0  # below this, pure dipole (correction 0)
TAPER_FULL_MLAT = 50.0  # above this, full AACGM correction

# ── Output locations ──────────────────────────────────────────────────────
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKSPACE = os.path.dirname(REPO_ROOT)
ASSET_NAME = "mlat_delta_2026.bin"
IOS_PATH = os.path.join(REPO_ROOT, "Geo", "Content", "SpaceWeather", ASSET_NAME)
ANDROID_PATH = os.path.join(
    WORKSPACE, "Geo.Android", "Geo", "src", "main", "assets", "spaceweather", ASSET_NAME
)

# ── Verification fixtures ─────────────────────────────────────────────────
# (name, geodetic lat, geodetic lon). Expected values are not hard-coded:
# they are recomputed from aacgmv2 on every run and the grid is checked
# against them, so this table cannot drift away from the library.
FIXTURES = [
    ("London", 51.5074, -0.1278),
    ("Lancaster", 54.0466, -2.8007),
    ("Edinburgh", 55.9533, -3.1883),
    ("Reykjavik", 64.1466, -21.9426),
    ("Berlin", 52.5200, 13.4050),
    ("Oslo", 59.9139, 10.7522),
    ("Yekaterinburg", 56.8389, 60.6057),
    ("Moscow", 55.7558, 37.6173),
    ("Helsinki", 60.1699, 24.9384),
    ("Tromso", 69.6492, 18.9553),
    ("Fairbanks", 64.8378, -147.7164),
    ("Edmonton", 53.5461, -113.4938),
    ("Seattle", 47.6062, -122.3321),
    ("Chicago", 41.8781, -87.6298),
    ("Hobart", -42.8821, 147.3272),
]
FIXTURE_TOLERANCE_DEG = 0.5


# ── Dipole — byte-for-byte the same maths the apps run ────────────────────
def dipole_constants():
    """(pole latitude, pole longitude, B0) of the IGRF-14 centred dipole."""
    b0 = math.sqrt(G10 * G10 + G11 * G11 + H11 * H11)
    south_lat = 90.0 - math.degrees(math.acos(G10 / b0))
    south_lon = math.degrees(math.atan2(H11, G11))
    return -south_lat, south_lon - 180.0, b0


POLE_LAT, POLE_LON, B0 = dipole_constants()


def dipole_mlat(lat, lon):
    p, l = math.radians(POLE_LAT), math.radians(POLE_LON)
    la, lo = math.radians(lat), math.radians(lon)
    s = math.sin(p) * math.sin(la) + math.cos(p) * math.cos(la) * math.cos(lo - l)
    return math.degrees(math.asin(max(-1.0, min(1.0, s))))


def taper_weight(mlat):
    t = (abs(mlat) - TAPER_START_MLAT) / (TAPER_FULL_MLAT - TAPER_START_MLAT)
    t = min(1.0, max(0.0, t))
    return t * t * (3.0 - 2.0 * t)  # smoothstep — C1 continuous, no seam


def aacgm_mlat(lat, lon):
    """AACGM-v2 magnetic latitude, or None where the model is undefined."""
    try:
        m = aacgmv2.get_aacgm_coord(lat, lon, HEIGHT_KM, EPOCH)[0]
    except Exception:
        return None
    if m is None or math.isnan(m):
        return None
    return m


def build_grid():
    """Return (int8 grid as a bytes object, diagnostics dict)."""
    counts = np.zeros((ROWS, COLS), dtype=np.int16)
    failures = 0
    peak = 0.0
    for i in range(ROWS):
        lat = LAT_MIN + LAT_STEP * i
        for j in range(COLS):
            lon = LON_MIN + LON_STEP * j
            dip = dipole_mlat(lat, lon)
            w = taper_weight(dip)
            if w == 0.0:
                continue  # tapered out — leave the correction at exactly 0
            m = aacgm_mlat(lat, lon)
            if m is None:
                # Must be unreachable: the taper floor sits above the highest
                # |dipole mlat| at which AACGM fails. Loud, not silent.
                raise RuntimeError(
                    f"AACGM undefined at {lat},{lon} where taper weight is "
                    f"{w:.3f} (dipole mlat {dip:.2f}). Raise TAPER_START_MLAT."
                )
            delta = (m - dip) * w
            peak = max(peak, abs(delta))
            counts[i, j] = int(round(delta / SCALE_DEG))
            failures += 0
    over = np.abs(counts) > 127
    if over.any():
        raise RuntimeError(f"{over.sum()} nodes overflow Int8; peak {peak:.3f} deg")
    return counts.astype(np.int8).tobytes(), {
        "peak_delta_deg": peak,
        "headroom_counts": 127 - int(np.abs(counts).max()),
        "nonzero_nodes": int((counts != 0).sum()),
    }


# ── Reader — mirrors MLatDeltaGrid.delta() in Swift and Kotlin exactly ────
def grid_delta(blob, lat, lon):
    fi = (lat - LAT_MIN) / LAT_STEP
    fj = ((lon - LON_MIN) % 360.0) / LON_STEP
    i0 = max(0, min(ROWS - 1, math.floor(fi)))
    i1 = max(0, min(ROWS - 1, i0 + 1))
    ti = max(0.0, min(1.0, fi - i0))
    j0 = math.floor(fj) % COLS
    j1 = (j0 + 1) % COLS
    tj = fj - math.floor(fj)

    def at(i, j):
        v = blob[i * COLS + j]
        return (v - 256 if v > 127 else v) * SCALE_DEG

    return (
        at(i0, j0) * (1 - ti) * (1 - tj)
        + at(i1, j0) * ti * (1 - tj)
        + at(i0, j1) * (1 - ti) * tj
        + at(i1, j1) * ti * tj
    )


def verify(blob):
    ok = True

    def check(label, cond, detail=""):
        nonlocal ok
        ok &= cond
        print(f"  [{'PASS' if cond else 'FAIL'}] {label}{(' — ' + detail) if detail else ''}")

    print("verification")
    check("byte count is exactly 4680", len(blob) == BYTE_COUNT, f"{len(blob)}")
    check(
        "longitude wraps continuously at the antimeridian",
        all(
            abs(grid_delta(blob, la, -180.0) - grid_delta(blob, la, 180.0)) < 1e-12
            for la in (-70, -40, 0, 40, 55, 70)
        ),
    )
    check(
        "correction is exactly 0 below the taper floor",
        all(
            grid_delta(blob, la, lo) == 0.0
            for la in (-20, -10, 0, 10, 20)
            for lo in (-150, -60, 0, 60, 150)
        ),
    )
    worst, worst_name = 0.0, ""
    for name, la, lo in FIXTURES:
        truth = aacgm_mlat(la, lo)
        got = dipole_mlat(la, lo) + grid_delta(blob, la, lo)
        err = abs(got - truth)
        if err > worst:
            worst, worst_name = err, name
    check(
        f"all {len(FIXTURES)} city fixtures within {FIXTURE_TOLERANCE_DEG} deg of AACGM",
        worst <= FIXTURE_TOLERANCE_DEG,
        f"worst {worst:.3f} deg at {worst_name}",
    )
    # The single most important property in the whole feature.
    lon_d = dipole_mlat(51.5074, -0.1278)
    lon_c = lon_d + grid_delta(blob, 51.5074, -0.1278)
    edge_kp7 = 66.5 - 2.0444 * 7.0
    check(
        "London regression: corrected mlat demotes Kp 7 from 'oval reaches' "
        "to 'horizon glow'",
        (lon_d - edge_kp7) >= 0.0 > (lon_c - edge_kp7),
        f"dipole {lon_d:.2f} (margin {lon_d - edge_kp7:+.2f}) vs "
        f"corrected {lon_c:.2f} (margin {lon_c - edge_kp7:+.2f})",
    )
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--write", action="store_true", help="emit the asset to both repos")
    ap.add_argument("--verify-only", action="store_true", help="build and check, write nothing")
    args = ap.parse_args()

    print(f"IGRF-14 @ epoch 2026.0   g10={G10:.1f}  g11={G11:.1f}  h11={H11:.1f}")
    print(f"centred dipole           pole {POLE_LAT:.4f} N {POLE_LON:.4f} E   B0 {B0:.4f} nT")
    print(f"                         tilt {90 - POLE_LAT:.4f} deg")
    print(f"grid                     {ROWS} x {COLS} = {BYTE_COUNT} B, "
          f"lat {LAT_MIN}..{LAT_MIN + LAT_STEP * (ROWS - 1)} step {LAT_STEP}, "
          f"lon {LON_MIN}..{LON_MIN + LON_STEP * (COLS - 1)} step {LON_STEP}")
    print(f"taper                    0 below |mlat| {TAPER_START_MLAT}, "
          f"full above {TAPER_FULL_MLAT}\n")

    blob, diag = build_grid()
    print(f"built                    peak |delta| {diag['peak_delta_deg']:.3f} deg, "
          f"{diag['headroom_counts']} counts of Int8 headroom, "
          f"{diag['nonzero_nodes']} non-zero nodes\n")

    digest = hashlib.sha256(blob).hexdigest()
    if not verify(blob):
        sys.exit("\nVERIFICATION FAILED — nothing written")
    print(f"\nsha256                   {digest}")

    if args.verify_only or not args.write:
        print("\n(dry run — pass --write to emit the asset)")
        return

    for path in (IOS_PATH, ANDROID_PATH):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(blob)
        print(f"wrote                    {path}")
    a = open(IOS_PATH, "rb").read()
    b = open(ANDROID_PATH, "rb").read()
    if a != b:
        sys.exit("FATAL: the two shipped copies differ")
    print("\nboth copies byte-identical. Pin this in the unit tests:")
    print(f'    "{digest}"')


if __name__ == "__main__":
    main()
