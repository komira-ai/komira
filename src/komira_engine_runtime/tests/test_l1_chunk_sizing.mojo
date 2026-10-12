# =============================================================================
# L1-CHUNK sizing + ADMISSION unit tests (PERF-L1-CHUNK path 1 + PHASE 3)
# =============================================================================
#
# Falsifies BOTH halves of the decision in
# `komira_engine_runtime/morsel_sizing_policy.mojo`, which are two separate
# questions and were conflated:
#
#   (b) WHETHER  admit  = fold_passes >= MIN_FOLD_PASSES  AND  budget > 0
#   (a) SIZE     budget = 2 * l2 - max(resident, budget/4)
#                rows   = round_down_64(budget / live_row_width),
#                         DECLINE below 2048, clamp at 16384
#
# Every expectation below is written as ARITHMETIC ON A KNOWN L2, not as a
# re-run of the implementation, so a change to the constants breaks the test.
#
# WHAT PHASE 3 ADDED, AND WHAT EACH TEST IS GUARDING:
#
#   * `test_admit_*` — the amortisation conjunct. This is the ONLY thing that
#     separates tpch q1 (8 aggregates, chunking wins 17.5%) from h2o/q02 and
#     sdk/b1_agg_lowcard (1 aggregate each, chunking loses 50.3% and 2.8%).
#     Group cardinality CANNOT do it: b1 has ten groups and still loses.
#   * `test_resident_state_unknown_abstains` — the `est_groups < 0` fix. UNKNOWN
#     used to be spelled `0` ("the table is empty"), so a guard that exists to
#     DECLINE had ADMIT as its failure mode on missing information.
#   * `test_floor_is_a_decline_not_a_clamp` — a computed count below 2048 used
#     to be clamped UP, converting "I cannot make this resident" into "I will
#     chunk it anyway at a size the sweep prices at +242% on h2o/q02".
#
# ⚑ THE DEFAULT-OFF ASSERTIONS ARE GONE, BECAUSE THE FLAG IS.
# `test_l1_chunk_default_off` / `test_force_default_off` pinned that an unset
# environment reached neither arm. There is no environment to be unset now:
# `KOMIRA_L1_CHUNK` and `KOMIRA_L1_CHUNK_FORCE` are DELETED and chunking is
# unconditional, so the safety claim moved from "the flag is inert" to "the
# PREDICATE declines correctly". The two replacements below are what carry it:
#   * `test_admission_is_the_only_gate` — the shipped path, with no argument
#     overridden, DECLINES the 1-pass cell and ADMITS the 8-pass one. This is
#     the assertion the deleted default-off test used to make from the outside.
#   * `test_force_admit_is_not_reachable_by_default` — the bypass is a defaulted
#     PARAMETER, so a caller that does not name it cannot get it. That is a
#     stronger claim than the old one: it is checked by the type system rather
#     than by a process's environment.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_engine_runtime.hardware import HardwareProfile
from komira_engine_runtime.l1_chunk_sizing import (
    L1_CHUNK_BUDGET_DEN,
    L1_CHUNK_BUDGET_NUM,
    L1_CHUNK_DECLINE,
    L1_CHUNK_GRAIN,
    L1_CHUNK_MAX_ROWS,
    L1_CHUNK_MIN_FOLD_PASSES,
    L1_CHUNK_MIN_ROWS,
    L1_CHUNK_RESERVE_DEN,
    L1_CHUNK_RESERVE_NUM,
    L1_CHUNK_STATE_UNKNOWN,
    l1_chunk_admit,
    l1_chunk_grain_round,
)
from komira_engine_runtime.morsel_sizing_policy import (
    MorselSizingPolicy,
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

comptime _L2: Int = 256 * 1024  # the Broadwell / x86 measurement target
comptime _BASE: Int = (_L2 * L1_CHUNK_BUDGET_NUM) // L1_CHUNK_BUDGET_DEN
comptime _RESERVE: Int = (_BASE * L1_CHUNK_RESERVE_NUM) // L1_CHUNK_RESERVE_DEN
comptime _BUDGET: Int = _BASE - _RESERVE  # 524288 - 131072 = 393216

# A pass count that clears the amortisation conjunct, so the SIZE tests below
# isolate question (a). tpch q1's real count is 8.
comptime _Q1_PASSES: Int = 8


def _policy_with_l2(l2: Int) -> MorselSizingPolicy:
    """A policy whose ONLY load-bearing field is `l2_cache_bytes`."""
    return MorselSizingPolicy(
        HardwareProfile(
            4, 4, 32 * 1024, l2, 0, 64, 1 << 30, 1 << 29, 1,
        )
    )


def _p() -> MorselSizingPolicy:
    return _policy_with_l2(_L2)


def _rows(w: Int, resident: Int = L1_CHUNK_STATE_UNKNOWN) -> Int:
    """`l1_chunk_rows` at a pass count that always amortises, so the SIZE tests
    are not silently answering the WHETHER question."""
    return _p().l1_chunk_rows(w, resident, _Q1_PASSES)


# -----------------------------------------------------------------------------
# 1 — THE PREDICATE IS THE ONLY GATE (replaces the two default-OFF pins)
# -----------------------------------------------------------------------------


def test_admission_is_the_only_gate() raises:
    """DEFAULT-ON, NO FLAG. Nothing here overrides anything: this
    is the shipped call, and the two answers come only from the predicate.

    This is the assertion that replaces `test_l1_chunk_default_off`. That test
    could pass while the predicate was broken, because an inert flag makes every
    cell take the old path. Now a broken predicate is a corpus regression, so
    what has to be pinned is that the DECLINE still happens: the 1-pass cell
    (h2o/q02's shape, +50.3% if admitted) must get the shipped sizing back.
    """
    assert_equal(
        _p().l1_chunk_rows(24, L1_CHUNK_STATE_UNKNOWN, 1), L1_CHUNK_DECLINE
    )
    assert_true(_p().l1_chunk_rows(54, L1_CHUNK_STATE_UNKNOWN, 8) > 0)


def test_force_admit_is_not_reachable_by_default() raises:
    """The admission bypass is a DEFAULTED PARAMETER, not an env probe.

    The bypass exists only to reproduce the historical override sweeps, which
    priced a SIZE curve on a universally-admitted binary. gate_verify says
    the override must never be the shipping path. Pinning that as a parameter
    is strictly stronger than the deleted `test_force_default_off`: an
    environment could be set by anything that spawns the process, whereas a
    caller that does not write `force_admit=True` provably cannot reach the arm.
    """
    # Same declining cell as above; the ONLY difference is the named argument.
    assert_equal(
        _p().l1_chunk_rows(24, L1_CHUNK_STATE_UNKNOWN, 1), L1_CHUNK_DECLINE
    )
    assert_true(
        _p().l1_chunk_rows(24, L1_CHUNK_STATE_UNKNOWN, 1, force_admit=True) > 0
    )


def test_min_passes_is_a_parameter_not_an_environment() raises:
    """`KOMIRA_L1_CHUNK_MIN_PASSES` is deleted; the threshold is an argument.

    `L1_CHUNK_MIN_FOLD_PASSES = 4` is FITTED TO FOUR POINTS and nothing in 2..7
    is measured, so the sweep that settles it still has to happen — it just
    costs a recompile per arm now instead of an env var. This pins that the
    knob still exists in the shape the next phase needs.
    """
    assert_false(l1_chunk_admit(2, 4096))
    assert_true(l1_chunk_admit(2, 4096, min_passes=2))


# -----------------------------------------------------------------------------
# 2 — (b) WHETHER: the AMORTISATION conjunct
# -----------------------------------------------------------------------------


def test_admit_requires_enough_fold_passes() raises:
    """THE CONJUNCT THAT DISCRIMINATES. Chunking multiplies a fixed per-chunk
    split cost by `rows / chunk_rows`, and only re-traversal repays it. A fold
    that walks the chunk once has nothing to re-traverse.

    Measured: 8 passes -> q1 -17.5%; 1 pass -> h2o/q02 +50.3% (and monotonically
    worse at every smaller size) and sdk/b1_agg_lowcard +2.8%.
    """
    assert_equal(L1_CHUNK_MIN_FOLD_PASSES, 4)
    assert_true(l1_chunk_admit(8, _BUDGET))  # tpch q1
    assert_false(l1_chunk_admit(1, _BUDGET))  # h2o/q02, sdk/b1
    assert_false(l1_chunk_admit(3, _BUDGET))
    assert_true(l1_chunk_admit(4, _BUDGET))


def test_admit_treats_unknown_pass_count_as_not_amortising() raises:
    """A pass count of 0 or less is UNKNOWN, and unknown must never ADMIT.

    This is the same rule as the residency abstain, applied to the other
    conjunct: absence of evidence is not evidence of amortisation.
    """
    assert_false(l1_chunk_admit(0, _BUDGET))
    assert_false(l1_chunk_admit(-1, _BUDGET))


def test_admit_requires_a_live_budget() raises:
    """A dead budget (bad probe / resident state over the budget) declines no
    matter how many passes the fold makes."""
    assert_false(l1_chunk_admit(64, 0))
    assert_false(l1_chunk_admit(64, -1))


def test_amortisation_declines_before_any_size_is_computed() raises:
    """The predicate is not advisory: a one-aggregate leaf gets DECLINE from
    `l1_chunk_rows` even though its SIZE would have been perfectly computable.

    h2o/q02: live width 24 B -> 393216/24 = 16384 rows, a number the size half
    of this policy is happy to produce. It must not be used.
    """
    assert_equal(_p().l1_chunk_rows(24, L1_CHUNK_STATE_UNKNOWN, 8), 16384)
    assert_equal(
        _p().l1_chunk_rows(24, L1_CHUNK_STATE_UNKNOWN, 1), L1_CHUNK_DECLINE
    )


def test_width_alone_cannot_answer_whether_and_discriminates_backwards() raises:
    """THE MEASUREMENT THAT FORCED THE DEVIATION FROM SIZING-BY-WIDTH ALONE.

    h2o/q02's live set is NARROWER than tpch q1's (24 B vs 54 B, both measured
    from the shipped binary under `KOMIRA_L1_CHUNK_TRACE=1`), so a pure width
    formula hands the cell that must NOT be chunked the LARGER chunk. Width
    answers (a) and only (a); if it could answer (b) this assertion would be
    the other way round.
    """
    var q1_rows = _p().l1_chunk_rows(54, L1_CHUNK_STATE_UNKNOWN, 8)
    var q02_rows_if_admitted = _p().l1_chunk_rows(24, L1_CHUNK_STATE_UNKNOWN, 8)
    assert_true(q02_rows_if_admitted > q1_rows)
    # ... and only the pass count puts them on the right sides.
    assert_true(_p().l1_chunk_rows(54, L1_CHUNK_STATE_UNKNOWN, 8) > 0)
    assert_equal(
        _p().l1_chunk_rows(24, L1_CHUNK_STATE_UNKNOWN, 1), L1_CHUNK_DECLINE
    )


# -----------------------------------------------------------------------------
# 3 — the budget, and the THREE-STATE resident-state contract
# -----------------------------------------------------------------------------


def test_budget_is_sited_on_l2_not_l1d() raises:
    """The base moved off `l1d_cache_bytes`. The old base gave q1 448 rows —
    the far left of the measured sweep, past the crossover where our per-chunk
    split cost dominates."""
    assert_equal(L1_CHUNK_BUDGET_NUM, 2)
    assert_equal(L1_CHUNK_BUDGET_DEN, 1)
    assert_equal(_BASE, 512 * 1024)
    assert_equal(_RESERVE, 128 * 1024)
    assert_equal(_BUDGET, 393216)
    # A policy whose L1d differs but whose L2 is the same gets the same budget.
    var odd_l1d = MorselSizingPolicy(
        HardwareProfile(4, 4, 999 * 1024, _L2, 0, 64, 1 << 30, 1 << 29, 1)
    )
    assert_equal(
        odd_l1d.l1_chunk_budget_bytes(L1_CHUNK_STATE_UNKNOWN), _BUDGET
    )


def test_resident_state_unknown_abstains() raises:
    """THE `est_groups < 0` FIX. UNKNOWN keeps the reserve at its floor and
    expresses NO residency opinion — it neither declines nor vouches.

    It used to be spelled `0`, which reads as "measured: the table is empty",
    i.e. "definitely small, ADMIT". A guard whose failure mode on missing
    information is ADMIT is not a guard, and that is exactly why tpch q1 (gains
    17%) and h2o/q02 (loses 50%) were indistinguishable to it — `est_groups` is
    -1 on both.
    """
    assert_equal(
        _p().l1_chunk_budget_bytes(L1_CHUNK_STATE_UNKNOWN), _BUDGET
    )
    # UNKNOWN and "measured empty" now produce the same BUDGET but are
    # different STATEMENTS; the distinction is load-bearing in the trace and in
    # `_agg_leaf_resident_state_bytes`, which no longer collapses them.
    assert_equal(_p().l1_chunk_budget_bytes(0), _BUDGET)
    assert_true(L1_CHUNK_STATE_UNKNOWN < 0)


def test_budget_grows_with_known_resident_state() raises:
    """A caller-supplied resident state ABOVE the floor widens the reserve."""
    assert_equal(_p().l1_chunk_budget_bytes(256 * 1024), 256 * 1024)
    # Below the floor -> the floor still applies (reserve is a max()).
    assert_equal(_p().l1_chunk_budget_bytes(256), _BUDGET)


def test_budget_declines_when_state_exceeds_the_base() raises:
    """THE HIGH-CARDINALITY GUARD. A hash table at or beyond the budget base
    means no chunk size can make the column streams resident -> DECLINE, and
    the caller keeps `_coalesced_morsel_rows`. This is what protects hc1/hc2/hc3
    (800K+ groups x ~40 B/slot = tens of MB -> budget 0).

    ⚠ IT IS **NOT** WHAT DECLINES h2o/q02, and saying otherwise would be the
    convenient story rather than the arithmetic. With the PHASE 3 estimator q02
    resolves to 10,000 groups x 40 B/slot = 400 KB, which is UNDER the 512 KiB
    base: the reserve grows to hold it and the budget survives at 124,288 B.
    Residency ADMITS q02. Only the amortisation conjunct declines it — which is
    the entire reason amortisation had to exist, and the reason a better
    `est_groups` alone would not have fixed the corpus gate."""
    assert_equal(_p().l1_chunk_budget_bytes(_BASE), 0)
    assert_equal(_p().l1_chunk_budget_bytes(800 * 1000 * 1000), 0)
    # ... and the rows accessor propagates the decline even at a q1 pass count.
    assert_equal(_rows(48, 800 * 1000 * 1000), L1_CHUNK_DECLINE)


def test_budget_declines_on_implausible_probe() raises:
    """A hardware probe that returns a sub-KiB L2 is not a budget."""
    assert_equal(
        _policy_with_l2(256).l1_chunk_budget_bytes(L1_CHUNK_STATE_UNKNOWN), 0
    )
    assert_equal(
        _policy_with_l2(0).l1_chunk_rows(8, L1_CHUNK_STATE_UNKNOWN, 8),
        L1_CHUNK_DECLINE,
    )


# -----------------------------------------------------------------------------
# 4 — grain, ceiling, and the floor-is-a-DECLINE change
# -----------------------------------------------------------------------------


def test_grain_rounds_down_to_64() raises:
    assert_equal(L1_CHUNK_GRAIN, 64)
    assert_equal(l1_chunk_grain_round(4096), 4096)
    assert_equal(l1_chunk_grain_round(4095), 4032)
    assert_equal(l1_chunk_grain_round(2100), 2048)


def test_floor_is_a_decline_not_a_clamp() raises:
    """CHANGED, and this is the assertion that pins it.

    A computed count below `L1_CHUNK_MIN_ROWS` used to be clamped UP to 256,
    silently converting "I cannot make this live set resident at any size I
    have evidence for" into "I will chunk it anyway". The sweep prices 1024
    rows at q1 -7.01% (under half the available win) and h2o/q02 +242.88%.
    2048 is DuckDB's own `STANDARD_VECTOR_SIZE` — the chunk they run EVERY
    kernel at, and which they can afford because their re-chunk is a pointer
    reinterpret while ours allocates and memcpys.
    """
    assert_equal(L1_CHUNK_MIN_ROWS, 2048)
    assert_equal(l1_chunk_grain_round(2048), 2048)
    assert_equal(l1_chunk_grain_round(2047), L1_CHUNK_DECLINE)
    assert_equal(l1_chunk_grain_round(1024), L1_CHUNK_DECLINE)
    assert_equal(l1_chunk_grain_round(1), L1_CHUNK_DECLINE)


def test_ceiling_holds_at_the_right_edge_of_the_measured_plateau() raises:
    """16384 is not an L2 argument, it is the right-hand edge of the measured
    q1 plateau (-17.52% there, -15.24% at 32768). Letting the number run to
    6-digit chunk sizes would silently re-create the row-group-sized chunk this
    path exists to stop."""
    assert_equal(L1_CHUNK_MAX_ROWS, 16384)
    assert_equal(l1_chunk_grain_round(1 << 20), L1_CHUNK_MAX_ROWS)
    assert_equal(_rows(1), L1_CHUNK_MAX_ROWS)


# -----------------------------------------------------------------------------
# 5 — the Q1 worked example (the number this whole path exists to produce)
# -----------------------------------------------------------------------------


def test_q1_live_width_54_lands_in_the_measured_plateau() raises:
    """THE FALSIFIABLE PREDICTION OF THIS LANDING, WRITTEN BEFORE MEASURING.

    q1's live set measures 54 B/row over 8 live columns (from the shipped
    binary under `KOMIRA_L1_CHUNK_TRACE=1`). 393216 / 54 = 7281 -> 7232 rows.
    The override sweep priced 4096 at -15.99%, 8192 at -17.11% and 16384 at
    -17.52%, so the principled form sits inside the plateau and should land at
    -16% to -17.5%. IF THE MEASURED PRINCIPLED ARM DOES NOT REPRODUCE THAT, THE
    GAP IS THE FINDING — it would mean the override was buying something other
    than its row count, and gate_verify says that gap is exactly what must
    not be papered over.
    """
    assert_equal(_BUDGET // 54, 7281)
    assert_equal(_rows(54), 7232)
    assert_true(_rows(54) >= 4096)
    assert_true(_rows(54) <= 16384)


def test_row_store_width_would_have_given_a_different_answer() raises:
    """The live-width model is load-bearing, not cosmetic.

    The same budget against q1's 116 B ROW-STORE width yields 3389 -> 3328
    rows, vs 7232 from the LIVE width. If the two agreed, sizing from the live
    set would be pointless. (Under the old L1d-sited budget the row-store width
    fell through the floor entirely — the difference was even starker, but for
    the wrong reason: both answers were in the bad region of the curve.)
    """
    assert_equal(_BUDGET // 116, 3389)
    assert_equal(_rows(116), 3328)
    assert_true(_rows(116) != _rows(54))


# -----------------------------------------------------------------------------
# 6 — DEGRADATION cases
# -----------------------------------------------------------------------------


def test_degradation_thirty_columns_still_sizes() raises:
    """30 x i64 = 240 B/row -> 393216/240 = 1638 rows, which is BELOW the 2048
    floor -> DECLINE. At 30 live columns we deliberately stop claiming
    residency rather than chunk into a size the measurements price as a loss."""
    assert_equal(_BUDGET // 240, 1638)
    assert_equal(_rows(240), L1_CHUNK_DECLINE)
    # One column narrower is back inside the floor.
    assert_equal(_BUDGET // 176, 2234)
    assert_equal(_rows(176), 2176)


def test_degradation_fat_string_column() raises:
    """A 4 KB-per-row string column fits ONE row in the budget, so it sizes to
    96 rows — far below the floor -> DECLINE. A row that does not fit at all
    (> 393216 B) has no answer either."""
    assert_equal(_rows(4096), L1_CHUNK_DECLINE)
    assert_equal(_rows(_BUDGET), L1_CHUNK_DECLINE)
    assert_equal(_rows(_BUDGET + 1), L1_CHUNK_DECLINE)


# -----------------------------------------------------------------------------
# 7 — monotonicity (a wider live set never gets a wider chunk)
# -----------------------------------------------------------------------------


def test_wider_live_set_never_widens_the_chunk() raises:
    """Holds across the DECLINE boundary too: once the floor turns into a
    decline the answer is 0, which is still <= every preceding answer."""
    var prev = _rows(1)
    for w in range(2, 400):
        var cur = _rows(w)
        assert_true(cur <= prev)
        prev = cur


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------


def test_forced_rows_overrides_size_but_not_admission() raises:
    """`forced_rows` is the SIZE override and the null control: it returns the
    given row count verbatim (un-clamped) on an admitted cell, and it does NOT
    grant admission to a declined one -- `force_admit` does that."""
    # Admitted cell: the override wins over the computed size, verbatim.
    assert_equal(
        _p().l1_chunk_rows(54, L1_CHUNK_STATE_UNKNOWN, _Q1_PASSES, forced_rows=122880),
        122880,
    )
    # Declined cell (1 pass): forcing a size alone does not admit it.
    assert_equal(
        _p().l1_chunk_rows(24, L1_CHUNK_STATE_UNKNOWN, 1, forced_rows=4096),
        L1_CHUNK_DECLINE,
    )
    # Declined cell + force_admit: now the forced size is returned.
    assert_equal(
        _p().l1_chunk_rows(
            24, L1_CHUNK_STATE_UNKNOWN, 1, force_admit=True, forced_rows=4096
        ),
        4096,
    )
    # Zero means "no override": the computed size comes back.
    assert_equal(
        _p().l1_chunk_rows(54, L1_CHUNK_STATE_UNKNOWN, _Q1_PASSES, forced_rows=0),
        _rows(54),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
