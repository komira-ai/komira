# =============================================================================
# COUNT(DISTINCT) skips NULL rows in the streaming accumulate of
# `WorkerCDState`: the grouped `consume_batch` and the 0-key
# `consume_batch_ungrouped`.
#
# THE DEFECT IS A WRONG NUMBER, NOT A REFUSAL. `count(DISTINCT i)` over
# `i = [10, 30, NULL, NULL, 7]` must be 3 (DuckDB v1.5.3 answers 3). A kernel
# that inserts a NULL row's DATA WORD into the distinct set answers 4: Arrow
# leaves that word unspecified, and the builders here store whatever was
# written there. SQL and DuckDB count DISTINCT NON-NULL values, and answer 0
# (not NULL) when every value is NULL.
#
# `consume_batch_ungrouped` is the arm a plain `SELECT count(DISTINCT c) FROM t`
# reaches (`CountDistinctAggSink.consume` delegates to it when the plan has no
# group keys), so its NULL skip is the one most queries depend on.
#
# THE ORACLE is DuckDB v1.5.3 over the small fixture (`k=[1,1,2,2,3]`,
# `v=[10,30,NULL,NULL,7]::BIGINT`):
#
#   SELECT count(DISTINCT v) FROM t                          ->  3
#   SELECT k, count(DISTINCT v) FROM t GROUP BY k ORDER BY k ->  2 / 0 / 1
#
# and, per test, a hand-written SQL-semantics oracle over the raw arrays the
# batch was built from, so it cannot inherit a bug from the column builders.
#
# THE NULL ROWS' PAYLOAD IS `_NULL_PAYLOAD`, NOT 0, AND THAT IS LOAD-BEARING.
# A payload that also appears as a real value makes the NULL-blind answer and
# the right answer coincide. Every fixture writes a payload that appears nowhere
# else, so a NULL-blind kernel is provably EXACTLY one too high;
# `test_null_payload_makes_a_null_blind_kernel_visible` pins that.
#
# REVERT-AND-RED: drop the `is_null_at` guard from the single-agg Int64 loop of
# `consume_batch_ungrouped` (`if nullable0 and vlanes.is_null_at(0, row)`) and
# `test_stream_ungrouped_skips_nulls`, `..._all_null_stores_nothing` and
# `test_stream_kernels_agree_on_the_small_fixture` go red; drop it from the
# grouped loop and the `test_stream_grouped_*` cells go red.
# =============================================================================

from std.collections import Dict, List, Set
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)

from komira_op_agg_distinct.streaming_agg_count_distinct import (
    WorkerCDState,
)


# The payload stored in the DATA word of a NULL row. Appears nowhere else in
# any value column built here.
comptime _NULL_PAYLOAD: Int64 = -777_777


struct _Fx(Movable):
    """The raw arrays the batch was built from. The oracles read THESE."""

    var keys: List[Int64]
    var vals: List[Int64]
    var nulls: List[Bool]

    def __init__(
        out self, var keys: List[Int64], var vals: List[Int64],
        var nulls: List[Bool],
    ):
        self.keys = keys^
        self.vals = vals^
        self.nulls = nulls^

    def n(self) -> Int:
        return len(self.keys)


def _small_fixture() raises -> _Fx:
    """`k=[1,1,2,2,3]`, `v=[10,30,NULL,NULL,7]`."""
    var keys: List[Int64] = [1, 1, 2, 2, 3]
    var vals: List[Int64] = [10, 30, _NULL_PAYLOAD, _NULL_PAYLOAD, 7]
    var nulls: List[Bool] = [False, False, True, True, False]
    return _Fx(keys^, vals^, nulls^)


def _build_batch(imm f: _Fx) raises -> RecordBatch:
    """A 2-column batch: INT64 key `k` (non-null) + INT64 value `v`.

    `v` gets a validity bitmap ONLY when the fixture has a null, so the
    no-validity path is exercised by the null-free control.
    """
    var n = f.n()
    var karr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        karr.store[1](i, Scalar[DType.int64](f.keys[i]))

    var any_null = False
    for i in range(n):
        if f.nulls[i]:
            any_null = True
            break

    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.int64](karr^))
    if any_null:
        var varr = PrimitiveArray[DType.int64].allocate_nullable(n)
        for i in range(n):
            varr.store[1](i, Scalar[DType.int64](f.vals[i]))
        for i in range(n):
            if f.nulls[i]:
                varr._set_null(i)
        rbb.add_column(Column.from_primitive[DType.int64](varr^))
    else:
        var varr = PrimitiveArray[DType.int64].allocate(n)
        for i in range(n):
            varr.store[1](i, Scalar[DType.int64](f.vals[i]))
        rbb.add_column(Column.from_primitive[DType.int64](varr^))

    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, any_null))
    return rbb.build(sb.build())


# =============================================================================
# Oracles, computed from the raw arrays
# =============================================================================


def _oracle_grouped(imm f: _Fx) raises -> Dict[Int64, Int]:
    var sets = Dict[Int64, Set[Int64]]()
    for i in range(f.n()):
        var k = f.keys[i]
        if k not in sets:
            sets[k] = Set[Int64]()
        if not f.nulls[i]:
            sets[k].add(f.vals[i])
    var out = Dict[Int64, Int]()
    for e in sets.items():
        out[e.key] = len(e.value)
    return out^


def _oracle_ungrouped(imm f: _Fx) raises -> Int:
    var s = Set[Int64]()
    for i in range(f.n()):
        if not f.nulls[i]:
            s.add(f.vals[i])
    return len(s)


def _oracle_ungrouped_null_blind(imm f: _Fx) raises -> Int:
    """What a NULL-BLIND kernel returns. Asserted to DIFFER from the real
    oracle, so a fixture that stopped being able to see the defect fails
    loudly instead of passing for the wrong reason."""
    var s = Set[Int64]()
    for i in range(f.n()):
        s.add(f.vals[i])
    return len(s)


def _assert_grouped_matches(
    imm got: Dict[Int64, Int], imm want: Dict[Int64, Int], imm msg: String
) raises:
    assert_equal(len(got), len(want), msg + ": group COUNT")
    for e in want.items():
        assert_true(
            e.key in got,
            msg + ": missing group key " + String(e.key),
        )
        assert_equal(
            got[e.key], e.value,
            msg + ": COUNT(DISTINCT) of group " + String(e.key),
        )


# =============================================================================
# Drivers
# =============================================================================


def _run_stream_ungrouped(imm f: _Fx) raises -> Int:
    """Drive `WorkerCDState.consume_batch_ungrouped` and read the accumulated
    distinct cardinality out of the per-value-partition sets. The finalize
    union is a pure function of what accumulate stored, so the NULL skip has to
    hold here."""
    var batch = _build_batch(f)
    var st = WorkerCDState(1)
    var val_idx = List[Int]()
    val_idx.append(1)
    st.consume_batch_ungrouped(batch, val_idx)
    _ = batch^
    var total = 0
    for p in range(len(st.cd_sets[0])):
        total += st.cd_sets[0][p].size()
    return total


def _run_stream_grouped(imm f: _Fx) raises -> Dict[Int64, Int]:
    """Drive `WorkerCDState.consume_batch` and dedup each group's buffered
    cell in the TEST (which is what the finalize radix driver does), so the
    assertion is on what accumulate stored, not on the dedup kernel."""
    var batch = _build_batch(f)
    var st = WorkerCDState(1)
    var val_idx = List[Int]()
    val_idx.append(1)
    st.consume_batch(batch, 0, val_idx)
    _ = batch^
    var out = Dict[Int64, Int]()
    for gid in range(len(st.group_keys)):
        # A cell's values live in EXACTLY ONE of the two stores (the struct's
        # own invariant), so one of these two terms is always 0. Counting both
        # keeps this helper correct whichever way `cd_scan_dedup_off` is set.
        var s = Set[Int64]()
        for i in range(len(st.cd_bufs[0][gid])):
            s.add(st.cd_bufs[0][gid][i])
        var promoted = 0
        for p in range(len(st.cd_gsets[0][gid])):
            promoted += st.cd_gsets[0][gid][p].size()
        out[Int64(st.group_keys[gid])] = len(s) + promoted
    return out^


# =============================================================================
# 0. The fixture's own discriminating power, asserted before any kernel runs
# =============================================================================


def test_null_payload_makes_a_null_blind_kernel_visible() raises:
    """If the NULL payload collided with a real value, the NULL-blind answer
    and the correct answer would be the same number and every cell below would
    pass with the skip removed. Assert the payload appears nowhere else and the
    two counts differ."""
    var small = _small_fixture()
    for i in range(small.n()):
        if not small.nulls[i]:
            assert_true(
                small.vals[i] != _NULL_PAYLOAD,
                "the NULL payload must not collide with a real value",
            )
    assert_equal(_oracle_ungrouped(small), 3, "DuckDB: count(DISTINCT v) = 3")
    assert_equal(
        _oracle_ungrouped_null_blind(small), 4,
        "a NULL-blind kernel returns 4",
    )


# =============================================================================
# 1. The GROUPED streaming accumulate (`WorkerCDState.consume_batch`)
# =============================================================================


def test_stream_grouped_skips_nulls() raises:
    var f = _small_fixture()
    _assert_grouped_matches(
        _run_stream_grouped(f), _oracle_grouped(f), "STREAM grouped accumulate"
    )


def test_stream_grouped_all_null_group_stores_nothing() raises:
    var f = _small_fixture()
    var got = _run_stream_grouped(f)
    assert_equal(
        got[Int64(2)], 0,
        "the all-NULL group's cell must hold ZERO values, so the finalize"
        " dedup counts 0",
    )


# =============================================================================
# 2. The 0-KEY streaming accumulate (`consume_batch_ungrouped`): the arm a
#    plain `SELECT count(DISTINCT c) FROM t` reaches.
# =============================================================================


def test_stream_ungrouped_skips_nulls() raises:
    var f = _small_fixture()
    assert_equal(
        _run_stream_ungrouped(f), _oracle_ungrouped(f),
        "STREAM 0-key accumulate: 3 distinct non-NULL values",
    )


def test_stream_ungrouped_all_null_stores_nothing() raises:
    var keys: List[Int64] = [1, 1, 2]
    var vals: List[Int64] = [_NULL_PAYLOAD, _NULL_PAYLOAD, _NULL_PAYLOAD]
    var nulls: List[Bool] = [True, True, True]
    var f = _Fx(keys^, vals^, nulls^)
    assert_equal(
        _run_stream_ungrouped(f), 0,
        "an ALL-NULL column accumulates an EMPTY distinct set; the union at"
        " finalize is then 0, which is DuckDB's answer",
    )


def test_stream_ungrouped_null_free_control_is_unchanged() raises:
    var keys: List[Int64] = [1, 1, 2, 3]
    var vals: List[Int64] = [10, 10, 30, 7]
    var nulls: List[Bool] = [False, False, False, False]
    var f = _Fx(keys^, vals^, nulls^)
    assert_equal(
        _run_stream_ungrouped(f), 3, "null-free control: {10, 30, 7} = 3"
    )


# =============================================================================
# 3. One fixture through both streaming arms. The plan shape (0 keys vs keys)
#    picks which one answers, so they must agree with the same oracle.
# =============================================================================


def test_stream_kernels_agree_on_the_small_fixture() raises:
    var f = _small_fixture()
    var want_u = _oracle_ungrouped(f)
    assert_equal(want_u, 3, "the shared 0-key oracle is DuckDB's 3")
    assert_equal(_run_stream_ungrouped(f), want_u, "STREAM 0-key")
    var want_g = _oracle_grouped(f)
    assert_equal(want_g[Int64(1)], 2, "DuckDB: group 1 counts 2")
    assert_equal(want_g[Int64(2)], 0, "DuckDB: group 2 counts 0")
    assert_equal(want_g[Int64(3)], 1, "DuckDB: group 3 counts 1")
    _assert_grouped_matches(_run_stream_grouped(f), want_g, "STREAM grouped")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
