# =============================================================================
# RowHashAggSpillState: what is spilled comes back, once, with its aggregates
# =============================================================================
#
# Each test feeds a `RowHashAggTable` batch by batch, calls `maybe_spill_run`
# after every batch as the engine does, finalizes, and checks the result
# against aggregates the test computes itself from the same rows (an oracle
# that does not go through the table). Groups are matched by key, never by
# position: the output order of a hash aggregate is unspecified.
#
#   * fold: a budget the folded result fits; several runs spill and fold back
#     into the in-memory table (last_finalize_subpartitions == 1).
#   * repartition: a budget far below the result; the fold overflows and the
#     finalize splits every source by key hash, two levels deep; the yields
#     are at most AGG_RECURSE_FANOUT batches and every group is in exactly one.
#   * string key: NULL and '' are two groups (as DuckDB groups them), and both
#     survive a spill and a repartition, as do the other string keys.
#   * no budget: a budget of 0 never spills and never touches the filesystem.
#
# Spill files go under $TEST_TMPDIR (unique per test execution).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_builder import ArrowStringBuilder
from komira_async.runtime.spill_prefetch import SpillPrefetcher
from komira_collections.slab import Slab
from komira_libc.posix import _read_env

from komira_row_format.row_block import (
    AGG_COUNT,
    AGG_MAX_I64,
    AGG_MIN_I64,
    AGG_SUM_I64,
    COL_FIXED,
    COL_FLAG_KEY_NULLABLE,
    COL_VAR_STRING,
    ColDescriptor,
    DT_I64,
    DT_STRING,
    RowHashAggTable,
    RowLayout,
)

from komira_op_spill_rows.agg_spill import (
    AGG_RECURSE_FANOUT,
    RowHashAggSpillState,
)


def _scratch_dir(name: String) raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d + "/" + name


def _fixed(off: Int, dtype_tag: UInt8) -> ColDescriptor:
    return ColDescriptor(
        kind=COL_FIXED,
        dtype_tag=dtype_tag,
        fixed_width=UInt16(8),
        offset_in_row=UInt16(off),
    )


# =============================================================================
# INT64 key, SUM / COUNT / MIN / MAX of an INT64 value
# =============================================================================

comptime _G = 500  # distinct keys
comptime _R = 64  # rows per batch
comptime _B = 40  # batches


def _key_of(g: Int) -> Int64:
    """Key of group `g`: spread over negative and positive values."""
    return Int64(g) * 1_000_003 - 5_000_000


def _group_of(key: Int64) -> Int:
    return Int((key + 5_000_000) // 1_000_003)


def _row_group(j: Int) -> Int:
    """Group of overall row `j`: 7 is prime to 500, so every 500 rows visit
    every group once, in a scattered order."""
    return (j * 7) % _G


def _row_value(j: Int) -> Int64:
    return Int64((j * 31) % 201) - 100


def _i64_layout() raises -> RowLayout:
    var l = RowLayout()
    l.add_key_col(_fixed(0, DT_I64))
    for a in range(4):
        l.add_payload_col(_fixed(8 + 8 * a, DT_I64))
    l.set_fixed_row_stride(40)
    return l^


def _i64_table() -> RowHashAggTable:
    var t = RowHashAggTable(8, 40)
    t.add_agg(AGG_SUM_I64, 8)
    t.add_agg(AGG_COUNT, 16)
    t.add_agg(AGG_MIN_I64, 24)
    t.add_agg(AGG_MAX_I64, 32)
    return t^


def _i64_batch(b: Int) raises -> RecordBatch:
    var keys = List[Int64]()
    var vals = List[Int64]()
    for i in range(_R):
        var j = b * _R + i
        keys.append(_key_of(_row_group(j)))
        vals.append(_row_value(j))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(keys)
    ))
    rbb.add_column(Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(vals)
    ))
    return rbb.build(sb.build())


def _key_names() -> List[String]:
    var l: List[String] = ["k"]
    return l^


def _agg_names4() -> List[String]:
    var l: List[String] = ["s", "c", "mn", "mx"]
    return l^


def _agg_names2() -> List[String]:
    var l: List[String] = ["c", "s"]
    return l^


def _one(x: Int) -> List[Int]:
    var l: List[Int] = [x]
    return l^


def _same(x: Int, n: Int) -> List[Int]:
    var l = List[Int]()
    for _ in range(n):
        l.append(x)
    return l^


def _feed_i64(mut table: RowHashAggTable, mut state: RowHashAggSpillState) raises:
    var layout = _i64_layout()
    for b in range(_B):
        var rb = _i64_batch(b)
        table.upsert_batch(BatchView(rb), _one(0), _same(1, 4), layout)
        state.maybe_spill_run(table)


struct _Oracle(Movable):
    """SUM / COUNT / MIN / MAX per group, computed from the rows directly."""

    var sum: List[Int64]
    var count: List[Int64]
    var min: List[Int64]
    var max: List[Int64]

    def __init__(out self):
        self.sum = List[Int64]()
        self.count = List[Int64]()
        self.min = List[Int64]()
        self.max = List[Int64]()
        for _ in range(_G):
            self.sum.append(0)
            self.count.append(0)
            self.min.append(Int64.MAX)
            self.max.append(Int64.MIN)
        for j in range(_B * _R):
            var g = _row_group(j)
            var v = _row_value(j)
            self.sum[g] += v
            self.count[g] += 1
            if v < self.min[g]:
                self.min[g] = v
            if v > self.max[g]:
                self.max[g] = v


def _i64(rb: RecordBatch, col: Int, row: Int) raises -> Int64:
    return rb.column_as_primitive_int64(col).load[1](row)[0]


def _check_i64_batches(parts: Slab[RecordBatch]) raises:
    """Every group exactly once across `parts`, with the oracle's aggregates."""
    var o = _Oracle()
    var seen = List[Bool]()
    for _ in range(_G):
        seen.append(False)
    var total = 0
    for p in range(len(parts)):
        ref rb = parts[p]
        for r in range(rb.num_rows()):
            var g = _group_of(_i64(rb, 0, r))
            assert_true(g >= 0 and g < _G, "a key the input never held")
            assert_false(seen[g], "group " + String(g) + " emitted twice")
            seen[g] = True
            assert_equal(_i64(rb, 1, r), o.sum[g], "SUM of group " + String(g))
            assert_equal(_i64(rb, 2, r), o.count[g], "COUNT of group " + String(g))
            assert_equal(_i64(rb, 3, r), o.min[g], "MIN of group " + String(g))
            assert_equal(_i64(rb, 4, r), o.max[g], "MAX of group " + String(g))
            total += 1
    assert_equal(total, _G, "every group emitted")


def test_agg_spill_runs_fold_back_into_the_in_memory_table() raises:
    """Budget 24000: the full result (500 groups x 40 bytes = 20000) fits, but
    the table plus its directory passes the budget once per sweep of the keys,
    so several partial runs spill. Catches a fold that drops a run (COUNT and
    SUM come back short) or folds one twice."""
    var state = RowHashAggSpillState(24000, _scratch_dir("agg_fold"))
    var table = _i64_table()
    _feed_i64(table, state)
    assert_true(
        state.num_spilled_runs() >= 2,
        "spilled runs: " + String(state.num_spilled_runs()),
    )
    var layout = _i64_layout()
    var pf = SpillPrefetcher()
    var out = state.finalize_with_spill(
        table, layout, _key_names(), _agg_names4(), pf
    )
    assert_equal(state.last_finalize_subpartitions(), 1)
    assert_true(out, "a result")
    var parts = Slab[RecordBatch]()
    parts.append(out.take())
    _check_i64_batches(parts)


def test_agg_spill_overflowing_fold_repartitions_by_key_hash() raises:
    """Budget 1024: every batch spills, the fold overflows, and the finalize
    repartitions every source into 8 parts (about 62 groups, 2500 bytes each,
    still over the budget, so each is split once more). Catches a repartition
    that starts from the partly folded table instead of the pre-fold snapshot
    (the runs folded before the overflow would count twice) and a part that
    loses or duplicates a group."""
    var state = RowHashAggSpillState(1024, _scratch_dir("agg_repart"))
    var table = _i64_table()
    _feed_i64(table, state)
    assert_equal(state.num_spilled_runs(), _B, "one run per batch")
    var layout = _i64_layout()
    var pf = SpillPrefetcher()
    var parts = state.finalize_with_spill_yield(
        table, layout, _key_names(), _agg_names4(), pf
    )
    assert_equal(state.last_finalize_subpartitions(), AGG_RECURSE_FANOUT)
    assert_true(len(parts) > 1, "more than one yield")
    assert_true(len(parts) <= AGG_RECURSE_FANOUT, "at most one yield per part")
    _check_i64_batches(parts)


def test_agg_spill_budget_zero_never_spills() raises:
    """Budget 0 is 'no budget': nothing spills (the spill directory, which
    is created only on a first spill, is never made) and the finalize is
    the table's own emit."""
    var state = RowHashAggSpillState(0, _scratch_dir("agg_never"))
    var table = _i64_table()
    _feed_i64(table, state)
    assert_false(state.has_spilled())
    var layout = _i64_layout()
    var pf = SpillPrefetcher()
    var out = state.finalize_with_spill(
        table, layout, _key_names(), _agg_names4(), pf
    )
    var parts = Slab[RecordBatch]()
    parts.append(out.take())
    _check_i64_batches(parts)


# =============================================================================
# Nullable STRING key: NULL and '' are different groups
# =============================================================================

comptime _SG = 40  # distinct strings, plus NULL
comptime _SR = 32
comptime _SB = 24


def _s_group(j: Int) -> Int:
    """Group of row `j` in [0, _SG]: _SG is NULL, 0 is '', g is 'x' * g
    with a suffix (so lengths differ and some pass the inline width)."""
    return (j * 13) % (_SG + 1)


def _s_text(g: Int) -> String:
    var s = String("")
    for _ in range(g):
        s += "x"
    if g > 0:
        s += String(g)
    return s


def _s_layout() raises -> RowLayout:
    var l = RowLayout()
    l.add_key_col(
        ColDescriptor(
            kind=COL_VAR_STRING,
            dtype_tag=DT_STRING,
            fixed_width=UInt16(8),
            offset_in_row=UInt16(0),
            flags=COL_FLAG_KEY_NULLABLE,
        )
    )
    l.add_payload_col(_fixed(8, DT_I64))
    l.add_payload_col(_fixed(16, DT_I64))
    l.set_fixed_row_stride(24)
    return l^


def _s_table() -> RowHashAggTable:
    var t = RowHashAggTable(8, 24)
    t.set_var_key_offsets(_one(0))
    t.add_agg(AGG_COUNT, 8)
    t.add_agg(AGG_SUM_I64, 16)
    return t^


def _s_batch(b: Int) raises -> RecordBatch:
    var sbld = ArrowStringBuilder()
    var vals = List[Int64]()
    for i in range(_SR):
        var j = b * _SR + i
        var g = _s_group(j)
        if g == _SG:
            sbld.push_null()
        else:
            var t = _s_text(g)
            sbld.push_bytes(t.as_bytes())
        vals.append(Int64(j))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, True))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(sbld^.build())
    rbb.add_column(Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(vals)
    ))
    return rbb.build(sb.build())


def test_agg_spill_string_key_keeps_null_and_empty_apart() raises:
    """Budget 256 over a nullable STRING key: runs spill with their string
    heaps, the fold overflows and repartitions. The NULL group and the ''
    group come back as two groups with their own COUNT and SUM, and every
    other string group comes back once. Catches a restore that drops the
    variable-width key declaration (it would hash the heap descriptor and
    split or merge string groups) and an image read without its heap."""
    var state = RowHashAggSpillState(256, _scratch_dir("agg_strings"))
    var table = _s_table()
    var layout = _s_layout()
    for b in range(_SB):
        var rb = _s_batch(b)
        table.upsert_batch(BatchView(rb), _one(0), _same(1, 2), layout)
        state.maybe_spill_run(table)
    assert_true(state.num_spilled_runs() >= 2)
    var pf = SpillPrefetcher()
    var out = state.finalize_with_spill(
        table, layout, _key_names(), _agg_names2(), pf
    )
    assert_equal(state.last_finalize_subpartitions(), AGG_RECURSE_FANOUT)
    var rb = out.take()

    var want_count = List[Int64]()
    var want_sum = List[Int64]()
    var seen = List[Bool]()
    for _ in range(_SG + 1):
        want_count.append(0)
        want_sum.append(0)
        seen.append(False)
    for j in range(_SB * _SR):
        var g = _s_group(j)
        want_count[g] += 1
        want_sum[g] += Int64(j)

    assert_equal(rb.num_rows(), _SG + 1, "40 strings, '' among them, and NULL")
    var bv = BatchView(rb)
    for r in range(rb.num_rows()):
        var g: Int
        if bv.col_is_null(0, r):
            g = _SG
        else:
            var s = bv.col_str(0).get(r).to_string()
            g = -1
            for c in range(_SG):
                if _s_text(c) == s:
                    g = c
            assert_true(g >= 0, "a key the input never held: '" + s + "'")
        assert_false(seen[g], "group " + String(g) + " emitted twice")
        seen[g] = True
        assert_equal(_i64(rb, 1, r), want_count[g], "COUNT of group " + String(g))
        assert_equal(_i64(rb, 2, r), want_sum[g], "SUM of group " + String(g))
    assert_true(seen[_SG], "the NULL group")
    assert_true(seen[0], "the '' group")


def main() raises:
    var s = TestSuite()
    s.test[test_agg_spill_runs_fold_back_into_the_in_memory_table]()
    s.test[test_agg_spill_overflowing_fold_repartitions_by_key_hash]()
    s.test[test_agg_spill_budget_zero_never_spills]()
    s.test[test_agg_spill_string_key_keeps_null_and_empty_apart]()
    s^.run()
