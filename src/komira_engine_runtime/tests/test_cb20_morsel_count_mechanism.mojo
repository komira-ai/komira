# =============================================================================
# WHERE cb20's 112,980 MORSELS/REP COME FROM — a measured derivation
#
# =============================================================================
#
# THE OBSERVATION (corpus census ``,
# `bench/results/forkzero_census/`, `KOMIRA_MORSEL_SORT_PROBE=1`):
# cb20 feeds `_stable_sort_morsels_by_partition` **112,980 morsels per rep**
# (94,272 + 18,708 across its two per-rep calls) against a corpus median of 782
# and p90 of 3,907 — and against the "e.g. 128 RGs * 16 sub-slots = 2048
# morsels" worst case that primitive's own docstring states. 24x p90, 46x the
# stated design ceiling. Because each `Morsel` move is a fat
# `RecordBatch`+`Schema` struct move, the serial finalize cost is driven by that
# COUNT, so "why 112,980" is the question that decides the lever.
#
# THE ANSWER IS NOT AN EXPLOSION — IT IS `rows / morsel_rows`, TWICE, with the
# REAL `hits` fixture geometry read from the parquet footer (99,997,497 rows,
# 814 row groups, 12 columns = 11 x INT64 + 1 x INT32 = 92 bytes/row).
#
# ⚠ THE WIDTH THE CENSUS RAN AT IS HISTORY, AND THIS FILE NOW SAYS SO. On
# the sizing budget was `l1d_cache_bytes / 2`:
#
# default_morsel_rows(schema) [RETIRED ]
#     = clamp( ((l1d_cache_bytes / 2) / row_width_bytes) * TIER_MULT_DEFAULT,
#              MIN_MORSEL_ROWS_DEFAULT = 1024,
#              MAX_MORSEL_ROWS_DEFAULT = 131072 )
#
# For a 92-byte row that term lands in the HUNDREDS, so the **MIN clamp fired**
# and the answer was exactly 1024 — the smallest morsel the policy will ever
# emit. 99,997,497 / 1024 = 97,654 morsels for ONE full scan of `hits`, and cb20
# scans it TWICE (build side `WHERE region_id = 229`, probe side the SEMI).
# Equivalently: 814 row groups x ~122,850 rows/RG / 1024 = ~120 sub-morsels per
# ROW GROUP, where the sort docstring's design case assumed 16.
#
# Now the budget is the L2-PER-WORKER share (x0.5) and there is no
# env gate; on a 256 KiB-share box that is 128 KiB, so the 92-byte row gives
# 1424 x 2.0 = 2848 rows and the MIN clamp NO LONGER BINDS. The same mechanism
# then predicts ~35,111 morsels per full scan instead of 97,654 — a ~2.8x drop.
# ⛔ THAT PREDICTION IS NOT MEASURED. No census has been re-run against the new
# default, so this file asserts it as ARITHMETIC over the shipped policy and
# explicitly does not claim cb20's observed count moved.
#
# WHAT THIS TEST PINS (each assertion is falsifiable, not descriptive):
#   1. `test_census_era_width_was_the_min_clamp` — under the RETIRED L1d
#      budget the unclamped term was strictly BELOW 1024, so the census-era
#      width was the MIN clamp. Arithmetic over the detected profile's
#      `l1d_cache_bytes` (still a real probed field), NOT over the live
#      formula — a historical measurement must not be recomputed from today's
#      code, or it silently stops being a check on the measurement.
#   2. `test_derived_morsel_count_matches_census` — `rows / 1024` for a full
#      `hits` scan must land within 5% of the census's observed 94,272. This is
#      the falsifier for the whole mechanism: if the morsels came from a
#      partition explosion, a per-row-group fan-out bug, or a sub-slot
#      multiplier rather than from `rows / morsel_rows`, this number does not
#      reproduce the measurement.
#   3. `test_file_schema_vs_projected_schema_sizing_gap` — QUANTIFIES the
#      second-order defect: both cb20 call sites size the morsel from the full
#      PARQUET FILE schema (`_build_schema_from_meta(meta)`) while the scan only
#      DECODES a narrow projection ({user_id, region_id} on the build side).
#      Sizing off the decoded projection instead is worth the ratio this test
#      prints — a real but bounded lever, NOT the 48x.
#   4. `test_hw_morsel_l2_path_is_the_default` — the SHIPPED width is the
#      `budget = l2_per_worker / 2` one, and this pins it against the live
#      policy so the file's own arithmetic cannot drift from the code. It
# asserted the OPPOSITE, when the L1d arm and its
#      `KOMIRA_HW_MORSEL_L2` gate were deleted.
#
# NO BENCHMARK IS RUN. This is arithmetic over the production policy object.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder

from komira_engine_runtime.hardware_detect import detect_hardware_profile
from komira_engine_runtime.hardware import HardwareProfile
from komira_engine_runtime.morsel_sizing_policy import (
    MAX_MORSEL_ROWS_DEFAULT,
    MIN_MORSEL_ROWS_DEFAULT,
    MorselSizingPolicy,
    TIER_MULT_DEFAULT,
)


# -- The REAL fixture geometry (parquet footer of bench/data/
# -- komira_bench_cb_hits.parquet, read). --
comptime HITS_ROWS: Int = 99997497
comptime HITS_ROW_GROUPS: Int = 814
comptime HITS_N_INT64: Int = 11
comptime HITS_N_INT32: Int = 1

# -- What the census measured for cb20's two per-rep sort calls. --
comptime CENSUS_PROBE_MORSELS: Int = 94272
# The morsel width the census RAN at (the MIN clamp, which bound under the
# then-live L1d budget). A constant, not a policy call: this is history.
comptime CENSUS_ERA_MORSEL_ROWS: Int = 1024
comptime CENSUS_BUILD_MORSELS: Int = 18708


def _hits_file_schema() raises -> Schema:
    """The full `hits` FILE schema: 11 x INT64 + 1 x INT32 -> 92 bytes/row.
    This is what BOTH cb20 call sites hand to `default_morsel_rows`
    (`_build_schema_from_meta(footer_cache.get_or_parse(path))`)."""
    var sb = SchemaBuilder()
    for i in range(HITS_N_INT64):
        sb.add_field(Field(String("i") + String(i), ArrowType.INT64, False))
    for i in range(HITS_N_INT32):
        sb.add_field(Field(String("j") + String(i), ArrowType.INT32, False))
    return sb.build()


def _build_side_projected_schema() raises -> Schema:
    """What the build scan actually DECODES: {user_id INT64, region_id INT32}
    = 12 bytes/row (`build_proj` in `materialize_parquet_join`)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("user_id", ArrowType.INT64, False))
    sb.add_field(Field("region_id", ArrowType.INT32, False))
    return sb.build()


def test_census_era_width_was_the_min_clamp() raises:
    """The census ran at a 1024-row morsel, and this reconstructs
    WHY from the retired formula — it is a check on the MEASUREMENT, so it is
    deliberately computed from `l1d_cache_bytes` rather than from the live
    policy (which no longer uses that field)."""
    print("== test_census_era_width_was_the_min_clamp ==")
    var profile = detect_hardware_profile()
    var policy = MorselSizingPolicy(profile.copy())
    var schema = _hits_file_schema()
    var row_w = schema.row_width_bytes()

    # Reproduce the RETIRED formula's UNCLAMPED term. `l1d_cache_bytes` is
    # still probed and still real; it is simply no longer the sizing input.
    # (It was never `l1d_min_bytes`, which the module header's "single source
    # of truth" formula named — that doc/code drift was itself a finding,
    #, and the L1d arm is gone now either way.)
    var l1d = profile.l1d_cache_bytes
    var base = (l1d // 2) // row_w
    var unclamped = Int(Float64(base) * TIER_MULT_DEFAULT)
    var shipped = policy.default_morsel_rows(schema)

    print("  l1d_cache_bytes       =", l1d)
    print("  row_width_bytes       =", row_w, "(expected 92)")
    print("  unclamped L1d term    =", unclamped, "(RETIRED formula)")
    print("  MIN clamp             =", MIN_MORSEL_ROWS_DEFAULT)
    print("  MAX clamp             =", MAX_MORSEL_ROWS_DEFAULT)
    print("  SHIPPED default_morsel_rows =", shipped)

    if row_w != HITS_N_INT64 * 8 + HITS_N_INT32 * 4:
        raise Error(
            "hits row_width_bytes is " + String(row_w)
            + ", expected " + String(HITS_N_INT64 * 8 + HITS_N_INT32 * 4)
            + " — the fixture geometry this derivation rests on changed"
        )
    if unclamped >= MIN_MORSEL_ROWS_DEFAULT:
        raise Error(
            "the RETIRED L1d term is " + String(unclamped)
            + " >= MIN " + String(MIN_MORSEL_ROWS_DEFAULT)
            + ": on this machine the census-era formula would NOT have hit the"
            " MIN clamp, so the 1024 this file's derivation rests on is not"
            " reconstructible here — re-derive against the census box"
        )
    if MIN_MORSEL_ROWS_DEFAULT != CENSUS_ERA_MORSEL_ROWS:
        raise Error(
            "MIN_MORSEL_ROWS_DEFAULT moved to "
            + String(MIN_MORSEL_ROWS_DEFAULT)
            + "; the census ran at " + String(CENSUS_ERA_MORSEL_ROWS)
            + " so the derivation below no longer describes it"
        )
    if shipped == CENSUS_ERA_MORSEL_ROWS:
        print(
            "  NOTE: the SHIPPED width equals the census-era one here, so this"
            " machine cannot show the YYYY-MM-DD change"
        )
    print("  => the census-era morsel width WAS the MIN clamp (1024)")
    print("  => the SHIPPED width is", shipped, "— sized off the L2 share")
    print("  PASS")


def test_derived_morsel_count_matches_census() raises:
    """THE FALSIFIER for the whole mechanism. If cb20's 94,272 morsels came
    from anything other than `rows / morsel_rows` over one full scan, this
    number does not reproduce the census.

    Uses the CENSUS-ERA width (1024). See the note at the call site."""
    print("== test_derived_morsel_count_matches_census ==")
    # THE CENSUS-ERA WIDTH, not the live one: this leg checks a MEASUREMENT
    # taken, and recomputing it from today's policy would turn a
    # falsifier into a tautology that moves whenever the formula does.
    var morsel_rows = CENSUS_ERA_MORSEL_ROWS
    var derived = (HITS_ROWS + morsel_rows - 1) // morsel_rows
    var per_rg = (derived + HITS_ROW_GROUPS - 1) // HITS_ROW_GROUPS

    # What the SHIPPED width predicts for the same scan — printed, never
    # asserted against the census, because it has not been measured.
    var policy = MorselSizingPolicy(detect_hardware_profile())
    var shipped_rows = policy.default_morsel_rows(_hits_file_schema())
    var shipped_derived = (HITS_ROWS + shipped_rows - 1) // shipped_rows
    print("  SHIPPED morsel_rows    =", shipped_rows,
          " => predicted count", shipped_derived, "(UNMEASURED)")

    print("  census-era morsel_rows =", morsel_rows)
    print("  derived full-scan count=", derived)
    print("  census probe-side count=", CENSUS_PROBE_MORSELS)
    print("  census build-side count=", CENSUS_BUILD_MORSELS)
    print("  census total           =", CENSUS_PROBE_MORSELS
          + CENSUS_BUILD_MORSELS)
    print("  sub-morsels per ROW GROUP =", per_rg,
          "(the sort docstring's design case assumes 16)")

    # Within 5%: the observed probe count is slightly BELOW a full scan because
    # zero-match morsels are dropped by `consume_morsel` and the SEMI bloom
    # prunes some pages.
    var diff = derived - CENSUS_PROBE_MORSELS
    if diff < 0:
        diff = -diff
    var tol = CENSUS_PROBE_MORSELS // 20
    print("  |derived - census| =", diff, " tol(5%) =", tol)
    if diff > tol:
        raise Error(
            "derived full-scan morsel count " + String(derived)
            + " is not within 5% of the census's observed "
            + String(CENSUS_PROBE_MORSELS)
            + " — cb20's morsel count is NOT simply rows/morsel_rows, so the"
            " mechanism needs re-deriving before any lever is aimed at it"
        )
    print("  PASS")


def test_file_schema_vs_projected_schema_sizing_gap() raises:
    """Quantifies the second-order defect: the morsel width is derived from the
    FULL FILE schema even though the scan decodes a narrow projection."""
    print("== test_file_schema_vs_projected_schema_sizing_gap ==")
    var policy = MorselSizingPolicy(detect_hardware_profile())
    var file_rows = policy.default_morsel_rows(_hits_file_schema())
    var proj_rows = policy.default_morsel_rows(_build_side_projected_schema())

    var file_count = (HITS_ROWS + file_rows - 1) // file_rows
    var proj_count = (HITS_ROWS + proj_rows - 1) // proj_rows

    print("  sized off FILE schema      (92 B/row): rows/morsel=", file_rows,
          " => morsels=", file_count)
    print("  sized off PROJECTED schema (12 B/row): rows/morsel=", proj_rows,
          " => morsels=", proj_count)
    if proj_rows < file_rows:
        raise Error(
            "sizing off the narrower PROJECTED schema produced a SMALLER"
            " morsel (" + String(proj_rows) + " < " + String(file_rows)
            + ") — that inverts the formula's direction; re-read it"
        )
    if proj_rows == file_rows:
        print("  => NO GAP on this machine: both land on the MIN clamp, so the")
        print("     file-vs-projected input is NOT a lever here.")
    else:
        print("  => projected-schema sizing would cut the morsel count",
              file_count // proj_count, "x. Real but bounded; NOT the 46x.")
    print("  PASS")


def test_hw_morsel_l2_path_is_the_default() raises:
    """The morsel budget IS the `l2_per_worker / 2` one — pin it here, because
    every number this file derives depends on which formula ships.

    ⚠ THIS TEST USED TO ASSERT THE OPPOSITE. Previously the L2 budget sat
    behind `KOMIRA_HW_MORSEL_L2` (default OFF) and this case pinned the L1d
    arm by asserting cb20's morsel landed on MIN_MORSEL_ROWS_DEFAULT. The gate
    and the L1d arm are deleted; the assertion is inverted rather than removed,
    so the file still fails loudly if the sizing input changes again."""
    print("== test_hw_morsel_l2_path_is_the_default ==")
    var profile = detect_hardware_profile()
    var policy = MorselSizingPolicy(profile.copy())
    var schema = _hits_file_schema()
    var row_w = schema.row_width_bytes()
    var actual = policy.default_morsel_rows(schema)

    var l2pw = profile.effective_e_core_l2_per_worker()
    var l2_budget = l2pw // 2
    var l2_base = l2_budget // row_w
    var l2_expected = Int(Float64(l2_base) * TIER_MULT_DEFAULT)
    if l2_expected < MIN_MORSEL_ROWS_DEFAULT:
        l2_expected = MIN_MORSEL_ROWS_DEFAULT
    if l2_expected > MAX_MORSEL_ROWS_DEFAULT:
        l2_expected = MAX_MORSEL_ROWS_DEFAULT

    # The retired arm, computed only so the failure message can say how far
    # off the shipped answer would be if it ever came back.
    var l1d_base = (profile.l1d_cache_bytes // 2) // row_w
    var l1d_would_be = Int(Float64(l1d_base) * TIER_MULT_DEFAULT)
    if l1d_would_be < MIN_MORSEL_ROWS_DEFAULT:
        l1d_would_be = MIN_MORSEL_ROWS_DEFAULT
    if l1d_would_be > MAX_MORSEL_ROWS_DEFAULT:
        l1d_would_be = MAX_MORSEL_ROWS_DEFAULT

    print("  effective_e_core_l2_per_worker =", l2pw)
    print("  L2  path (LIVE default) rows/morsel =", actual)
    print("  L1d path (RETIRED)      rows/morsel =", l1d_would_be)
    print("  L2 -path morsels =", (HITS_ROWS + actual - 1) // actual)
    print("  L1d-path morsels =", (HITS_ROWS + l1d_would_be - 1) // l1d_would_be)

    if actual != l2_expected:
        raise Error(
            "the LIVE default did not produce the L2-per-worker answer ("
            + String(actual) + " vs " + String(l2_expected)
            + ") — the sizing input moved; this file's derivation assumes"
            " the L2-per-worker budget"
        )
    if l2_expected == l1d_would_be:
        print(
            "  NOTE: on this machine both formulas agree ("
            + String(l2_expected) + "), so this case cannot discriminate"
            " between them here — it still pins the shipped value."
        )
    print("  PASS")


def main() raises:
    test_census_era_width_was_the_min_clamp()
    test_derived_morsel_count_matches_census()
    test_file_schema_vs_projected_schema_sizing_gap()
    test_hw_morsel_l2_path_is_the_default()
    print("ALL PASS: test_cb20_morsel_count_mechanism")
