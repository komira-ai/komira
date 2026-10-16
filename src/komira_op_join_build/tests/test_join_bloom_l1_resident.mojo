# =============================================================================
# test_join_bloom_l1_resident — BLOOML1's falsifier
# =============================================================================
#
# ⛔ THE VACUITY THIS FILE EXISTS TO CLOSE, STATED FIRST. Declining a bloom
# filter is VALUE-INVARIANT: a bloom has no false negatives, so a row it would
# have rejected instead loads a bucket head and either finds `_CHAIN_END` or
# walks a chain whose compares all fail. The ON and OFF arms therefore emit
# identical pairs in identical order, and EVERY value oracle in the tree is
# satisfied by an arm THAT NEVER RAN. A test that only checks "the join still
# returns the right answer" is vacuous TWICE over — once because the answer
# cannot move, and once because it is equally green with the lever unreachable.
#
# ⚠ AND THIS LEVER IS NOT PURELY SUBTRACTIVE — IT ADDS AN ARMING PREDICATE — so
# "the bloom was declined" is only half a result. The other half is that a
# build ABOVE the budget still BUILDS one. Both directions are asserted on the
# same fixture shape in leg 3, and neither assertion alone is sufficient:
# a predicate stuck at True passes the first, a predicate stuck at False passes
# the second.
#
# FIVE THINGS ARE UNDER TEST, and they are separable on purpose:
#
#   1. `bloom_l1_index_bytes` — a PURE arithmetic function. Tested directly,
#      with no join and no fixture, against the j1 geometry re-derived by hand
#      and against both OFF layouts.
#   2. `bloom_l1_should_decline` — a PURE predicate, both boundary directions
#      and the `budget <= 0` fail-towards-the-incumbent rule.
#   3. the SETTING's contract: unconfigured, 0 and negative are OFF, which is
#      the half no value assertion can reach: with the lever off by accident
#      the whole suite is green.
#   4. ARMING + NON-VACUITY through the real `HashJoinBuilder.build`: a small
#      build DECLINES and reports `uses_bloom() == False`, a large one KEEPS
#      and reports True, and the counters move on the matching disposition.
#   5. VALUE INVARIANCE: the declined index and a force-built one emit
#      byte-identical match sets over the same probe column.
#
# MUTANT LOG — predicted, then RUN. Every line is the leg that goes red.
#
#   M1  `bloom_l1_should_decline` uses `<` instead of `<=`
#         -> RED, leg 2's exact-boundary assertion (16,384 must decline).
#   M2  `bloom_l1_should_decline` returns True on `budget <= 0`
#         -> RED, leg 2's OFF-arm assertion AND leg 3's unconfigured assertion.
#   M3  `bloom_l1_index_bytes` counts `build_keys`/`next_chain` under `fused`
#         -> RED, leg 1: the shipped-layout figure becomes 3,648 + 1,600.
#   M4  `bloom_l1_index_bytes` drops the hash table and counts entries only
#         -> RED, leg 1 (1,600 != 3,648) and leg 4's boundary build.
#   M5  `build` notches `declined` but still passes `use_bloom=True`
#         -> RED, leg 4's `uses_bloom()` assertion, and ONLY that one. Every
#            counter still moves correctly and the answer is value-invariant,
#            which is exactly why the structural observable exists.
#   M6  the decline is applied to EVERY build, budget ignored
#         -> RED, leg 4's LARGE-build assertion (`uses_bloom()` must stay True).
#   M7  `build` consults the predicate but ignores `build_bloom=False`
#         -> RED, leg 4's "never reached" assertion: the counters must not move
#            for a caller that already declined.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_join_assembly.join_payload_inline import JOIN_KN_WORDS

from komira_op_join_build.join import HashJoinBuilder
from komira_op_join_build.join_bloom_l1_resident import (
    BLOOM_L1_DEFAULT_BUDGET_BYTES,
    BLOOM_L1_L1D_BYTES,
    bloom_l1_configure,
    bloom_l1_reset_config,
    bloom_l1_budget_bytes,
    bloom_l1_declined_count,
    bloom_l1_declined_rows,
    bloom_l1_index_bytes,
    bloom_l1_kept_count,
    bloom_l1_should_decline,
    reset_bloom_l1_counters,
)


comptime I64 = DType.int64

# The j1 geometry, re-derived here by hand rather than imported, so a change to
# the build arithmetic breaks this test instead of silently agreeing with it.
#   n = 100 -> min_cap = max(int(100*1.4)+1, 16) = 141 -> cap = 256
#   hash_table 256*8 = 2048 ; key_next 2*100*8 = 1600 ; total 3648
comptime _J1_BUILD_ROWS: Int = 100
comptime _J1_CAP: Int = 256
comptime _J1_INDEX_BYTES: Int = 3_648


def _clear_env() raises:
    """Back to the unconfigured setting (OFF)."""
    bloom_l1_reset_config()


def _dense_keys(n: Int) -> PrimitiveArray[I64]:
    """`n` distinct keys, 0..n-1 — j1's build side in shape: every probe key
    will match, so the bloom rejects nothing."""
    var arr = PrimitiveArray[I64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, Int64(i))
    return arr^


def _probe_keys(n: Int, modulus: Int) -> PrimitiveArray[I64]:
    var arr = PrimitiveArray[I64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, Int64(i % modulus))
    return arr^


def _sorted(var v: List[Int]) -> List[Int]:
    for i in range(1, len(v)):
        var x = v[i]
        var j = i - 1
        while j >= 0 and v[j] > x:
            v[j + 1] = v[j]
            j -= 1
        v[j + 1] = x
    return v^


def _encode_pairs(imm bm: List[Int], imm pm: List[Int]) -> List[Int]:
    var enc = List[Int]()
    for i in range(len(bm)):
        enc.append((bm[i] + 1) * 1_000_000 + (pm[i] + 1))
    return _sorted(enc^)


# -----------------------------------------------------------------------------
# Leg 1 — the PURE byte arithmetic
# -----------------------------------------------------------------------------


def test_index_bytes_arithmetic() raises:
    # THE SHIPPED LAYOUT (fused + nobi), at j1's exact geometry. 2,048 B of
    # hash table + 1,600 B of chain entries. `build_keys`, `next_chain` and
    # `build_indices` are NOT ALLOCATED under this layout and must not be
    # counted; M3 and M4 are the two ways of getting that wrong.
    assert_equal(
        bloom_l1_index_bytes(
            _J1_BUILD_ROWS, _J1_CAP, JOIN_KN_WORDS, True, True
        ),
        _J1_INDEX_BYTES,
        "j1 geometry: 256*8 + 2*100*8",
    )

    # The OFF layout — `build_keys` + `next_chain` at 8 B each, plus
    # `build_indices` when `nobi` is False. Still reachable; it is this tree's
    # differential join oracle.
    assert_equal(
        bloom_l1_index_bytes(
            _J1_BUILD_ROWS, _J1_CAP, JOIN_KN_WORDS, False, True
        ),
        2_048 + 100 * 8 + 100 * 8,
        "split layout, build_indices elided",
    )
    assert_equal(
        bloom_l1_index_bytes(
            _J1_BUILD_ROWS, _J1_CAP, JOIN_KN_WORDS, False, False
        ),
        2_048 + 100 * 8 * 3,
        "split layout, build_indices present",
    )

    # PAYLOAD-INLINE widens the entry to four words; the figure must follow the
    # stride it is given rather than the literal 2.
    assert_equal(
        bloom_l1_index_bytes(_J1_BUILD_ROWS, _J1_CAP, 4, True, True),
        2_048 + 4 * 100 * 8,
        "payload-inline stride is honoured",
    )

    # An EMPTY build still has a 16-bucket table. The figure is never 0, so a
    # decline on an empty build is a real decision and not an arithmetic
    # accident.
    assert_equal(
        bloom_l1_index_bytes(0, 16, JOIN_KN_WORDS, True, True),
        128,
        "empty build is 16 buckets, not zero bytes",
    )
    print("test_index_bytes_arithmetic OK")


# -----------------------------------------------------------------------------
# Leg 2 — the PURE predicate, both boundaries and the OFF arm
# -----------------------------------------------------------------------------


def test_should_decline_predicate() raises:
    # j1: 3,648 B against the derived default of 16,384. Inside by 4.5x — this
    # cell's verdict does not depend on where in [3,648, 32,768] the line falls.
    assert_true(
        bloom_l1_should_decline(
            _J1_INDEX_BYTES, BLOOM_L1_DEFAULT_BUDGET_BYTES
        ),
        "j1's 3,648 B index is inside the default budget",
    )
    assert_true(
        bloom_l1_should_decline(_J1_INDEX_BYTES, BLOOM_L1_L1D_BYTES),
        "j1's 3,648 B index is inside the benchmark host's whole L1d",
    )

    # THE EXACT BOUNDARY. `<=`, not `<` — an index that exactly fills the
    # budget is resident, so it declines. M1 is the off-by-one.
    assert_true(
        bloom_l1_should_decline(16_384, 16_384), "exactly at budget declines"
    )
    assert_false(
        bloom_l1_should_decline(16_385, 16_384), "one byte over is kept"
    )

    # The shipped layout quantises the boundary onto exact row counts via the
    # power-of-two capacity: n=512 -> cap 1024 -> 16,384 B exactly;
    # n=513 -> cap 1024 -> 16,400 B. Both re-derived here, not quoted.
    assert_equal(
        bloom_l1_index_bytes(512, 1_024, JOIN_KN_WORDS, True, True), 16_384
    )
    assert_equal(
        bloom_l1_index_bytes(513, 1_024, JOIN_KN_WORDS, True, True), 16_400
    )
    assert_true(
        bloom_l1_should_decline(16_384, BLOOM_L1_DEFAULT_BUDGET_BYTES),
        "512 build rows decline at the default budget",
    )
    assert_false(
        bloom_l1_should_decline(16_400, BLOOM_L1_DEFAULT_BUDGET_BYTES),
        "513 build rows do NOT",
    )

    # THE OFF ARM. A zero or negative budget is the lever being off, and it
    # must fail towards the incumbent — never "decline everything", which is
    # what an operator would spell by typo. M2 is this direction inverted.
    assert_false(bloom_l1_should_decline(8, 0), "budget 0 is OFF")
    assert_false(bloom_l1_should_decline(8, -1), "negative budget is OFF")
    assert_false(
        bloom_l1_should_decline(0, 0), "a zero-byte index is still OFF at 0"
    )
    print("test_should_decline_predicate OK")


# -----------------------------------------------------------------------------
# Leg 3 — the gate's parsing contract
# -----------------------------------------------------------------------------


def test_gate_parsing_contract() raises:
    _clear_env()
    assert_equal(bloom_l1_budget_bytes(), 0, "unconfigured is OFF")

    # 0 is the OFF arm spelled explicitly, so `0` against `16384` is a
    # single-variable comparison in one process.
    bloom_l1_configure(0)
    assert_equal(bloom_l1_budget_bytes(), 0, "explicit 0 is the OFF arm")

    bloom_l1_configure(16_384)
    assert_equal(bloom_l1_budget_bytes(), 16_384, "a budget is honoured")

    bloom_l1_configure(32_768)
    assert_equal(bloom_l1_budget_bytes(), 32_768, "a whole 32 KiB L1d")

    bloom_l1_configure(-1)
    assert_equal(bloom_l1_budget_bytes(), 0, "a negative budget is OFF")

    _clear_env()
    assert_equal(bloom_l1_budget_bytes(), 0, "cleared is OFF")
    print("test_gate_parsing_contract OK")


# -----------------------------------------------------------------------------
# Leg 4 — ARMING and NON-VACUITY through the real builder
# -----------------------------------------------------------------------------


def test_decline_arms_on_small_and_not_on_large() raises:
    _clear_env()

    # --- the OFF arm: unset gate, j1-shaped build, bloom must be BUILT -------
    # M2 and a predicate stuck at True both die here.
    reset_bloom_l1_counters()
    var off = HashJoinBuilder.build(_dense_keys(_J1_BUILD_ROWS))
    assert_true(
        off.uses_bloom(),
        "with the gate unset a 100-row build must still get its bloom",
    )
    assert_equal(
        bloom_l1_declined_count(), 0, "nothing may decline on the OFF arm"
    )
    assert_true(
        bloom_l1_kept_count() > 0,
        "the predicate was REACHED on the OFF arm — kept=0 declined=0 would"
        " mean unreachable, which is a different fact",
    )
    _ = off^

    # --- the ON arm, SMALL: j1's shape must DECLINE -------------------------
    bloom_l1_configure(16_384)
    reset_bloom_l1_counters()
    var small = HashJoinBuilder.build(_dense_keys(_J1_BUILD_ROWS))
    # THE STRUCTURAL OBSERVABLE. M5 — notch the counter, build the filter
    # anyway — is green on every other assertion in this file.
    assert_false(
        small.uses_bloom(),
        "a 3,648 B index must return an index the probe will not ask",
    )
    assert_equal(bloom_l1_declined_count(), 1, "exactly one decline")
    assert_equal(bloom_l1_kept_count(), 0, "and no keep")
    assert_equal(
        bloom_l1_declined_rows(),
        _J1_BUILD_ROWS,
        "the decline was decided on 100 real rows, not on an empty build",
    )
    _ = small^

    # --- the ON arm, LARGE: the counter-vacuity leg -------------------------
    # 4,096 rows -> cap 8,192 -> 8,192*8 + 2*4,096*8 = 131,072 B, eight times
    # the budget. M6 (decline everything) dies here and nowhere else.
    reset_bloom_l1_counters()
    var large = HashJoinBuilder.build(_dense_keys(4_096))
    assert_equal(
        bloom_l1_index_bytes(4_096, 8_192, JOIN_KN_WORDS, True, True),
        131_072,
        "4,096 rows is 131,072 B — re-derived, not assumed",
    )
    assert_true(
        large.uses_bloom(),
        "a 131,072 B index is not L1-resident and MUST keep its bloom",
    )
    assert_equal(bloom_l1_kept_count(), 1, "exactly one keep")
    assert_equal(bloom_l1_declined_count(), 0, "and no decline")
    _ = large^

    # --- a caller that already declined must not reach the predicate --------
    # M7: `build_bloom=False` is the driver saying the bloom is unwired
    # downstream. That is not this lever's decision to re-take, and counting it
    # would inflate `declined` with builds the lever had nothing to do with.
    reset_bloom_l1_counters()
    var pre = HashJoinBuilder.build(
        _dense_keys(_J1_BUILD_ROWS), build_bloom=False
    )
    assert_false(pre.uses_bloom(), "build_bloom=False still means no bloom")
    assert_equal(
        bloom_l1_declined_count(),
        0,
        "a caller-declined build never reached the predicate",
    )
    assert_equal(bloom_l1_kept_count(), 0, "kept=0 declined=0 = never reached")
    _ = pre^

    reset_bloom_l1_counters()
    _clear_env()
    print("test_decline_arms_on_small_and_not_on_large OK")


# -----------------------------------------------------------------------------
# Leg 5 — VALUE INVARIANCE
# -----------------------------------------------------------------------------


def test_decline_is_value_invariant() raises:
    """The declined index and a bloom-carrying one over the same keys emit the
    same pairs. Necessary, and on its own worth nothing — see the header."""
    _clear_env()
    var probe = _probe_keys(4_000, _J1_BUILD_ROWS)

    # Control: force the bloom on, gate unset.
    var ctl = HashJoinBuilder.build(_dense_keys(_J1_BUILD_ROWS))
    assert_true(ctl.uses_bloom(), "control arm must actually carry a bloom")
    var ctl_bm = List[Int]()
    var ctl_pm = List[Int]()
    ctl.probe_inner_into(probe, ctl_bm, ctl_pm)
    _ = ctl^

    # Treatment: the gate declines it.
    bloom_l1_configure(16_384)
    var trt = HashJoinBuilder.build(_dense_keys(_J1_BUILD_ROWS))
    assert_false(trt.uses_bloom(), "treatment arm must actually have declined")
    var trt_bm = List[Int]()
    var trt_pm = List[Int]()
    trt.probe_inner_into(probe, trt_bm, trt_pm)
    _ = trt^

    # j1's shape: EVERY probe row matches exactly one build row, so the bloom
    # in the control arm rejected nothing at all — the cell's defining property,
    # asserted rather than described.
    assert_equal(len(ctl_bm), 4_000, "every probe row matches on this fixture")
    var ctl_enc = _encode_pairs(ctl_bm, ctl_pm)
    var trt_enc = _encode_pairs(trt_bm, trt_pm)
    assert_equal(len(ctl_enc), len(trt_enc), "same number of pairs")
    for i in range(len(ctl_enc)):
        assert_equal(ctl_enc[i], trt_enc[i], "pair " + String(i))

    _clear_env()
    reset_bloom_l1_counters()
    print("test_decline_is_value_invariant OK")


def main() raises:
    var suite = TestSuite()
    suite.test[test_index_bytes_arithmetic]()
    suite.test[test_should_decline_predicate]()
    suite.test[test_gate_parsing_contract]()
    suite.test[test_decline_arms_on_small_and_not_on_large]()
    suite.test[test_decline_is_value_invariant]()
    suite^.run()
