# =============================================================================
# test_udf_e2e_agg_fn.mojo: a custom stateful AggFn, per group, over a
# nullable column, through komira_agg's `AggFnAgg` adapter.
# =============================================================================
#
# The UDF: `DistinctBelow`, a distinct count of small non-negative integers
# held in a 64-bit set, with a captured `limit` (a value at or past it makes
# the group's answer unknown, -1). Its state is a POD (`PodState`), its merge
# is a set union, and it is driven the way a parallel grouped aggregate is:
# three workers, each with its own copy of the UDF inside an
# `AggFnAgg[DistinctBelow, 1]`, fold their rows into per-group partial states;
# the partials are then combined per group, in three different worker orders,
# and finalized. Every expected value is written out by hand.
#
# What the three orders check: `AggFnAgg.combine` accumulates every worker's
# partial into the running state (group 0's rows are split across all three
# workers, so a combine that kept only one partial, or dropped `into`, reads
# a wrong count). They do NOT check order sensitivity: `DistinctBelow.merge`
# is a union and a sum, commutative and associative, so the orders agree by
# construction.
#
# Four groups: 0 and 1 with values and nulls, 2 with only nulls, 3 with no
# rows at all. Two fold paths, which must agree:
#   * MASKED CHUNKS: `Aggregator.update_chunk[4]` (the default body komira
#     provides), one call per (chunk, group) with the lane mask "in this group"
#     AND the column's validity as `ColView.validity_load[4]` reads it from
#     the Arrow bitmap. This is the path that keeps nulls out.
#   * ROW AT A TIME: `AggFnAgg.update_scalar` on the valid rows only.
#
# A null slot holds 0 and no valid value is 0, so a null that reached the
# fold would add a distinct value (bit 0) and a row: groups 0 and 2 would read
# 4 and 1 instead of 3 and 0.
#
# What komira does not provide, so the test does: the group routing (which
# state a row folds into) and the partial-merge schedule. There is no grouped
# driver for `AggFnAgg` in komira; `AggFnAgg.init`/`finalize` are compile-time
# refusals by design, so the per-group `init` and `finalize` are the UDF's own
# methods, called on the test's copy of it. `AggFn.finalize` returns a
# non-null value, so this UDF reports an empty or all-null group as 0 (which
# is COUNT(DISTINCT)'s SQL answer); an aggregate whose SQL answer for such a
# group is NULL (a mean) cannot say so through this trait.
#
# Planted mutant (reverted): `Aggregator.update_chunk`'s default body,
# `if i + lane < n and valid[lane]` -> `if i + lane < n` (the mask ignored).
# `test_masked_chunks_keep_nulls_out` and
# `test_the_capture_rides_into_every_worker` went red (group 0 read 6 distinct
# values, every lane of every chunk, other groups' and nulls' included,
# instead of 3); no other welded test in the rebuilt closure did.
#
# Planted mutant (reverted): the same line, `if i + lane < n and
# valid[lane]` -> `if valid[lane]` (the bounds check dropped).
# `test_a_partial_last_chunk_folds_only_in_bounds_lanes` went red (the chunk
# at row 8 folded 4 rows instead of 2); no other welded test in the rebuilt
# closure did.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.batch_view import BatchView, batch_view_over

from komira_udf.agg_fn import AggFn, PodState
from komira_udf.auto_komira_schema import AutoKomiraSchema
from komira_udf.schema_descriptor import DT_I64, schema_of
from komira_agg.agg_fn_agg import AggFnAgg

from komira_udf_e2e.columns import all_valid, i64_column


# --- the UDF --------------------------------------------------------------------


@fieldwise_init
struct DistinctState(PodState):
    var bits: UInt64
    var rows: Int64
    var overflow: Int64


@fieldwise_init
struct VRow(AutoKomiraSchema, Copyable, Movable):
    var v: Int64


def _popcount(x: UInt64) -> Int64:
    var n = Int64(0)
    var y = x
    while y != 0:
        n += Int64(y & 1)
        y >>= 1
    return n


@fieldwise_init
struct DistinctBelow(AggFn):
    """COUNT(DISTINCT v) for `0 <= v < limit <= 64`; -1 once any value of the
    group fell outside that range. `limit` is the captured state of the UDF
    instance, copied into every worker's adapter."""

    var limit: Int64
    comptime InRow = VRow
    comptime OutputSchema = schema_of["distinct_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = DistinctState
    comptime UDF_ID = UInt32(20_101)

    def init(self) -> DistinctState:
        return DistinctState(UInt64(0), Int64(0), Int64(0))

    def update(self, mut s: DistinctState, row: VRow):
        self.update_scalar(s, row.v)

    def update_scalar[
        *Ts: Copyable & Movable
    ](self, mut s: DistinctState, *vals: *Ts):
        var v = rebind[Int64](vals[0])
        s.rows += 1
        if v < 0 or v >= self.limit:
            s.overflow += 1
            return
        s.bits |= UInt64(1) << UInt64(v)

    def merge(self, a: DistinctState, b: DistinctState) -> DistinctState:
        return DistinctState(
            a.bits | b.bits, a.rows + b.rows, a.overflow + b.overflow
        )

    def finalize(self, s: DistinctState) -> Scalar[DType.int64]:
        if s.overflow > 0:
            return -1
        return _popcount(s.bits)


comptime Agg = AggFnAgg[DistinctBelow, 1]
comptime N_GROUPS = 4
comptime N_WORKERS = 3


# --- the batch ---------------------------------------------------------------------
#
#   row  g  v                  group 0: 5 5 9 12 NULL  -> distinct 3, 4 rows
#    0   0  5                  group 1: 7 NULL 7 3     -> distinct 2, 3 rows
#    1   1  7                  group 2: NULL NULL NULL -> distinct 0, 0 rows
#    2   2  NULL               group 3: no rows        -> distinct 0, 0 rows
#    3   0  5
#    4   1  NULL               with limit 8, group 0's 9 and 12 are out of
#    5   0  9                  range: group 0 -> -1, the others unchanged.
#    6   2  NULL
#    7   1  7
#    8   0  12
#    9   1  3
#   10   2  NULL
#   11   0  NULL


def _batch() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("g", DType.int64, False))
    sb.add_field(Field("v", DType.int64, True))
    var g: List[Int64] = [0, 1, 2, 0, 1, 0, 2, 1, 0, 1, 2, 0]
    var v: List[Int64] = [5, 7, 0, 5, 0, 9, 0, 7, 12, 3, 0, 0]
    var ok: List[Bool] = [True, True, False, True, False, True, False, True, True, True, False, False]
    return RecordBatch.from_typed_columns_2(
        sb.build(), i64_column(g, all_valid(len(g))), i64_column(v, ok)
    )


# --- the drive -----------------------------------------------------------------------


def _fresh_states(f: DistinctBelow) -> List[DistinctState]:
    var s = List[DistinctState]()
    for _ in range(N_GROUPS):
        s.append(f.init())
    return s^


def _fold_masked_chunks[
    bo: Origin[mut=False]
](f: DistinctBelow, bv: BatchView[bo]) raises -> List[List[DistinctState]]:
    """Worker `w` folds chunks `w, w + 3, ...` of four rows; within a chunk,
    one `update_chunk[4]` per group, masked to the lanes of that group that
    the validity bitmap says are valid."""
    var partials = List[List[DistinctState]]()
    for w in range(N_WORKERS):
        var agg = Agg(f.copy())
        var states = _fresh_states(f)
        var start = w * 4
        while start < bv.n_rows():
            # The batch is 12 rows, so every chunk is whole and
            # `validity_load[4]` (which refuses a range past the end) is in
            # bounds.
            var valid = bv.col_i64(1).validity_load[4](start)
            for g in range(N_GROUPS):
                var in_g = SIMD[DType.bool, 4](fill=False)
                for lane in range(4):
                    in_g[lane] = Int(bv.col_i64(0).load[1](start + lane)[0]) == g
                agg.update_chunk[4, bo](states[g], bv, start, in_g & valid)
            start += 4 * N_WORKERS
        partials.append(states^)
    return partials^


def _fold_rows[
    bo: Origin[mut=False]
](f: DistinctBelow, bv: BatchView[bo]) raises -> List[List[DistinctState]]:
    """Worker `w` folds rows `r` with `r % 3 == w`, valid rows only."""
    var partials = List[List[DistinctState]]()
    for w in range(N_WORKERS):
        var agg = Agg(f.copy())
        var states = _fresh_states(f)
        for r in range(bv.n_rows()):
            if r % N_WORKERS != w or bv.col_is_null(1, r):
                continue
            var g = Int(bv.col_i64(0).load[1](r)[0])
            agg.update_scalar[bo](states[g], bv, r)
        partials.append(states^)
    return partials^


def _merge_in_order(
    f: DistinctBelow,
    partials: List[List[DistinctState]],
    order: List[Int],
) -> List[DistinctState]:
    """Combine every worker's partial for each group, in `order`, through
    `AggFnAgg.combine`."""
    var agg = Agg(f.copy())
    var out = _fresh_states(f)
    for g in range(N_GROUPS):
        for k in range(len(order)):
            agg.combine(out[g], partials[order[k]][g].copy())
    return out^


def _check(
    f: DistinctBelow,
    partials: List[List[DistinctState]],
    want_distinct: List[Int64],
    want_rows: List[Int64],
    label: String,
) raises:
    var orders: List[List[Int]] = [[0, 1, 2], [2, 0, 1], [1, 2, 0]]
    for o in range(len(orders)):
        var merged = _merge_in_order(f, partials, orders[o])
        for g in range(N_GROUPS):
            var where = label + " order " + String(o) + " group " + String(g)
            assert_equal(f.finalize(merged[g]), want_distinct[g], where)
            assert_equal(merged[g].rows, want_rows[g], where + " rows")


def test_masked_chunks_keep_nulls_out() raises:
    var batch = _batch()
    var bv = batch_view_over(batch)
    var f = DistinctBelow(limit=64)
    var want_d: List[Int64] = [3, 2, 0, 0]
    var want_r: List[Int64] = [4, 3, 0, 0]
    _check(f, _fold_masked_chunks(f, bv), want_d, want_r, "chunks")


def test_row_at_a_time_agrees() raises:
    var batch = _batch()
    var bv = batch_view_over(batch)
    var f = DistinctBelow(limit=64)
    var want_d: List[Int64] = [3, 2, 0, 0]
    var want_r: List[Int64] = [4, 3, 0, 0]
    _check(f, _fold_rows(f, bv), want_d, want_r, "rows")


def test_the_capture_rides_into_every_worker() raises:
    """`limit = 8` is set on the UDF the test owns; each worker's adapter
    holds a copy. Group 0's 9 and 12 must be out of range in whichever worker
    folds them."""
    var batch = _batch()
    var bv = batch_view_over(batch)
    var f = DistinctBelow(limit=8)
    var want_d: List[Int64] = [-1, 2, 0, 0]
    var want_r: List[Int64] = [4, 3, 0, 0]
    _check(f, _fold_masked_chunks(f, bv), want_d, want_r, "limit 8 chunks")
    _check(f, _fold_rows(f, bv), want_d, want_r, "limit 8 rows")


def test_a_partial_last_chunk_folds_only_in_bounds_lanes() raises:
    """`update_chunk[4]`'s default body over a 10-row batch with every lane
    of the mask set: the chunk at row 8 has lanes 2 and 3 (rows 10, 11) past
    the end, and only its in-bounds half may fold. The values are 1..10, all
    valid; a lane past the end that folded would add at least one row (and
    whatever its slot holds) to the state."""
    var sb = SchemaBuilder()
    sb.add_field(Field("g", DType.int64, False))
    sb.add_field(Field("v", DType.int64, False))
    var g: List[Int64] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    var v: List[Int64] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    var batch = RecordBatch.from_typed_columns_2(
        sb.build(), i64_column(g, all_valid(10)), i64_column(v, all_valid(10))
    )
    var bv = batch_view_over(batch)
    var f = DistinctBelow(limit=64)
    var agg = Agg(f.copy())
    var all_lanes = SIMD[DType.bool, 4](fill=True)
    # The partial chunk alone: rows 8 and 9 (values 9 and 10).
    var tail = f.init()
    agg.update_chunk[4](tail, bv, 8, all_lanes)
    assert_equal(tail.rows, 2, "rows folded from the chunk at row 8")
    assert_equal(tail.bits, (UInt64(1) << 9) | (UInt64(1) << 10), "tail bits")
    # The whole batch, chunk by chunk: exactly the ten values.
    var whole = f.init()
    var i = 0
    while i < bv.n_rows():
        agg.update_chunk[4](whole, bv, i, all_lanes)
        i += 4
    assert_equal(whole.rows, 10, "rows folded over the whole batch")
    assert_equal(f.finalize(whole), 10, "distinct values over the whole batch")
    assert_equal(whole.bits, UInt64(0x7FE), "bits 1..10 and nothing else")


def test_named_row_update_equals_the_positional_one() raises:
    var f = DistinctBelow(limit=64)
    var a = f.init()
    var b = f.init()
    var vals: List[Int64] = [5, 9, 5, 63]
    for i in range(len(vals)):
        f.update(a, VRow(vals[i]))
        f.update_scalar(b, vals[i])
    assert_equal(a.bits, b.bits)
    assert_equal(a.rows, 4)
    assert_equal(f.finalize(a), 3)
    assert_true(Agg.OUT_DT == DType.int64)
    var si = materialize[DistinctBelow.InputSchema]()
    assert_equal(si.cols[0].name, "v")
    assert_equal(si.cols[0].dtype, DT_I64)


def main() raises:
    var suite = TestSuite()
    suite.test[test_masked_chunks_keep_nulls_out]()
    suite.test[test_row_at_a_time_agrees]()
    suite.test[test_the_capture_rides_into_every_worker]()
    suite.test[test_a_partial_last_chunk_folds_only_in_bounds_lanes]()
    suite.test[test_named_row_update_equals_the_positional_one]()
    suite^.run()
