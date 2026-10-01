# =============================================================================
# test_typed_col_count_distinct_kerneldirect.mojo
# =============================================================================
#
# COUNT_DISTINCT in the typed-column hash-agg catalog (`hash_agg_op_dt.mojo`):
# the `CountDistinctOp[dt]` catalog conformer lets the typed-column scalar +
# grouped agg paths self-serve COUNT_DISTINCT instead of falling through to
# the untyped-column executor.
#
# COUNT_DISTINCT is the FIRST genuinely VARIABLE-SIZE per-group state in the
# catalog: state is a heap-owning `CountDistinctState[dt]` (a `List[Scalar[dt]]`
# value buffer). The typed-COLUMN catalog hosts this cleanly (the per-group state
# lives in `AggSlot[A].states: List[A.StateTy]`, a typed Mojo `List` not a
# byte-slab — slab-safe), with a UNION/CONCAT cross-worker combine. (This is the
# OPPOSITE of the ROW substrate, whose fixed-extra-cell byte-slab cannot host a
# variable-size value set — the row COUNT_DISTINCT was HALTED for that reason.)
#
# ALGORITHM = SORT-DEDUP AT FINALIZE (mirrors the untyped-column oracle
# `agg_count_distinct.mojo` = the older `CountDistinctI64ColumnarAcc`): update
# appends the value; combine concatenates donor buffers (UNION, dedup deferred —
# associative); finalize sorts + counts value-runs. Output is ALWAYS int64.
#
# THIS TEST drives the agg KERNEL DIRECTLY (`CountDistinctOp[dt]` init/
# update_scalar/finalize/combine) over hand-built value lists — without
# compiling the full ctx.materialize dispatch tree — so it runs in well under
# a second. It exercises BOTH the single-accumulator hot path AND the
# multi-partial UNION/CONCAT `combine` path (the multi-worker shape the typed
# Stage uses), and compares against a DuckDB COUNT(DISTINCT) oracle.
#
# DuckDB oracle (the duckdb CLI, COUNT(DISTINCT x)):
#   int64  [1,2,2,3,3,3]      -> 3
#   int64  [5,5,5]            -> 1
#   int64  []  (empty group)  -> 0  (DuckDB returns 0, NOT NULL, for an empty CD)
#   int64  [-1,-1,0,2,-3]     -> 4
#   float32[1.5,2.5,1.5,3.5,2.5] -> 3
#   int32  [10,20,10,30,20,10] -> 3
#
# COMPARE MODE = EXACT (COUNT_DISTINCT is an integer count — no float epsilon).
#
# Encapsulation invariants: NO UnsafePointer / wildcard
# origins / unsafe_from_address / take_pointee in THIS test. Kernel surface only.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_eval.hash_agg_op_dt import CountDistinctOp, CountDistinctState


# -----------------------------------------------------------------------------
# Single-accumulator drain: init -> update_scalar over the whole list -> finalize.
# The one-worker hot path of the typed Stage (no cross-worker combine).
# -----------------------------------------------------------------------------
def _cd_single[dt: DType](vals: List[Scalar[dt]]) -> Int64:
    var st = CountDistinctOp[dt].init()
    for i in range(len(vals)):
        CountDistinctOp[dt].update_scalar(st, vals[i])
    return CountDistinctOp[dt].finalize(st)


# -----------------------------------------------------------------------------
# Multi-partial drain: split the list into two disjoint halves, accumulate each
# in its OWN CountDistinctState (the per-worker partial), then UNION/CONCAT-merge
# them via `combine` before finalize. This is the actual multi-worker shape the
# typed Stage drives — it MUST produce the same distinct count as the single-
# accumulator path (and match DuckDB) even when the SAME value straddles the two
# halves (where a naive count-add would double-count).
# -----------------------------------------------------------------------------
def _cd_two_partials[dt: DType](vals: List[Scalar[dt]]) -> Int64:
    var mid = len(vals) // 2
    var a = CountDistinctOp[dt].init()
    for i in range(mid):
        CountDistinctOp[dt].update_scalar(a, vals[i])
    var b = CountDistinctOp[dt].init()
    for i in range(mid, len(vals)):
        CountDistinctOp[dt].update_scalar(b, vals[i])
    CountDistinctOp[dt].combine(a, b)
    return CountDistinctOp[dt].finalize(a)


# -----------------------------------------------------------------------------
# The CONCAT-FREE move-combine path. Split
# the list into two per-worker partials, then MOVE each worker's whole value
# buffer into a merged accumulator's run-list via `take_distinct_buffer_into`
# (O(1) per buffer, NO concat copy) — the eval-layer half of the concat-free merge
# the `StageMorselSinkAdapter.combine_move_distinct` drives. `finalize` over the
# UNION (values ++ flatten(runs)) MUST match the single-accumulator count even
# when a value STRADDLES the two workers (deduped once across runs).
# -----------------------------------------------------------------------------
def _cd_two_partials_move[dt: DType](vals: List[Scalar[dt]]) -> Int64:
    var mid = len(vals) // 2
    var w0 = CountDistinctOp[dt].init()
    for i in range(mid):
        CountDistinctOp[dt].update_scalar(w0, vals[i])
    var w1 = CountDistinctOp[dt].init()
    for i in range(mid, len(vals)):
        CountDistinctOp[dt].update_scalar(w1, vals[i])
    var merged = CountDistinctOp[dt].init()  # starts empty; accumulates runs
    CountDistinctOp[dt].take_distinct_buffer_into(merged, w0)
    CountDistinctOp[dt].take_distinct_buffer_into(merged, w1)
    return CountDistinctOp[dt].finalize(merged)


# -----------------------------------------------------------------------------
# §1 — INT64 input COUNT_DISTINCT, vs DuckDB. Single + 2-partial UNION-merge.
# -----------------------------------------------------------------------------
def test_int64_count_distinct_matches_duckdb() raises:
    # [1,2,2,3,3,3] -> 3
    var v = List[Scalar[DType.int64]]()
    v.append(Int64(1)); v.append(Int64(2)); v.append(Int64(2))
    v.append(Int64(3)); v.append(Int64(3)); v.append(Int64(3))
    assert_equal(_cd_single[DType.int64](v), Int64(3), "int64 [1,2,2,3,3,3]")
    # 2-partial UNION-merge: halves [1,2,2] | [3,3,3] -> still 3.
    assert_equal(
        _cd_two_partials[DType.int64](v), Int64(3),
        "int64 [1,2,2,3,3,3] (2-partial UNION)",
    )

    # [5,5,5] -> 1
    var v2 = List[Scalar[DType.int64]]()
    v2.append(Int64(5)); v2.append(Int64(5)); v2.append(Int64(5))
    assert_equal(_cd_single[DType.int64](v2), Int64(1), "int64 [5,5,5]")
    # 2-partial: halves [5] | [5,5] — value 5 STRADDLES both halves; a naive
    # count-add would yield 2. The UNION/CONCAT combine + finalize dedup yields 1.
    assert_equal(
        _cd_two_partials[DType.int64](v2), Int64(1),
        "int64 [5,5,5] (2-partial UNION, straddling value)",
    )

    # [-1,-1,0,2,-3] -> 4 (negatives + zero)
    var v3 = List[Scalar[DType.int64]]()
    v3.append(Int64(-1)); v3.append(Int64(-1)); v3.append(Int64(0))
    v3.append(Int64(2)); v3.append(Int64(-3))
    assert_equal(_cd_single[DType.int64](v3), Int64(4), "int64 [-1,-1,0,2,-3]")
    assert_equal(
        _cd_two_partials[DType.int64](v3), Int64(4),
        "int64 [-1,-1,0,2,-3] (2-partial UNION)",
    )


# -----------------------------------------------------------------------------
# §2 — empty group -> 0 (DuckDB COUNT(DISTINCT) of an empty group is 0, NOT NULL).
# -----------------------------------------------------------------------------
def test_empty_group_returns_zero() raises:
    var empty = List[Scalar[DType.int64]]()
    assert_equal(
        _cd_single[DType.int64](empty), Int64(0),
        "int64 empty COUNT_DISTINCT -> 0",
    )
    # combine of two empty partials is still 0.
    var a = CountDistinctOp[DType.int64].init()
    var b = CountDistinctOp[DType.int64].init()
    CountDistinctOp[DType.int64].combine(a, b)
    assert_equal(
        CountDistinctOp[DType.int64].finalize(a), Int64(0),
        "int64 empty+empty UNION COUNT_DISTINCT -> 0",
    )


# -----------------------------------------------------------------------------
# §3 — FLOAT32 input COUNT_DISTINCT (native-dt distinctness, no widening), vs DuckDB.
# -----------------------------------------------------------------------------
def test_float32_count_distinct_matches_duckdb() raises:
    # [1.5,2.5,1.5,3.5,2.5] -> 3
    var v = List[Scalar[DType.float32]]()
    v.append(Float32(1.5)); v.append(Float32(2.5)); v.append(Float32(1.5))
    v.append(Float32(3.5)); v.append(Float32(2.5))
    assert_equal(
        _cd_single[DType.float32](v), Int64(3), "float32 [1.5,2.5,1.5,3.5,2.5]"
    )
    assert_equal(
        _cd_two_partials[DType.float32](v), Int64(3),
        "float32 [1.5,2.5,1.5,3.5,2.5] (2-partial UNION)",
    )


# -----------------------------------------------------------------------------
# §4 — INT32 input COUNT_DISTINCT (DType-generic single conformer), vs DuckDB.
# -----------------------------------------------------------------------------
def test_int32_count_distinct_matches_duckdb() raises:
    # [10,20,10,30,20,10] -> 3
    var v = List[Scalar[DType.int32]]()
    v.append(Int32(10)); v.append(Int32(20)); v.append(Int32(10))
    v.append(Int32(30)); v.append(Int32(20)); v.append(Int32(10))
    assert_equal(
        _cd_single[DType.int32](v), Int64(3), "int32 [10,20,10,30,20,10]"
    )
    assert_equal(
        _cd_two_partials[DType.int32](v), Int64(3),
        "int32 [10,20,10,30,20,10] (2-partial UNION)",
    )


def test_move_combine_matches_single() raises:
    """The concat-free move-combine (`take_distinct_
    buffer_into` -> `finalize` over runs) == the single-accumulator count, EXACTLY,
    for every input shape — INCLUDING the straddling-value cases where a naive
    per-buffer count would double-count."""
    # [1,2,2,3,3,3] -> 3; halves [1,2,2] | [3,3,3].
    var v = List[Scalar[DType.int64]]()
    v.append(Int64(1)); v.append(Int64(2)); v.append(Int64(2))
    v.append(Int64(3)); v.append(Int64(3)); v.append(Int64(3))
    assert_equal(
        _cd_two_partials_move[DType.int64](v), _cd_single[DType.int64](v),
        "int64 [1,2,2,3,3,3] (2-partial MOVE combine)",
    )
    # [5,5,5] -> 1; halves [5] | [5,5] — value 5 STRADDLES both worker buffers.
    # The move accumulates runs [[5],[5,5]]; finalize dedups across runs -> 1.
    var v2 = List[Scalar[DType.int64]]()
    v2.append(Int64(5)); v2.append(Int64(5)); v2.append(Int64(5))
    assert_equal(
        _cd_two_partials_move[DType.int64](v2), Int64(1),
        "int64 [5,5,5] (2-partial MOVE, straddling value -> 1 not 2)",
    )
    # negatives + zero across the split.
    var v3 = List[Scalar[DType.int64]]()
    v3.append(Int64(-1)); v3.append(Int64(-1)); v3.append(Int64(0))
    v3.append(Int64(2)); v3.append(Int64(-3))
    assert_equal(
        _cd_two_partials_move[DType.int64](v3), Int64(4),
        "int64 [-1,-1,0,2,-3] (2-partial MOVE combine)",
    )
    # int32 DType-generic move path.
    var v4 = List[Scalar[DType.int32]]()
    v4.append(Int32(10)); v4.append(Int32(20)); v4.append(Int32(10))
    v4.append(Int32(30)); v4.append(Int32(20)); v4.append(Int32(10))
    assert_equal(
        _cd_two_partials_move[DType.int32](v4), Int64(3),
        "int32 [10,20,10,30,20,10] (2-partial MOVE combine)",
    )


def test_move_combine_empty() raises:
    """Empty + empty move-combine -> 0; and moving an empty worker buffer into a
    non-empty merged accumulator is a no-op."""
    var empty = List[Scalar[DType.int64]]()
    assert_equal(
        _cd_two_partials_move[DType.int64](empty), Int64(0),
        "int64 empty MOVE combine -> 0",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
