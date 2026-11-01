# =============================================================================
# test_partition_topn_hash_state_keytypes -- INT32 and FLOAT32 keys, and the
# emitted order key of tied rows
# =============================================================================
#
# Order keys and partition keys of INT32 and FLOAT32 go through their own
# read paths and their own order-preserving map, so each is checked against a
# stable per-partition sort on value pools that hold the extremes: for INT32
# the minimum, the maximum, negatives and zero; for FLOAT32 also -inf, +inf,
# NaN, and -0.0 beside +0.0 (one value, one partition). A pool is listed in
# ascending order, so a value's index is its rank and the oracle compares
# indexes.
#
# Per partition the state must hold exactly the rows the stable sort keeps
# (ROW_NUMBER: the first N positions; RANK: every row with fewer than N rows
# strictly better), best first, with the emitted `order_key` equal to that
# row's own order key, when fed as one state and as three states fed
# consecutive ranges and merged left to right.
#
# The last test asserts the `order_key` column of rows tied with the N-th row
# of a STRING RANK partition.
# =============================================================================

from std.math import inf, isnan, nan
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
comptime I32 = DType.int32
comptime F32 = DType.float32
comptime PAY2 = PayloadCol_Typed[I64, 2]


def _pool[dt: DType]() -> List[Float64]:
    """Ascending distinct values (NaN last for floats), as Float64."""
    var p = List[Float64]()
    comptime if dt == I32:
        p.append(-2147483648.0)
        p.append(-7.0)
        p.append(-1.0)
        p.append(0.0)
        p.append(1.0)
        p.append(9.0)
        p.append(2147483647.0)
    else:
        p.append(-inf[DType.float64]())
        p.append(-3.4028234663852886e38)
        p.append(-1.5)
        p.append(0.0)
        p.append(2.5)
        p.append(3.4028234663852886e38)
        p.append(inf[DType.float64]())
        p.append(nan[DType.float64]())
    return p^


def _value[dt: DType](pool: List[Float64], code: Int, row: Int) -> Scalar[dt]:
    """The pool value of `code`; the zero is -0.0 on odd rows (floats)."""
    if pool[code] == 0.0 and row % 2 == 1:
        return Scalar[DType.float64](-0.0).cast[dt]()
    return Scalar[DType.float64](pool[code]).cast[dt]()


def _code_of(pool: List[Float64], v: Float64) -> Int:
    if isnan(v):
        return len(pool) - 1
    for i in range(len(pool)):
        if pool[i] == v:
            return i
    return -1


def _next(mut s: Int) -> Int:
    s = (s * 1103515245 + 12345) % 2147483648
    return s // 256


struct _Codes(Movable):
    """Per row: partition code and order code, `-1` for NULL."""

    var pk: List[Int]
    var ok: List[Int]

    def __init__(out self):
        self.pk = List[Int]()
        self.ok = List[Int]()


def _gen(seed: Int, n: Int, n_pk: Int, n_ok: Int) -> _Codes:
    var s = seed
    var c = _Codes()
    for _ in range(n):
        c.pk.append(-1 if _next(s) % 100 < 8 else _next(s) % n_pk)
        c.ok.append(-1 if _next(s) % 100 < 10 else _next(s) % n_ok)
    return c^


def _col[dt: DType](vals: List[Scalar[dt]], valid: List[Bool]) -> Column[HeapRegion]:
    var arr = PrimitiveArray[dt].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.store[1](i, vals[i])
        if not valid[i]:
            arr._set_null(i)
    return Column.from_primitive[dt](arr)


def _batch[PD: DType, OD: DType](c: _Codes) raises -> RecordBatch:
    """[pk @0 of PD, order key @1 of OD, payload = input row @2]."""
    var pkp = _pool[PD]()
    var okp = _pool[OD]()
    var pks = List[Scalar[PD]]()
    var pkv = List[Bool]()
    var oks = List[Scalar[OD]]()
    var okv = List[Bool]()
    var pay = List[Scalar[I64]]()
    var all_valid = List[Bool]()
    for i in range(len(c.pk)):
        pkv.append(c.pk[i] >= 0)
        pks.append(_value[PD](pkp, max(c.pk[i], 0), i))
        okv.append(c.ok[i] >= 0)
        oks.append(_value[OD](okp, max(c.ok[i], 0), i))
        pay.append(Scalar[I64](i))
        all_valid.append(True)
    var sb = SchemaBuilder()
    var rbb = RecordBatchBuilder()
    sb.add_field(Field("pk", ArrowType.INT32 if PD == I32 else ArrowType.FLOAT32, True))
    rbb.add_column(_col[PD](pks, pkv))
    sb.add_field(Field("okey", ArrowType.INT32 if OD == I32 else ArrowType.FLOAT32, True))
    rbb.add_column(_col[OD](oks, okv))
    sb.add_field(Field("pay", ArrowType.INT64, False))
    rbb.add_column(_col[I64](pay, all_valid))
    return rbb.build(sb.build())


def _cmp(c: _Codes, j: Int, i: Int, desc: Bool) -> Int:
    """-1 if row j sorts before row i, 1 if after, 0 if they tie (NULL last)."""
    if c.ok[j] >= 0 and c.ok[i] < 0:
        return -1
    if c.ok[j] < 0 and c.ok[i] >= 0:
        return 1
    if c.ok[j] == c.ok[i]:
        return 0
    var lt = c.ok[j] < c.ok[i]
    if desc:
        lt = not lt
    return -1 if lt else 1


def _oracle(c: _Codes, n_pk: Int, n_keep: Int, desc: Bool, rank: Bool) -> List[List[Int]]:
    """Per partition code (`n_pk` is the NULL partition) the kept rows."""
    var out = List[List[Int]]()
    var members = List[List[Int]]()
    for _ in range(n_pk + 1):
        out.append(List[Int]())
        members.append(List[Int]())
    for i in range(len(c.pk)):
        members[c.pk[i] if c.pk[i] >= 0 else n_pk].append(i)
    for p in range(n_pk + 1):
        var m = members[p].copy()
        var sz = len(m)
        var at_pos = List[Int](length=sz, fill=0)
        var better_at = List[Int](length=sz, fill=0)
        for a in range(sz):
            var better = 0
            var tied_before = 0
            for b in range(sz):
                if b == a:
                    continue
                var rel = _cmp(c, m[b], m[a], desc)
                if rel < 0:
                    better += 1
                elif rel == 0 and b < a:
                    tied_before += 1
            at_pos[better + tied_before] = m[a]
            better_at[better + tied_before] = better
        for pos in range(sz):
            if (better_at[pos] < n_keep) if rank else (pos < n_keep):
                out[p].append(at_pos[pos])
    return out^


def _assert_state[
    PD: DType, OD: DType
](o: Optional[RecordBatch], c: _Codes, want: List[List[Int]], label: String) raises:
    var n_pk = len(_pool[PD]())
    var okp = _pool[OD]()
    var pkp = _pool[PD]()
    var got = List[List[Int]]()
    for _ in range(n_pk + 1):
        got.append(List[Int]())
    if o:
        ref rb = o.value()
        ref pkc = rb.column_at(0)
        ref okc = rb.column_at(1)
        ref pyc = rb.column_at(2)
        for r in range(rb.num_rows()):
            var part = n_pk
            if not pkc.is_null_at(r):
                part = _code_of(pkp, Float64(pkc._data.get_typed[Scalar[PD]](pkc._offset + r)))
            var row = Int(pyc._data.get_typed[Scalar[I64]](pyc._offset + r))
            got[part].append(row)
            # The emitted order key is the row's own.
            if c.ok[row] < 0:
                assert_true(okc.is_null_at(r), label + ": NULL order key of row " + String(row))
            else:
                assert_true(not okc.is_null_at(r), label + ": order key present at row " + String(row))
                var ov = Float64(okc._data.get_typed[Scalar[OD]](okc._offset + r))
                assert_equal(_code_of(okp, ov), c.ok[row], label + ": order key of row " + String(row))
            # The emitted partition key is the row's own partition.
            assert_equal(part, c.pk[row] if c.pk[row] >= 0 else n_pk, label + ": partition of row " + String(row))
    for p in range(n_pk + 1):
        assert_equal(len(got[p]), len(want[p]), label + ": rows of partition " + String(p))
        for i in range(len(want[p])):
            assert_equal(got[p][i], want[p][i], label + ": partition " + String(p) + " position " + String(i))


def _fed[
    PD: DType, OD: DType, N: Int, d: Int, t: Int
](
    b: RecordBatch, lo: Int, hi: Int
) raises -> PartitionTopNHashState[PartKeyBlock[PartKeyCol_Numeric[PD, 0]], 1, OD, N, d, t, PAY2]:
    var bv = batch_view_over(b)
    var st = PartitionTopNHashState[PartKeyBlock[PartKeyCol_Numeric[PD, 0]], 1, OD, N, d, t, PAY2](
        PartKeyBlock[PartKeyCol_Numeric[PD, 0]].make_empty(8)
    )
    for r in range(lo, hi):
        st.feed_row(bv, r)
    return st^


def _check[PD: DType, OD: DType, N: Int, d: Int, t: Int](seed: Int, label: String) raises:
    var n_pk = len(_pool[PD]())
    var c = _gen(seed, 160, n_pk, len(_pool[OD]()))
    var b = _batch[PD, OD](c)
    var want = _oracle(c, n_pk, N, d == PTN_DIR_DESC, t == PTN_TIES_RANK)
    var one = _fed[PD, OD, N, d, t](b, 0, 160)
    _assert_state[PD, OD](one.drain_to_record_batch(), c, want, label + " one feed")
    var a = _fed[PD, OD, N, d, t](b, 0, 55)
    var m = _fed[PD, OD, N, d, t](b, 55, 110)
    var z = _fed[PD, OD, N, d, t](b, 110, 160)
    a.combine(m^)
    a.combine(z^)
    _assert_state[PD, OD](a.drain_to_record_batch(), c, want, label + " three ranges merged")


def _check_all[PD: DType, OD: DType](seed: Int, label: String) raises:
    _check[PD, OD, 3, PTN_DIR_ASC, PTN_TIES_ROW](seed, label + " asc row n3")
    _check[PD, OD, 3, PTN_DIR_DESC, PTN_TIES_ROW](seed, label + " desc row n3")
    _check[PD, OD, 3, PTN_DIR_ASC, PTN_TIES_RANK](seed, label + " asc rank n3")
    _check[PD, OD, 3, PTN_DIR_DESC, PTN_TIES_RANK](seed, label + " desc rank n3")
    _check[PD, OD, 64, PTN_DIR_ASC, PTN_TIES_ROW](seed, label + " asc row n64")
    _check[PD, OD, 64, PTN_DIR_DESC, PTN_TIES_RANK](seed, label + " desc rank n64")


def test_int32_order_and_partition_keys() raises:
    _check_all[I32, I32](3, "i32 pk i32 ok")


def test_float32_order_and_partition_keys() raises:
    _check_all[F32, F32](4, "f32 pk f32 ok")


def test_int32_partition_float32_order() raises:
    _check_all[I32, F32](5, "i32 pk f32 ok")


def test_float32_partition_int32_order() raises:
    _check_all[F32, I32](6, "f32 pk i32 ok")


def test_string_rank_tied_rows_emit_their_order_key() raises:
    # One partition, RANK <= 2, ASC, keys b a c b b c: a is rank 1, the three
    # b rows share rank 2 (one fills the heap, two are tied with its root),
    # c is rank 5 and out. Each tied b row comes out with order key "b".
    var keys: List[String] = ["b", "a", "c", "b", "b", "c"]
    var n = len(keys)
    var pk = List[Int64]()
    var pay = List[Int64]()
    var all_valid = List[Bool]()
    for i in range(n):
        pk.append(Int64(7))
        pay.append(Int64(i))
        all_valid.append(True)
    var sb = SchemaBuilder()
    var rbb = RecordBatchBuilder()
    sb.add_field(Field("pk", ArrowType.INT64, True))
    rbb.add_column(_col[I64](pk, all_valid))
    sb.add_field(Field("okey", ArrowType.STRING, True))
    rbb.add_column(Column.from_string(StringArray.from_strings(keys)))
    sb.add_field(Field("pay", ArrowType.INT64, False))
    rbb.add_column(_col[I64](pay, all_valid))
    var b = rbb.build(sb.build())
    var bv = batch_view_over(b)
    var st = PartitionTopNHashState[
        PartKeyBlock[PartKeyCol_Numeric[I64, 0]], 1, PTN_ORDER_STRING_SENTINEL, 2, PTN_DIR_ASC, PTN_TIES_RANK, PAY2
    ](PartKeyBlock[PartKeyCol_Numeric[I64, 0]].make_empty(4))
    for r in range(n):
        st.feed_row(bv, r)
    var drained = st.drain_to_record_batch()
    var out = drained.take()
    var want_pay: List[Int] = [1, 0, 3, 4]
    var want_key: List[String] = ["a", "b", "b", "b"]
    assert_equal(out.num_rows(), 4)
    ref pyc = out.column_at(2)
    var okc = out.column_at(1).as_string()
    for i in range(4):
        assert_equal(Int(pyc._data.get_typed[Scalar[I64]](pyc._offset + i)), want_pay[i], "payload " + String(i))
        assert_equal(okc.get(i), want_key[i], "order key " + String(i))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
