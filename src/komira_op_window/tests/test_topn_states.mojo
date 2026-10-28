# =============================================================================
# test_topn_states -- the INT64 top-N heaps, states and stages
# =============================================================================
#
# `topn_stage` (the scaffolds), `stage_topn` (the FusedMorselOp breakers),
# `topn_state.TopNState` and `partition_topn_state.PartitionTopNState`.
# Expected rows are derived by hand: ASC keeps the N smallest keys, DESC the
# N largest, NULL keys last in both directions (docs/design/query_semantics.md
# §4.1), a NULL partition key is one partition (§9.9). `Int64.MIN` and
# `Int64.MAX` are in the fixtures: a DESC heap that stores `-key` sees
# `-Int64.MIN` overflow back to `Int64.MIN` and drops the smallest key last.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView, batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_engine_runtime.spill.local_disk import LocalDiskSpillStorage
from komira_eval.expr_x_conformers import ColXI64
from komira_expr.expr_sortable_key import SORT_DIR_ASC, SORT_DIR_DESC
from komira_libc.posix import _read_env
from komira_operator_api.breaker_state_trait import BreakerState
from komira_udf.column_resolver import ColumnResolver

from komira_op_window.bounded_heap import BoundedHeapInt64PayloadDynamic, BoundedHeapStringPayload
from komira_op_window.partition_topn_state import (
    PTOPN_DIR_ASC,
    PTOPN_DIR_DESC,
    PartitionTopNState,
)
from komira_op_window.stage_topn import Stage_TopN_1_I64, Stage_TopN_Dynamic_1_I64
from komira_op_window.topn_stage import TopNStageScaffoldI64, TopNStageScaffoldI64Dynamic
from komira_op_window.topn_state import TOPN_DIR_ASC, TOPN_DIR_DESC, TopNState


comptime _MIN = Int64.MIN
comptime _MAX = Int64.MAX


def _i64(vals: List[Int64], valid: List[Bool]) -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.store[1](i, vals[i])
        if not valid[i]:
            arr._set_null(i)
    return Column.from_primitive[DType.int64](arr)


def _all(n: Int) -> List[Bool]:
    var v = List[Bool]()
    for _ in range(n):
        v.append(True)
    return v^


def _batch(names: List[String], var cols: List[Column[HeapRegion]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var bb = RecordBatchBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], ArrowType.INT64, True))
    for i in range(len(cols)):
        bb.add_column(cols[i].share())
    return bb.build(sb.build())


def _get(rb: RecordBatch, col: Int, row: Int) -> Int64:
    ref c = rb.column_at(col)
    return c._data.get_typed[Scalar[DType.int64]](c._offset + row)


def _null(rb: RecordBatch, col: Int, row: Int) -> Bool:
    return rb.column_at(col).is_null_at(row)


# =============================================================================
# The scaffolds
# =============================================================================


def test_scaffold_desc_keeps_largest_including_extremes() raises:
    # Keys 0, MIN, MAX, -5, 7. DESC top 3: MAX, 7, 0. ASC top 3: MIN, -5, 0.
    var keys: List[Int64] = [0, _MIN, _MAX, -5, 7]
    var desc = TopNStageScaffoldI64[3].new(SORT_DIR_DESC)
    var asc = TopNStageScaffoldI64[3].new(SORT_DIR_ASC)
    var dyn = TopNStageScaffoldI64Dynamic.new(3, SORT_DIR_DESC)
    for i in range(len(keys)):
        desc.push_row(keys[i], Int64(i))
        asc.push_row(keys[i], Int64(i))
        dyn.push_row(keys[i], Int64(i))
    var d = desc.finalize_emit()
    var a = asc.finalize_emit()
    var y = dyn.finalize_emit()
    var want_d: List[Int64] = [_MAX, 7, 0]
    var want_a: List[Int64] = [_MIN, -5, 0]
    for i in range(3):
        assert_equal(d[i].key, want_d[i])
        assert_equal(y[i].key, want_d[i])
        assert_equal(a[i].key, want_a[i])
    # DESC with the minimum among only a few keys: top 2 of (MIN, 3) is 3, MIN.
    var d2 = TopNStageScaffoldI64[2].new(SORT_DIR_DESC)
    d2.push_row(_MIN, 0)
    d2.push_row(3, 1)
    var e2 = d2.finalize_emit()
    assert_equal(e2[0].key, 3)
    assert_equal(e2[1].key, _MIN)


def _resolver_k() raises -> ColumnResolver:
    var names: List[String] = ["k"]
    var indices: List[Int] = [0]
    var dts: List[DType] = [DType.int64]
    var ats: List[ArrowType] = [ArrowType.INT64]
    return ColumnResolver(names^, indices^, dts^, ats^)


def _schema_kp() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("p", ArrowType.INT64, True))
    return sb.build()


def test_stage_topn_breakers() raises:
    # k = 3, 1, MIN, 5: DESC top 2 -> (5, row 3), (3, row 0); dynamic ASC top 2
    # -> (MIN, row 2), (1, row 1). Nothing is emitted per batch.
    var keys: List[Int64] = [3, 1, _MIN, 5]
    var cols = List[Column[HeapRegion]]()
    cols.append(_i64(keys, _all(4)))
    var names: List[String] = ["k"]
    var batch = _batch(names, cols^)
    var bv = batch_view_over(batch)

    var st = Stage_TopN_1_I64[ColXI64["k"], 2](
        scaffold=TopNStageScaffoldI64[2].new(SORT_DIR_DESC), output_schema=_schema_kp()
    )
    st.bind(_resolver_k())
    var pr = st.process_batch(bv)
    assert_false(Bool(pr.batch))
    var out_opt = st^.finalize()
    var out = out_opt.take()
    assert_equal(out.num_rows(), 2)
    assert_equal(_get(out, 0, 0), 5)
    assert_equal(_get(out, 1, 0), 3)
    assert_equal(_get(out, 0, 1), 3)
    assert_equal(_get(out, 1, 1), 0)

    var dy = Stage_TopN_Dynamic_1_I64[ColXI64["k"]](
        scaffold=TopNStageScaffoldI64Dynamic.new(2, SORT_DIR_ASC), output_schema=_schema_kp()
    )
    dy.bind(_resolver_k())
    _ = dy.process_batch(bv)
    var out2_opt = dy^.finalize()
    var out2 = out2_opt.take()
    assert_equal(_get(out2, 0, 0), _MIN)
    assert_equal(_get(out2, 1, 0), 2)
    assert_equal(_get(out2, 0, 1), 1)


# =============================================================================
# TopNState
# =============================================================================


def _kp_batch(keys: List[Int64], valid: List[Bool]) raises -> RecordBatch:
    """(key, payload = row index) with NULL keys where `valid` is False."""
    var pays = List[Int64]()
    for i in range(len(keys)):
        pays.append(Int64(i))
    var cols = List[Column[HeapRegion]]()
    cols.append(_i64(keys, valid))
    cols.append(_i64(pays, _all(len(keys))))
    var names: List[String] = ["key", "payload"]
    return _batch(names, cols^)


def _feed[N: Int, D: Int](mut st: TopNState[N, 0, 1, D], batch: RecordBatch) raises:
    var bv = batch_view_over(batch)
    for r in range(batch.num_rows()):
        st.feed_row(bv, r)


# Keys 5, NULL(slot MIN), 1, NULL(slot MAX), MIN, 7 at rows 0..5.
def _nullable_fixture() raises -> RecordBatch:
    var keys: List[Int64] = [5, _MIN, 1, _MAX, _MIN, 7]
    var valid: List[Bool] = [True, False, True, False, True, True]
    return _kp_batch(keys, valid)


def test_topn_state_null_keys_last() raises:
    # ASC top 3: MIN (row 4), 1 (row 2), 5 (row 0) -- no NULL row.
    var asc3 = TopNState[3, 0, 1, TOPN_DIR_ASC]()
    _feed(asc3, _nullable_fixture())
    var o1_opt = asc3.drain_to_record_batch()
    var o1 = o1_opt.take()
    assert_equal(o1.num_rows(), 3)
    var want_k1: List[Int64] = [_MIN, 1, 5]
    var want_p1: List[Int64] = [4, 2, 0]
    for r in range(3):
        assert_false(_null(o1, 0, r))
        assert_equal(_get(o1, 0, r), want_k1[r])
        assert_equal(_get(o1, 1, r), want_p1[r])

    # DESC top 5: 7, 5, 1, MIN, then one NULL row (a NULL sorts last in DESC
    # too). The DESC heap keeps MIN: a negated MIN would compare as largest.
    var desc5 = TopNState[5, 0, 1, TOPN_DIR_DESC]()
    _feed(desc5, _nullable_fixture())
    var o2_opt = desc5.drain_to_record_batch()
    var o2 = o2_opt.take()
    assert_equal(o2.num_rows(), 5)
    var want_k2: List[Int64] = [7, 5, 1, _MIN]
    for r in range(4):
        assert_false(_null(o2, 0, r))
        assert_equal(_get(o2, 0, r), want_k2[r])
    assert_true(_null(o2, 0, 4))
    var p4 = _get(o2, 1, 4)
    assert_true(p4 == 1 or p4 == 3)

    # ASC top 8 of 6 rows: the 4 values then both NULL rows.
    var asc8 = TopNState[8, 0, 1, TOPN_DIR_ASC]()
    _feed(asc8, _nullable_fixture())
    var o3_opt = asc8.drain_to_record_batch()
    var o3 = o3_opt.take()
    assert_equal(o3.num_rows(), 6)
    assert_true(_null(o3, 0, 4) and _null(o3, 0, 5))


def test_topn_state_combine_equals_one_feed() raises:
    # Two workers each fed half the rows give the rows of one worker fed all.
    var keys: List[Int64] = [9, 2, _MIN, 4, 6, 1, 8, 3]
    var valid: List[Bool] = [True, True, True, False, True, True, False, True]
    var all_rows = _kp_batch(keys, valid)
    var one = TopNState[5, 0, 1, TOPN_DIR_DESC]()
    _feed(one, all_rows)
    var w0 = TopNState[5, 0, 1, TOPN_DIR_DESC]()
    var w1 = TopNState[5, 0, 1, TOPN_DIR_DESC]()
    var bv = batch_view_over(all_rows)
    for r in range(8):
        if r % 2 == 0:
            w0.feed_row(bv, r)
        else:
            w1.feed_row(bv, r)
    w0.combine(w1^)
    var a_opt = one.drain_to_record_batch()
    var a = a_opt.take()
    var b_opt = w0.drain_to_record_batch()
    var b = b_opt.take()
    assert_equal(a.num_rows(), 5)
    assert_equal(b.num_rows(), 5)
    for r in range(5):
        assert_equal(_get(a, 0, r), _get(b, 0, r))
        assert_equal(_get(a, 1, r), _get(b, 1, r))


def _scratch_dir() raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d


def test_topn_state_spill_restore_keeps_null_rows() raises:
    # Spill after half the rows, feed the rest, restore: the drain equals the
    # unspilled drain, NULL-key rows included.
    var keys: List[Int64] = [5, _MIN, 1, _MAX, _MIN, 7]
    var valid: List[Bool] = [True, False, True, False, True, True]
    var batch = _kp_batch(keys, valid)
    var bv = batch_view_over(batch)
    var ref_state = TopNState[6, 0, 1, TOPN_DIR_DESC]()
    _feed(ref_state, batch)
    var st = TopNState[6, 0, 1, TOPN_DIR_DESC]()
    var storage = LocalDiskSpillStorage.with_unlimited(_scratch_dir() + "/topn_spill")
    for r in range(3):
        st.feed_row(bv, r)
    _ = st.spill_to_storage(storage)
    assert_equal(st.memory_usage_bytes(), 0)
    for r in range(3, 6):
        st.feed_row(bv, r)
    st.restore_from_storage(storage)
    var a_opt = ref_state.drain_to_record_batch()
    var a = a_opt.take()
    var b_opt = st.drain_to_record_batch()
    var b = b_opt.take()
    assert_equal(a.num_rows(), 6)
    assert_equal(b.num_rows(), 6)
    for r in range(4):
        assert_equal(_get(a, 0, r), _get(b, 0, r))
        assert_equal(_get(a, 1, r), _get(b, 1, r))
    assert_true(_null(b, 0, 4) and _null(b, 0, 5))


# =============================================================================
# PartitionTopNState
# =============================================================================


def test_partition_topn_state_null_partition_and_order_keys() raises:
    # g: 1, NULL(slot 1), 1, NULL(slot 1), 2 ; k: 4, 9, NULL, MIN, 3.
    # Partitions in first-seen order: g=1, g=NULL, g=2. DESC top 2 each:
    #   g=1: 4, then the NULL-k row; g=NULL: 9, MIN; g=2: 3.
    var g: List[Int64] = [1, 1, 1, 1, 2]
    var gvalid: List[Bool] = [True, False, True, False, True]
    var k: List[Int64] = [4, 9, 0, _MIN, 3]
    var kvalid: List[Bool] = [True, True, False, True, True]
    var p: List[Int64] = [0, 1, 2, 3, 4]
    var cols = List[Column[HeapRegion]]()
    cols.append(_i64(g, gvalid))
    cols.append(_i64(k, kvalid))
    cols.append(_i64(p, _all(5)))
    var names: List[String] = ["g", "k", "p"]
    var batch = _batch(names, cols^)
    var bv = batch_view_over(batch)
    var st = PartitionTopNState[0, 1, 2, 2, PTOPN_DIR_DESC]()
    for r in range(5):
        st.feed_row(bv, r)
    assert_equal(st.n_partitions(), 3)
    var out_opt = st.drain_to_record_batch()
    var out = out_opt.take()
    assert_equal(out.num_rows(), 5)
    # g=1
    assert_equal(_get(out, 0, 0), 1)
    assert_equal(_get(out, 1, 0), 4)
    assert_true(_null(out, 1, 1))
    assert_equal(_get(out, 2, 1), 2)
    # g=NULL
    assert_true(_null(out, 0, 2) and _null(out, 0, 3))
    assert_equal(_get(out, 1, 2), 9)
    assert_equal(_get(out, 1, 3), _MIN)
    # g=2
    assert_equal(_get(out, 0, 4), 2)
    assert_equal(_get(out, 1, 4), 3)

    # combine: the same rows split over two workers give the same partitions.
    var w0 = PartitionTopNState[0, 1, 2, 2, PTOPN_DIR_DESC]()
    var w1 = PartitionTopNState[0, 1, 2, 2, PTOPN_DIR_DESC]()
    for r in range(5):
        if r < 2:
            w0.feed_row(bv, r)
        else:
            w1.feed_row(bv, r)
    w0.combine(w1^)
    var out2_opt = w0.drain_to_record_batch()
    var out2 = out2_opt.take()
    assert_equal(out2.num_rows(), 5)
    for r in range(5):
        assert_equal(_null(out2, 0, r), _null(out, 0, r))
        assert_equal(_null(out2, 1, r), _null(out, 1, r))
        if not _null(out2, 1, r):
            assert_equal(_get(out2, 1, r), _get(out, 1, r))


# =============================================================================
# Ties: equal keys keep the smaller payload (row) first, as a stable sort does
# =============================================================================


def _drain[S: BreakerState](st: S) raises -> RecordBatch:
    var o = st.drain_to_record_batch()
    return o.take()


def _payloads(rb: RecordBatch, col: Int) -> List[Int64]:
    var out = List[Int64]()
    for r in range(rb.num_rows()):
        out.append(_get(rb, col, r))
    return out^


def _check_payloads(rb: RecordBatch, col: Int, want: List[Int64]) raises:
    assert_equal(rb.num_rows(), len(want))
    for r in range(len(want)):
        assert_equal(_get(rb, col, r), want[r])


def test_topn_state_ties_follow_row_order() raises:
    # Keys 5 5 9 5 5 1 5 at rows 0..6, every key valid.
    var keys: List[Int64] = [5, 5, 9, 5, 5, 1, 5]
    var valid = _all(7)
    var batch = _kp_batch(keys, valid)
    var bv = batch_view_over(batch)

    # ASC top 4: 1 (row 5), then the first three 5s by row: 0, 1, 3.
    var asc_want: List[Int64] = [5, 0, 1, 3]
    var asc = TopNState[4, 0, 1, TOPN_DIR_ASC]()
    _feed(asc, batch)
    var asc_out = _drain(asc)
    _check_payloads(asc_out, 1, asc_want)

    # The same rows fed last-row-first keep the same rows in the same order.
    var rev = TopNState[4, 0, 1, TOPN_DIR_ASC]()
    for r in range(6, -1, -1):
        rev.feed_row(bv, r)
    _check_payloads(_drain(rev), 1, asc_want)

    # Two workers merged in either order give the same rows again.
    var a0 = TopNState[4, 0, 1, TOPN_DIR_ASC]()
    var a1 = TopNState[4, 0, 1, TOPN_DIR_ASC]()
    for r in range(7):
        if r < 4:
            a1.feed_row(bv, r)
        else:
            a0.feed_row(bv, r)
    a0.combine(a1^)
    _check_payloads(_drain(a0), 1, asc_want)

    # DESC top 4: 9 (row 2), then the first three 5s by row: 0, 1, 3.
    var desc_want: List[Int64] = [2, 0, 1, 3]
    var desc = TopNState[4, 0, 1, TOPN_DIR_DESC]()
    for r in range(6, -1, -1):
        desc.feed_row(bv, r)
    _check_payloads(_drain(desc), 1, desc_want)


def test_partition_topn_state_ties_follow_row_order() raises:
    # One partition; order keys 7 7 7 3 7 at rows 0..4, fed last-row-first.
    var g: List[Int64] = [1, 1, 1, 1, 1]
    var k: List[Int64] = [7, 7, 7, 3, 7]
    var p: List[Int64] = [0, 1, 2, 3, 4]
    var cols = List[Column[HeapRegion]]()
    cols.append(_i64(g, _all(5)))
    cols.append(_i64(k, _all(5)))
    cols.append(_i64(p, _all(5)))
    var names: List[String] = ["g", "k", "p"]
    var batch = _batch(names, cols^)
    var bv = batch_view_over(batch)
    var asc = PartitionTopNState[0, 1, 2, 3, PTOPN_DIR_ASC]()
    for r in range(4, -1, -1):
        asc.feed_row(bv, r)
    var want_asc: List[Int64] = [3, 0, 1]
    _check_payloads(_drain(asc), 2, want_asc)
    var desc = PartitionTopNState[0, 1, 2, 3, PTOPN_DIR_DESC]()
    for r in range(4, -1, -1):
        desc.feed_row(bv, r)
    var want_desc: List[Int64] = [0, 1, 2]
    _check_payloads(_drain(desc), 2, want_desc)


def _push_str[N: Int, D: Int](
    mut h: BoundedHeapStringPayload[N, D], key: String, pay: Int64
):
    _ = h.push_returning_evicted(key.as_bytes(), pay)


def _string_heap_payloads[N: Int, D: Int](mut h: BoundedHeapStringPayload[N, D]) -> List[Int64]:
    var out = List[Int64]()
    var slots = h.extract_sorted()
    for i in range(len(slots)):
        out.append(slots[i].payload_row_id)
    return out^


def test_string_heap_ties_follow_payload_order() raises:
    # Rows: b a a a (payloads 0..3). ASC top 2: the first two a's.
    var fwd = BoundedHeapStringPayload[2, 0]()
    _push_str(fwd, "b", 0)
    _push_str(fwd, "a", 1)
    _push_str(fwd, "a", 2)
    _push_str(fwd, "a", 3)
    var want_asc: List[Int64] = [1, 2]
    var fgot = _string_heap_payloads(fwd)
    assert_equal(len(fgot), 2)
    assert_equal(fgot[0], want_asc[0])
    assert_equal(fgot[1], want_asc[1])
    var fwd2 = BoundedHeapStringPayload[2, 0]()
    _push_str(fwd2, "a", 3)
    _push_str(fwd2, "a", 2)
    _push_str(fwd2, "a", 1)
    _push_str(fwd2, "b", 0)
    var got = _string_heap_payloads(fwd2)
    assert_equal(len(got), 2)
    assert_equal(got[0], want_asc[0])
    assert_equal(got[1], want_asc[1])
    # DESC top 2 of b b b a (payloads 0..3), fed last-first: b rows 0 and 1.
    var d = BoundedHeapStringPayload[2, 1]()
    _push_str(d, "a", 3)
    _push_str(d, "b", 2)
    _push_str(d, "b", 1)
    _push_str(d, "b", 0)
    var dgot = _string_heap_payloads(d)
    assert_equal(len(dgot), 2)
    assert_equal(dgot[0], 0)
    assert_equal(dgot[1], 1)


def test_stage_topn_ties_across_batches_follow_row_order() raises:
    # Two batches of keys [4, 4, 1] and [4, 1, 4] (rows 0..5). ASC top 3: the
    # two 1s (rows 2, 4) then the first 4 (row 0). The payload is the row
    # index across batches; a batch-local index would let row 3 (index 0 of
    # the second batch) displace row 1.
    var k0: List[Int64] = [4, 4, 1]
    var k1: List[Int64] = [4, 1, 4]
    var c0 = List[Column[HeapRegion]]()
    c0.append(_i64(k0, _all(3)))
    var c1 = List[Column[HeapRegion]]()
    c1.append(_i64(k1, _all(3)))
    var names: List[String] = ["k"]
    var b0 = _batch(names, c0^)
    var b1 = _batch(names, c1^)
    var st = Stage_TopN_1_I64[ColXI64["k"], 3](
        scaffold=TopNStageScaffoldI64[3].new(SORT_DIR_ASC), output_schema=_schema_kp()
    )
    st.bind(_resolver_k())
    _ = st.process_batch(batch_view_over(b0))
    _ = st.process_batch(batch_view_over(b1))
    var out_opt = st^.finalize()
    var out = out_opt.take()
    var want: List[Int64] = [2, 4, 0]
    _check_payloads(out, 1, want)

# =============================================================================
# NULL-key rows: the kept rows do not depend on feed or merge order
# =============================================================================


def _worker[N: Int, D: Int](bv: BatchView, n_rows: Int, w: Int, nw: Int) raises -> TopNState[N, 0, 1, D]:
    """The state of worker `w` of `nw`, fed rows r with r % nw == w."""
    var st = TopNState[N, 0, 1, D]()
    for r in range(n_rows):
        if r % nw == w:
            st.feed_row(bv, r)
    return st^


def _merged[N: Int, D: Int](
    batch: RecordBatch, nw: Int, reverse_merge: Bool
) raises -> RecordBatch:
    """`nw` workers, worker w fed rows r with r % nw == w, merged by a chain
    of `combine`s that starts at worker 0 (at worker nw - 1 when
    `reverse_merge`) and folds in the rest in that direction."""
    var bv = batch_view_over(batch)
    var n_rows = batch.num_rows()
    var order = List[Int]()
    for w in range(nw):
        order.append(nw - 1 - w if reverse_merge else w)
    var acc = _worker[N, D](bv, n_rows, order[0], nw)
    for i in range(1, nw):
        acc.combine(_worker[N, D](bv, n_rows, order[i], nw))
    return _drain(acc)


def _check_all_merges[N: Int, D: Int](batch: RecordBatch, want_pay: List[Int64]) raises:
    """One worker fed forward and backward, and 2 and 4 workers merged in both
    orders, all give `want_pay` (hand-computed) as the payload column."""
    var one = TopNState[N, 0, 1, D]()
    _feed(one, batch)
    _check_payloads(_drain(one), 1, want_pay)
    var bv = batch_view_over(batch)
    var back = TopNState[N, 0, 1, D]()
    for r in range(batch.num_rows() - 1, -1, -1):
        back.feed_row(bv, r)
    _check_payloads(_drain(back), 1, want_pay)
    for nw in [2, 4]:
        _check_payloads(_merged[N, D](batch, nw, False), 1, want_pay)
        _check_payloads(_merged[N, D](batch, nw, True), 1, want_pay)


def test_topn_state_all_null_keys_keep_smallest_payloads() raises:
    # Six rows, every key NULL: N = 2 keeps rows 0 and 1, however fed/merged.
    var keys: List[Int64] = [0, 0, 0, 0, 0, 0]
    var valid: List[Bool] = [False, False, False, False, False, False]
    var batch = _kp_batch(keys, valid)
    var want: List[Int64] = [0, 1]
    _check_all_merges[2, TOPN_DIR_ASC](batch, want)
    _check_all_merges[2, TOPN_DIR_DESC](batch, want)
    var out = _drain_one[2, TOPN_DIR_ASC](batch)
    assert_true(_null(out, 0, 0) and _null(out, 0, 1))


def _drain_one[N: Int, D: Int](batch: RecordBatch) raises -> RecordBatch:
    var st = TopNState[N, 0, 1, D]()
    _feed(st, batch)
    return _drain(st)


def test_topn_state_mixed_null_keys_keep_smallest_payloads() raises:
    # Rows 0..7: NULL 4 NULL NULL 2 NULL 9 NULL. N = 5: the three values then
    # the NULL rows with the smallest payloads, 0 and 2.
    var keys: List[Int64] = [0, 4, 0, 0, 2, 0, 9, 0]
    var valid: List[Bool] = [False, True, False, False, True, False, True, False]
    var batch = _kp_batch(keys, valid)
    var asc_want: List[Int64] = [4, 1, 6, 0, 2]
    _check_all_merges[5, TOPN_DIR_ASC](batch, asc_want)
    var desc_want: List[Int64] = [6, 1, 4, 0, 2]
    _check_all_merges[5, TOPN_DIR_DESC](batch, desc_want)
    # N = 4 leaves room for one NULL row: payload 0.
    var asc4: List[Int64] = [4, 1, 6, 0]
    _check_all_merges[4, TOPN_DIR_ASC](batch, asc4)


def test_topn_state_spill_with_many_null_rows_round_trips() raises:
    # Eight rows: values at rows 2 and 5, NULL keys elsewhere. N = 4. Rows are
    # fed in two halves around a spill, the second half last-row-first, so the
    # later-fed NULL rows have the smaller payloads. Kept: the values then the
    # NULL rows 0 and 1 (rows 2 and 5 hold values).
    var keys: List[Int64] = [0, 0, 7, 0, 0, 3, 0, 0]
    var valid: List[Bool] = [False, False, True, False, False, True, False, False]
    var batch = _kp_batch(keys, valid)
    var bv = batch_view_over(batch)
    var st = TopNState[4, 0, 1, TOPN_DIR_ASC]()
    var storage = LocalDiskSpillStorage.with_unlimited(_scratch_dir() + "/topn_spill_nulls")
    for r in range(4, 8):
        st.feed_row(bv, r)
    _ = st.spill_to_storage(storage)
    for r in range(3, -1, -1):
        st.feed_row(bv, r)
    st.restore_from_storage(storage)
    var out = _drain(st)
    var want: List[Int64] = [5, 2, 0, 1]
    _check_payloads(out, 1, want)
    assert_false(_null(out, 0, 1))
    assert_true(_null(out, 0, 2) and _null(out, 0, 3))
    # Only NULL keys held at the spill: a restore of the image alone.
    var nk: List[Int64] = [0, 0, 0, 0, 0]
    var nv: List[Bool] = [False, False, False, False, False]
    var nbatch = _kp_batch(nk, nv)
    var nbv = batch_view_over(nbatch)
    var only = TopNState[3, 0, 1, TOPN_DIR_DESC]()
    for r in range(4, -1, -1):
        only.feed_row(nbv, r)
    _ = only.spill_to_storage(storage)
    only.restore_from_storage(storage)
    var want_n: List[Int64] = [0, 1, 2]
    _check_payloads(_drain(only), 1, want_n)


def _part_payloads(rb: RecordBatch, part: Int64) raises -> List[Int64]:
    """The payloads of the rows of partition `part`, in output order."""
    var out = List[Int64]()
    for r in range(rb.num_rows()):
        if not _null(rb, 0, r) and _get(rb, 0, r) == part:
            out.append(_get(rb, 2, r))
    return out^


def test_partition_topn_state_null_order_rows_merge_in_any_order() raises:
    # Rows 0..7: partition g = 1 1 1 1 1 1 2 2, order key k = NULL 5 NULL NULL
    # NULL NULL NULL NULL. N = 2 ASC: partition 1 keeps (5, row 1) then the
    # NULL row with the smallest payload (0); partition 2 keeps rows 6 and 7.
    var g: List[Int64] = [1, 1, 1, 1, 1, 1, 2, 2]
    var k: List[Int64] = [0, 5, 0, 0, 0, 0, 0, 0]
    var kvalid: List[Bool] = [False, True, False, False, False, False, False, False]
    var p: List[Int64] = [0, 1, 2, 3, 4, 5, 6, 7]
    var cols = List[Column[HeapRegion]]()
    cols.append(_i64(g, _all(8)))
    cols.append(_i64(k, kvalid))
    cols.append(_i64(p, _all(8)))
    var names: List[String] = ["g", "k", "p"]
    var batch = _batch(names, cols^)
    var bv = batch_view_over(batch)
    var want1: List[Int64] = [1, 0]
    var want2: List[Int64] = [6, 7]
    var one = PartitionTopNState[0, 1, 2, 2, PTOPN_DIR_ASC]()
    for r in range(7, -1, -1):
        one.feed_row(bv, r)
    var one_out = _drain(one)
    _check_payloads_list(_part_payloads(one_out, 1), want1)
    _check_payloads_list(_part_payloads(one_out, 2), want2)
    for nw in [2, 4]:
        for rev in [False, True]:
            var order = List[Int]()
            for w in range(nw):
                order.append(nw - 1 - w if rev else w)
            var acc = PartitionTopNState[0, 1, 2, 2, PTOPN_DIR_ASC]()
            for i in range(nw):
                var wk = PartitionTopNState[0, 1, 2, 2, PTOPN_DIR_ASC]()
                for r in range(8):
                    if r % nw == order[i]:
                        wk.feed_row(bv, r)
                if i == 0:
                    acc = wk^
                else:
                    acc.combine(wk^)
            var out = _drain(acc)
            _check_payloads_list(_part_payloads(out, 1), want1)
            _check_payloads_list(_part_payloads(out, 2), want2)


def _check_payloads_list(got: List[Int64], want: List[Int64]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


# =============================================================================
# LIMIT 0 and the dynamic heap's ties
# =============================================================================


def test_limit_zero_keeps_nothing() raises:
    var sh = BoundedHeapStringPayload[0, 0]()
    _push_str(sh, "b", 0)
    _push_str(sh, "a", 1)
    assert_equal(sh.size(), 0)
    assert_equal(sh.push_returning_evicted("a".as_bytes(), 9), 9)
    assert_false(sh.candidate_beats_root("a".as_bytes(), 9))
    assert_equal(len(_string_heap_payloads(sh)), 0)

    var dh = BoundedHeapInt64PayloadDynamic(0)
    dh.push(5, 0)
    dh.push(1, 1)
    assert_equal(dh.size(), 0)
    assert_equal(len(dh.extract_sorted()), 0)

    var dy = Stage_TopN_Dynamic_1_I64[ColXI64["k"]](
        scaffold=TopNStageScaffoldI64Dynamic.new(0, SORT_DIR_ASC), output_schema=_schema_kp()
    )
    dy.bind(_resolver_k())
    var keys: List[Int64] = [3, 1, 2]
    var cols = List[Column[HeapRegion]]()
    cols.append(_i64(keys, _all(3)))
    var names: List[String] = ["k"]
    var batch = _batch(names, cols^)
    _ = dy.process_batch(batch_view_over(batch))
    var out_opt = dy^.finalize()
    assert_equal(out_opt.take().num_rows(), 0)


def test_dynamic_heap_ties_ignore_arrival_order() raises:
    # Capacity 2, key 7 for payloads 9, 3, 6 and then 1: the smaller payloads
    # win however they arrive.
    var h = BoundedHeapInt64PayloadDynamic(2)
    h.push(7, 9)
    h.push(7, 3)
    h.push(7, 6)
    h.push(7, 1)
    var slots = h.extract_sorted()
    assert_equal(len(slots), 2)
    assert_equal(slots[0].payload_row_id, 1)
    assert_equal(slots[1].payload_row_id, 3)
    # The scaffold, a single slot: the second push has the smaller payload.
    var sc = TopNStageScaffoldI64Dynamic.new(1, SORT_DIR_ASC)
    sc.push_row(4, 5)
    sc.push_row(4, 1)
    var e = sc.finalize_emit()
    assert_equal(len(e), 1)
    assert_equal(e[0].payload_row_id, 1)


def test_dynamic_stage_ties_across_batches_follow_row_order() raises:
    # As the static stage's test: batches [4, 4, 1] and [4, 1, 4], ASC top 3 is
    # rows 2, 4, then the first 4 (row 0), which needs the row index to run on
    # across batches.
    var k0: List[Int64] = [4, 4, 1]
    var k1: List[Int64] = [4, 1, 4]
    var c0 = List[Column[HeapRegion]]()
    c0.append(_i64(k0, _all(3)))
    var c1 = List[Column[HeapRegion]]()
    c1.append(_i64(k1, _all(3)))
    var names: List[String] = ["k"]
    var b0 = _batch(names, c0^)
    var b1 = _batch(names, c1^)
    var st = Stage_TopN_Dynamic_1_I64[ColXI64["k"]](
        scaffold=TopNStageScaffoldI64Dynamic.new(3, SORT_DIR_ASC), output_schema=_schema_kp()
    )
    st.bind(_resolver_k())
    _ = st.process_batch(batch_view_over(b0))
    _ = st.process_batch(batch_view_over(b1))
    var out_opt = st^.finalize()
    var out = out_opt.take()
    var want: List[Int64] = [2, 4, 0]
    _check_payloads(out, 1, want)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
