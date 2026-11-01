# =============================================================================
# test_partition_topn_hash_state_oracle -- PartitionTopNHashState vs a stable
# per-partition sort
# =============================================================================
#
# Every case builds a batch from a seeded generator and computes the expected
# rows without the state: per partition, the rows' position in a stable sort
# by the order key (NULLs last in both directions, ties by input row), and
# the number of rows strictly better. ROW_NUMBER keeps the rows at positions
# below N, RANK those with fewer than N rows strictly better. The state must
# hold, per partition, exactly those rows in exactly that order, however the
# input is fed:
#
#   * one state fed every row;
#   * 2, 3 and 7 states fed consecutive row ranges and merged left to right,
#     right to left, as adjacent pairs in a seeded order (equal to one feed
#     even with ties and NULL keys);
#   * on keys without ties, merged in an arbitrary order (any two states).
#
# The partition order of a drained batch differs between feeds, so rows are
# grouped by partition key (NULL as its own group) before comparing.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_op_sort.sort_stage_payloads import PayloadCol_Typed

from komira_op_window.part_key_block import PartKeyBlock, PartKeyCol_Numeric
from komira_op_window.partition_topn_hash_state import (
    PTN_DIR_ASC,
    PTN_DIR_DESC,
    PTN_ORDER_STRING_SENTINEL,
    PTN_TIES_RANK,
    PTN_TIES_ROW,
    PartitionTopNHashState,
)


comptime I64 = DType.int64
comptime STR = PTN_ORDER_STRING_SENTINEL
comptime KB_I64 = PartKeyBlock[PartKeyCol_Numeric[I64, 0]]
comptime PAY2 = PayloadCol_Typed[I64, 2]


struct _Rows(Movable):
    var pk: List[Int64]
    var pkv: List[Bool]
    var ok: List[Int64]
    var okv: List[Bool]

    def __init__(out self):
        self.pk = List[Int64]()
        self.pkv = List[Bool]()
        self.ok = List[Int64]()
        self.okv = List[Bool]()


def _next(mut s: Int) -> Int:
    s = (s * 1103515245 + 12345) % 2147483648
    return s // 256


def _gen(
    seed: Int, n: Int, parts: Int, vals: Int, null_pk_pct: Int, null_ok_pct: Int
) -> _Rows:
    """`n` rows over partitions `0..parts` and order keys `0..vals`, with the
    given percentage of NULL partition keys and NULL order keys."""
    var s = seed
    var r = _Rows()
    for _ in range(n):
        r.pkv.append(_next(s) % 100 >= null_pk_pct)
        r.pk.append(Int64(_next(s) % parts))
        r.okv.append(_next(s) % 100 >= null_ok_pct)
        r.ok.append(Int64(_next(s) % vals))
    return r^


def _gen_unique(n: Int, parts: Int, null_pk_pct: Int) -> _Rows:
    """Order keys all different (so no ties anywhere), none NULL."""
    var s = 7
    var r = _Rows()
    for i in range(n):
        r.pkv.append(_next(s) % 100 >= null_pk_pct)
        r.pk.append(Int64(_next(s) % parts))
        r.okv.append(True)
        r.ok.append(Int64((i * 37) % 1009))
    return r^


def _col_i64(vals: List[Int64], valid: List[Bool]) -> Column[HeapRegion]:
    var arr = PrimitiveArray[I64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.store[1](i, vals[i])
        if not valid[i]:
            arr._set_null(i)
    return Column.from_primitive[I64](arr)


def _pad4(v: Int64) -> String:
    var t = String(v)
    while t.byte_length() < 4:
        t = String("0") + t
    return t^


def _batch(r: _Rows, string_order: Bool) raises -> RecordBatch:
    """[pk @0, order key @1, payload = input row @2]."""
    var n = len(r.pk)
    var pay = List[Int64]()
    var all_valid = List[Bool]()
    for i in range(n):
        pay.append(Int64(i))
        all_valid.append(True)
    var sb = SchemaBuilder()
    sb.add_field(Field("pk", ArrowType.INT64, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(_col_i64(r.pk, r.pkv))
    if string_order:
        sb.add_field(Field("okey", ArrowType.STRING, True))
        var strs = List[String]()
        for i in range(n):
            strs.append(_pad4(r.ok[i]))
        rbb.add_column(Column.from_string(StringArray.from_strings_with_validity(strs, r.okv)))
    else:
        sb.add_field(Field("okey", ArrowType.INT64, True))
        rbb.add_column(_col_i64(r.ok, r.okv))
    sb.add_field(Field("pay", ArrowType.INT64, False))
    rbb.add_column(_col_i64(pay, all_valid))
    return rbb.build(sb.build())


def _cmp(r: _Rows, j: Int, i: Int, desc: Bool) -> Int:
    """-1 if row j sorts before row i, 1 if after, 0 if they tie."""
    if r.okv[j] and not r.okv[i]:
        return -1
    if not r.okv[j] and r.okv[i]:
        return 1
    if not r.okv[j] and not r.okv[i]:
        return 0
    if r.ok[j] == r.ok[i]:
        return 0
    var lt = r.ok[j] < r.ok[i]
    if desc:
        lt = not lt
    return -1 if lt else 1


def _oracle(r: _Rows, parts: Int, n_keep: Int, desc: Bool, rank: Bool) -> List[List[Int64]]:
    """Per partition code (`parts` is the NULL partition), the kept input
    rows best first, from a stable sort position and a strictly-better count
    for every row."""
    var out = List[List[Int64]]()
    var members = List[List[Int]]()
    for _ in range(parts + 1):
        out.append(List[Int64]())
        members.append(List[Int]())
    for i in range(len(r.pk)):
        var code = Int(r.pk[i]) if r.pkv[i] else parts
        members[code].append(i)
    for c in range(parts + 1):
        var m = members[c].copy()
        var sz = len(m)
        var at_pos = List[Int](length=sz, fill=0)
        var better_at = List[Int](length=sz, fill=0)
        for a in range(sz):
            var better = 0
            var tied_before = 0
            for b in range(sz):
                if b == a:
                    continue
                var rel = _cmp(r, m[b], m[a], desc)
                if rel < 0:
                    better += 1
                elif rel == 0 and b < a:
                    tied_before += 1
            at_pos[better + tied_before] = m[a]
            better_at[better + tied_before] = better
        for pos in range(sz):
            var keep = better_at[pos] < n_keep if rank else pos < n_keep
            if keep:
                out[c].append(Int64(at_pos[pos]))
    return out^


def _by_code(o: Optional[RecordBatch], parts: Int) raises -> List[List[Int64]]:
    var out = List[List[Int64]]()
    for _ in range(parts + 1):
        out.append(List[Int64]())
    if not o:
        return out^
    ref rb = o.value()
    for r in range(rb.num_rows()):
        ref pkc = rb.column_at(0)
        ref pyc = rb.column_at(2)
        var code = parts if pkc.is_null_at(r) else Int(pkc._data.get_typed[Scalar[I64]](pkc._offset + r))
        out[code].append(pyc._data.get_typed[Scalar[I64]](pyc._offset + r))
    return out^


def _assert_same(got: List[List[Int64]], want: List[List[Int64]], label: String) raises:
    assert_equal(len(got), len(want), label + ": partitions")
    for c in range(len(want)):
        assert_equal(len(got[c]), len(want[c]), label + ": rows of partition " + String(c))
        for i in range(len(want[c])):
            assert_equal(got[c][i], want[c][i], label + ": partition " + String(c) + " row " + String(i))


def _feed[
    N: Int, d: Int, t: Int, odt: DType
](b: RecordBatch, lo: Int, hi: Int) raises -> PartitionTopNHashState[KB_I64, 1, odt, N, d, t, PAY2]:
    var bv = batch_view_over(b)
    var st = PartitionTopNHashState[KB_I64, 1, odt, N, d, t, PAY2](KB_I64.make_empty(8))
    for r in range(lo, hi):
        st.feed_row(bv, r)
    return st^


def _merged[
    N: Int, d: Int, t: Int, odt: DType
](b: RecordBatch, workers: Int, strategy: Int, seed: Int) raises -> Optional[RecordBatch]:
    """`workers` states fed consecutive ranges of `b`, merged by `strategy`:
    0 left to right, 1 right to left, 2 adjacent pairs in a seeded order,
    3 any two states in a seeded order."""
    var n = b.num_rows()
    var parts = List[PartitionTopNHashState[KB_I64, 1, odt, N, d, t, PAY2]]()
    for w in range(workers):
        parts.append(_feed[N, d, t, odt](b, n * w // workers, n * (w + 1) // workers))
    var s = seed
    if strategy == 0:
        while len(parts) > 1:
            var right = parts.pop(1)
            parts[0].combine(right^)
    elif strategy == 1:
        while len(parts) > 1:
            var last = parts.pop()
            parts[len(parts) - 1].combine(last^)
    elif strategy == 2:
        while len(parts) > 1:
            var k = _next(s) % (len(parts) - 1)
            var right = parts.pop(k + 1)
            parts[k].combine(right^)
    else:
        while len(parts) > 1:
            var i = _next(s) % len(parts)
            var j = _next(s) % (len(parts) - 1)
            if j >= i:
                j += 1
            var other = parts.pop(j)
            if j < i:
                i -= 1
            parts[i].combine(other^)
    return parts[0].drain_to_record_batch()


def _check[
    N: Int, d: Int, t: Int, odt: DType
](r: _Rows, parts: Int, any_merge_order: Bool, label: String) raises:
    var b = _batch(r, odt == STR)
    var want = _oracle(r, parts, N, d == PTN_DIR_DESC, t == PTN_TIES_RANK)
    var one = _feed[N, d, t, odt](b, 0, b.num_rows())
    _assert_same(_by_code(one.drain_to_record_batch(), parts), want, label + " one feed")
    var workers: List[Int] = [1, 2, 3, 7]
    for wi in range(len(workers)):
        for strategy in range(4 if any_merge_order else 3):
            for seed in range(3):
                _assert_same(
                    _by_code(_merged[N, d, t, odt](b, workers[wi], strategy, seed + 1), parts),
                    want,
                    label + " workers " + String(workers[wi]) + " merge " + String(strategy),
                )


def _check_both_orders[N: Int, t: Int, odt: DType](r: _Rows, parts: Int, any_order: Bool, label: String) raises:
    _check[N, PTN_DIR_ASC, t, odt](r, parts, any_order, label + " asc")
    _check[N, PTN_DIR_DESC, t, odt](r, parts, any_order, label + " desc")


def test_ties_after_slot_reuse_follow_input_order() raises:
    # Three order values over 2 partitions: most rows tie, and rows leaving a
    # heap hand their slots to later rows, so slot numbers run against input
    # order.
    var r = _gen(11, 120, 2, 3, 0, 0)
    _check_both_orders[1, PTN_TIES_ROW, I64](r, 2, False, "row n1")
    _check_both_orders[3, PTN_TIES_ROW, I64](r, 2, False, "row n3")
    _check_both_orders[7, PTN_TIES_ROW, I64](r, 2, False, "row n7")
    _check_both_orders[3, PTN_TIES_ROW, STR](r, 2, False, "row str n3")


def test_rank_keeps_every_tied_row_in_input_order() raises:
    # Two order values in one partition, then a few partitions: the rows tied with the
    # N-th come out in input order.
    var one = _gen(5, 150, 1, 2, 0, 0)
    _check_both_orders[1, PTN_TIES_RANK, I64](one, 1, False, "rank n1")
    _check_both_orders[3, PTN_TIES_RANK, I64](one, 1, False, "rank n3")
    _check_both_orders[3, PTN_TIES_RANK, STR](one, 1, False, "rank str n3")
    var many = _gen(6, 200, 4, 5, 0, 0)
    _check_both_orders[2, PTN_TIES_RANK, I64](many, 4, False, "rank 4 parts n2")
    _check_both_orders[6, PTN_TIES_RANK, I64](many, 4, False, "rank 4 parts n6")


def test_worker_counts_and_merge_orders_agree_on_keys_without_ties() raises:
    # Distinct order keys: the kept rows are fixed by the data, so states
    # merged in any order, including non-adjacent ones, must agree.
    var r = _gen_unique(600, 5, 10)
    _check_both_orders[4, PTN_TIES_ROW, I64](r, 5, True, "unique row")
    _check_both_orders[4, PTN_TIES_RANK, I64](r, 5, True, "unique rank")
    _check_both_orders[4, PTN_TIES_ROW, STR](r, 5, True, "unique str row")


def test_null_partition_and_order_keys() raises:
    # A quarter of the partition keys and of the order keys are NULL.
    var r = _gen(21, 240, 3, 4, 25, 25)
    _check_both_orders[3, PTN_TIES_ROW, I64](r, 3, False, "null row")
    _check_both_orders[3, PTN_TIES_RANK, I64](r, 3, False, "null rank")
    _check_both_orders[3, PTN_TIES_ROW, STR](r, 3, False, "null str row")
    _check_both_orders[3, PTN_TIES_RANK, STR](r, 3, False, "null str rank")
    # NULL order keys in a partition of mostly NULLs: more of them than N.
    var sparse = _gen(22, 200, 2, 6, 10, 80)
    _check_both_orders[2, PTN_TIES_ROW, I64](sparse, 2, False, "sparse null row")
    _check_both_orders[5, PTN_TIES_RANK, I64](sparse, 2, False, "sparse null rank")


def test_limit_zero_one_and_larger_than_the_partition() raises:
    var r = _gen(31, 90, 4, 5, 10, 10)
    # k = 0 keeps nothing and reads nothing out of bounds (feed, merge, drain).
    _check_both_orders[0, PTN_TIES_ROW, I64](r, 4, False, "k0 row")
    _check_both_orders[0, PTN_TIES_RANK, I64](r, 4, False, "k0 rank")
    _check_both_orders[0, PTN_TIES_ROW, STR](r, 4, False, "k0 str row")
    _check_both_orders[0, PTN_TIES_RANK, STR](r, 4, False, "k0 str rank")
    _check_both_orders[1, PTN_TIES_ROW, I64](r, 4, False, "k1 row")
    _check_both_orders[1, PTN_TIES_RANK, I64](r, 4, False, "k1 rank")
    _check_both_orders[1, PTN_TIES_ROW, STR](r, 4, False, "k1 str row")
    # k larger than any partition (about 22 rows): every row is kept.
    _check_both_orders[64, PTN_TIES_ROW, I64](r, 4, False, "big row")
    _check_both_orders[64, PTN_TIES_RANK, I64](r, 4, False, "big rank")
    _check_both_orders[64, PTN_TIES_ROW, STR](r, 4, False, "big str row")


def test_many_partitions_grow_the_directory() raises:
    # 3000 partitions: the directory grows past its initial size several times.
    var r = _gen(41, 9000, 3000, 5, 1, 5)
    _check_both_orders[2, PTN_TIES_ROW, I64](r, 3000, False, "many row")
    _check_both_orders[2, PTN_TIES_RANK, I64](r, 3000, False, "many rank")
    # The same many keys, one row each: nothing may be dropped or merged.
    var single = _Rows()
    for i in range(2500):
        single.pk.append(Int64(i))
        single.pkv.append(True)
        single.ok.append(Int64(i % 7))
        single.okv.append(True)
    _check_both_orders[1, PTN_TIES_ROW, I64](single, 2500, True, "single rows")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
