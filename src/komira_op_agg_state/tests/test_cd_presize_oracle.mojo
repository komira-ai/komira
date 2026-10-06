# =============================================================================
# test_cd_presize_oracle.mojo — LEVER CDP byte-equivalence oracle
# =============================================================================
#
# LEVER CDP (pre-sized COUNT(DISTINCT) dedup tables, DEFAULT-OFF behind
# `KOMIRA_CD_PRESIZE_ON`) constructs each `GrowableHashSetI64` accumulator
# already large enough for its known input size, so the grow-and-rehash ladder
# never runs. The lever's whole correctness claim is:
#
#   the dedup RESULT is invariant to the directory capacity it was built at.
#
# This file is the oracle for that claim. It drives the set primitive DIRECTLY
# (no SDK, no dispatcher) and compares the DEFAULT-CAPACITY arm (2048 slots,
# grows by doubling — the pre-lever path, exactly what runs with the flag unset)
# against the PRE-SIZED arm (`with_expected(n)`) on the two observables every
# COUNT(DISTINCT) caller consumes:
#
#   * `size()`        — the distinct count itself.
#   * `key_at(i)` for every i — the insertion-ordered dense key column, which
#                     `_cd_union_count` / the grouped drain walk.
#
# WHY THIS ORACLE CAN GO RED (the "must be able to fail in the direction it
# guards" requirement). The comparison is a FULL element-wise equality over an
# independently-built reference, not a self-comparison of one table with itself:
#   * If `new_presized` mis-sized the directory such that the load factor could
#     exceed the probe invariant (e.g. capacity not a power of two, so
#     `_salt_stride`'s odd stride is no longer coprime with the modulus and the
#     probe cannot visit every slot), inserts would land on the wrong slot or
#     spin — `size()` diverges and §1/§2/§3 FAIL.
#   * If `new_presized` under-filled the sentinel (leaving one slot non-`_EMPTY_
#     SLOT`), that slot reads as occupied forever, a distinct key is silently
#     folded into it, and `size()` comes back SHORT — §2 FAILs.
#   * If the reserve on the dense side arrays disturbed the append order,
#     `key_at` order diverges — §3 FAILs.
# Verified empirically: deliberately breaking `new_presized` (see the report's
# break-verification) turns §1-§3 RED and reverting turns them GREEN again.
#
# §4 additionally pins the DEFAULT-EQUIVALENCE identity the caller-side gate
# depends on: `with_expected(n)` for any `n <= 0` must be byte-for-byte the
# default `GrowableHashSetI64()` — that is what makes the flag-OFF arm the
# pre-lever code path rather than a second, differently-sized path.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_op_agg_state.growable_hash_set_i64 import (
    GrowableHashSetI64,
)


# =============================================================================
# Helpers
# =============================================================================


def _build_default(imm vals: List[Int64]) -> GrowableHashSetI64:
    """Reference arm: the DEFAULT 2048-slot table that reaches its working size
    by doubling. This is the pre-lever path (flag unset)."""
    var s = GrowableHashSetI64()
    for i in range(len(vals)):
        _ = s.insert(vals[i])
    return s^


def _build_presized(imm vals: List[Int64]) -> GrowableHashSetI64:
    """Lever arm: pre-sized from the input VALUE count (an upper bound on the
    distinct count — exactly the hint the radix driver passes)."""
    var s = GrowableHashSetI64.with_expected(len(vals))
    for i in range(len(vals)):
        _ = s.insert(vals[i])
    return s^


def _assert_arms_identical(
    imm vals: List[Int64], label: String
) raises:
    """Full observable equality between the two arms: cardinality AND the whole
    insertion-ordered dense key column, element by element."""
    var ref_set = _build_default(vals)
    var pre_set = _build_presized(vals)

    assert_equal(
        pre_set.size(),
        ref_set.size(),
        label + ": distinct count must be capacity-invariant",
    )
    for slot in range(ref_set.size()):
        assert_equal(
            Int(pre_set.key_at(slot)),
            Int(ref_set.key_at(slot)),
            label + ": key_at(" + String(slot) + ") must match the "
            "default-capacity arm (insertion order is capacity-invariant)",
        )


# =============================================================================
# §1 — all-distinct, crossing many doublings in the reference arm
# =============================================================================


def test_all_distinct_crosses_many_doublings() raises:
    """200_000 distinct keys. The reference arm starts at 2048 slots and grows
    through ~8 doublings (each one a full sentinel-fill + rehash of every live
    group); the pre-sized arm allocates once and never grows. Both must agree
    on the count AND on every key position."""
    var vals = List[Int64](capacity=200_000)
    for k in range(200_000):
        vals.append(Int64(k) * Int64(7) + Int64(3))
    _assert_arms_identical(vals, "200k all-distinct")


# =============================================================================
# §2 — heavy duplicates (hint is a LOOSE upper bound)
# =============================================================================


def test_heavy_duplicates_loose_hint() raises:
    """150_000 values but only 1_000 distinct — the pre-size hint over-shoots
    the true cardinality by 150x. The count must still be exactly 1_000 (an
    over-sized directory must not merge or split groups), and the insertion
    order must be unchanged."""
    var vals = List[Int64](capacity=150_000)
    for i in range(150_000):
        vals.append(Int64(i % 1_000))
    _assert_arms_identical(vals, "150k values / 1k distinct")

    var pre_set = _build_presized(vals)
    assert_equal(
        pre_set.size(), 1_000, "exact distinct cardinality under a loose hint"
    )


# =============================================================================
# §3 — negatives, zero, and adversarial low-entropy keys
# =============================================================================


def test_negative_zero_and_sparse_keys() raises:
    """Mixed sign, zero, and keys whose LOW bits collide (multiples of a large
    power of two) — the shape most sensitive to a directory-sizing or
    probe-stride mistake, because every key wants the same starting slot band."""
    var vals = List[Int64]()
    for k in range(-2_000, 2_000):
        vals.append(Int64(k))
    for k in range(4_000):
        vals.append(Int64(k) << Int64(20))  # low 20 bits all zero
    for _ in range(4_000):
        vals.append(Int64(0))  # the sentinel-adjacent key, many times
    _assert_arms_identical(vals, "mixed sign / low-entropy / zero")


# =============================================================================
# §4 — the OFF-arm identity the caller-side gate relies on
# =============================================================================


def test_no_hint_equals_default_ctor() raises:
    """`with_expected(n)` for n <= 0 must behave exactly like the default ctor.
    The radix driver's gate is `hint = n if presize else 0`, so this identity is
    what makes flag-OFF the untouched pre-lever path."""
    var vals = List[Int64](capacity=5_000)
    for k in range(5_000):
        vals.append(Int64(k % 1_700))

    var ref_set = _build_default(vals)

    var hints = List[Int]()
    hints.append(0)
    hints.append(-1)
    hints.append(-100_000)

    for hi in range(len(hints)):
        var hint = hints[hi]
        var s = GrowableHashSetI64.with_expected(hint)
        for i in range(len(vals)):
            _ = s.insert(vals[i])
        assert_equal(
            s.size(),
            ref_set.size(),
            "with_expected(" + String(hint) + ") == default ctor cardinality",
        )
        for slot in range(ref_set.size()):
            assert_equal(
                Int(s.key_at(slot)),
                Int(ref_set.key_at(slot)),
                "with_expected(" + String(hint) + ") == default ctor order",
            )


# =============================================================================
# §5 — a pre-sized table still GROWS correctly past its hint
# =============================================================================


def test_presized_still_grows_past_hint() raises:
    """The hint is advisory, not a cap: inserting far more distinct keys than
    the hint anticipated must still be exact (the table falls back to the normal
    doubling ladder from the pre-sized floor). Guards against the pre-size path
    ever being treated as a fixed-capacity table."""
    var vals = List[Int64](capacity=60_000)
    for k in range(60_000):
        vals.append(Int64(k))

    # Deliberately tiny hint relative to the real cardinality.
    var s = GrowableHashSetI64.with_expected(64)
    for i in range(len(vals)):
        _ = s.insert(vals[i])

    assert_equal(s.size(), 60_000, "under-sized hint still counts exactly")
    assert_true(
        s.contains(Int64(59_999)), "last key present after growth past hint"
    )
    for slot in range(0, 60_000, 4_999):
        assert_equal(
            Int(s.key_at(slot)), slot, "insertion order preserved past hint"
        )


# =============================================================================
# main
# =============================================================================


def main() raises:
    var suite = TestSuite()
    suite.test[test_all_distinct_crosses_many_doublings]()
    suite.test[test_heavy_duplicates_loose_hint]()
    suite.test[test_negative_zero_and_sparse_keys]()
    suite.test[test_no_hint_equals_default_ctor]()
    suite.test[test_presized_still_grows_past_hint]()
    suite^.run()
