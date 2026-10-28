# =============================================================================
# SortBuffer spill and restore keep input order, checked against a naive stable
# sort of the same rows
# =============================================================================
#
# Rows are generated from small key domains (heavy ties), cut into three
# batches, and fed through `feed_row`. A plan says after which batches the
# buffer spills; the buffer is restored once at the end and drained through
# `drain_to_record_batch`. Every drained column is compared, row by row, with
# the expected column from a stable insertion sort of the generated rows (the
# row id is payload 0, so tie order is visible).
#
# Plans: no spill; spill after the last batch; spill after batch 0 then feed
# more; spill, feed, spill, feed; three spills. Four configurations cover
# the drain paths and the column types:
#   A  keys (INT64, FLOAT64); payloads INT64 id, INT32, STRING, FLOAT32, UINT8
#      (vectorized drain, narrow, f32, u8 and STRING payload emit)
#   B  keys (INT16, STRING); payloads INT64 id, UINT32   (merge-sort drain)
#   C  keys (FLOAT32 with NaN and infinities, UINT64); INT64 id, UINT32
#      (merge-sort drain)
#   D  keys (STRING, INT32); payloads INT64 id, UINT32   (vectorized drain)
# =============================================================================

from std.ffi import external_call
from std.math import inf, nan
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_engine_runtime.spill.local_disk import LocalDiskSpillStorage
from komira_libc.posix import _read_env
from komira_op_sort.sort_stage_buffer import SortBuffer, SortKeyBlock
from komira_op_sort.sort_stage_buffer import SortKeyBlockTrait
from komira_op_sort.sort_stage_columns import (
    SORT_DIR_ASC_U8,
    SORT_DIR_DESC_U8,
    SortKeyColumn_Typed,
)
from komira_op_sort.sort_stage_payloads import (
    PayloadColumn,
    PayloadCol_String,
    PayloadCol_Typed,
)
from komira_op_sort.sort_stage_string_key import SortKeyColumn_String


# -----------------------------------------------------------------------------
# Scratch directory, deterministic generator
# -----------------------------------------------------------------------------


def _root(tag: String) raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var pid = external_call["getpid", Int32]()
    return d + String("/spill-order-") + String(Int(pid)) + String("-") + tag


struct _Rng:
    var state: UInt64

    def __init__(out self, seed: Int):
        self.state = UInt64(seed) * UInt64(2654435761) + UInt64(88172645463325252)

    def below(mut self, m: Int) -> Int:
        self.state = self.state * UInt64(6364136223846793005) + UInt64(
            1442695040888963407
        )
        return Int((self.state >> UInt64(33)) % UInt64(m))


# -----------------------------------------------------------------------------
# Generic oracle: key domains are listed in ascending order, so a row is its
# domain indices; the expected row order is a stable insertion sort of them.
# -----------------------------------------------------------------------------


def _gen_idx(mut rng: _Rng, n: Int, domain: Int) -> List[Int]:
    var out = List[Int](capacity=n)
    for _ in range(n):
        out.append(rng.below(domain))
    return out^


def _expected_ids(
    k0: List[Int], k1: List[Int], desc0: Bool, desc1: Bool
) -> List[Int]:
    var ids = List[Int]()
    for i in range(len(k0)):
        # Insert row i after every row that does not sort strictly after it.
        var pos = len(ids)
        while pos > 0:
            var j = ids[pos - 1]
            var c = _cmp(k0[i], k0[j], desc0)
            if c == 0:
                c = _cmp(k1[i], k1[j], desc1)
            if c < 0:
                pos -= 1
            else:
                break
        ids.insert(pos, i)
    return ids^


def _cmp(a: Int, b: Int, desc: Bool) -> Int:
    var c = 0
    if a < b:
        c = -1
    elif a > b:
        c = 1
    return -c if desc else c


# Batch cuts: three non-empty parts of n rows.
def _cuts(mut rng: _Rng, n: Int) -> List[Int]:
    var c1 = 1 + rng.below(n - 2)
    var c2 = c1 + 1 + rng.below(n - c1 - 1)
    return [0, c1, c2, n]


# Plans: whether to spill after batch 0, 1, 2.
def _plans() -> List[List[Bool]]:
    return [
        [False, False, False],
        [False, False, True],
        [True, False, False],
        [True, True, False],
        [True, True, True],
    ]


# -----------------------------------------------------------------------------
# Typed column helpers
# -----------------------------------------------------------------------------


def _pcol[dt: DType](var v: List[Scalar[dt]]) -> Column[]:
    return Column.from_primitive[dt](PrimitiveArray[dt].from_list(v^))


def _scol(v: List[String]) raises -> Column[]:
    return Column.from_string(StringArray.from_strings(v))


def _same[dt: DType](got: Scalar[dt], want: Scalar[dt]) -> Bool:
    comptime if dt.is_floating_point():
        if got != got:
            return want != want
    return got == want


def _expect[
    dt: DType
](bv: BatchView[_], col: Int, pos: Int, want: Scalar[dt], what: String) raises:
    var got = bv.col_scalar_nonraising[dt](col, pos)
    assert_true(
        _same[dt](got, want),
        what + " differs at sorted position " + String(pos),
    )


def _expect_str(
    bv: BatchView[_], col: Int, pos: Int, want: String, what: String
) raises:
    assert_equal(
        bv.col_str(col).get(pos).to_string(),
        want,
        what + " differs at sorted position " + String(pos),
    )


def _feed[
    KB: SortKeyBlockTrait, *Ps: PayloadColumn
](mut buf: SortBuffer[KB, *Ps], batch: RecordBatch) raises:
    var bv = BatchView(batch)
    for r in range(bv.n_rows()):
        buf.feed_row[origin_of(batch)](bv, r)


def _drive[
    KB: SortKeyBlockTrait, *Ps: PayloadColumn
](
    mut buf: SortBuffer[KB, *Ps],
    batches: List[RecordBatch],
    spill_after: List[Bool],
    mut storage: LocalDiskSpillStorage,
) raises:
    """Feed the batches in order, spilling after those the plan names, then
    restore once."""
    var spills = 0
    for i in range(len(batches)):
        _feed(buf, batches[i])
        if spill_after[i]:
            _ = buf.spill_to_storage(storage)
            spills += 1
    assert_equal(len(buf.spilled_chunk_ids()), spills, "chunks outstanding")
    if spills > 0:
        buf.restore_from_storage(storage)
    assert_equal(len(buf.spilled_chunk_ids()), 0, "chunks after restore")
    assert_equal(storage.num_live_chunks(), 0, "live chunks after restore")


def _dir(d: Bool) -> UInt8:
    return SORT_DIR_DESC_U8 if d else SORT_DIR_ASC_U8


# =============================================================================
# Config A
# =============================================================================

comptime _A_K0 = SortKeyColumn_Typed[DType.int64, 0]
comptime _A_K1 = SortKeyColumn_Typed[DType.float64, 1]
comptime _A_KB = SortKeyBlock[_A_K0, _A_K1]
comptime _A_P0 = PayloadCol_Typed[DType.int64, 2]
comptime _A_P1 = PayloadCol_Typed[DType.int32, 3]
comptime _A_P2 = PayloadCol_String[4]
comptime _A_P3 = PayloadCol_Typed[DType.float32, 5]
comptime _A_P4 = PayloadCol_Typed[DType.uint8, 6]
comptime _ABuf = SortBuffer[_A_KB, _A_P0, _A_P1, _A_P2, _A_P3, _A_P4]


def _a_k0(i: Int) -> Int64:
    var d: List[Int64] = [-5, 0, 3, 7]
    return d[i]


def _a_k1(i: Int) -> Float64:
    var d: List[Float64] = [-2.5, 0.0, 1.5, inf[DType.float64]()]
    return d[i]


def _a_batch(
    k0: List[Int], k1: List[Int], lo: Int, hi: Int
) raises -> RecordBatch:
    var c0 = List[Int64]()
    var c1 = List[Float64]()
    var id = List[Int64]()
    var p32 = List[Int32]()
    var ps = List[String]()
    var pf = List[Float32]()
    var pu = List[UInt8]()
    for r in range(lo, hi):
        c0.append(_a_k0(k0[r]))
        c1.append(_a_k1(k1[r]))
        id.append(Int64(r))
        p32.append(Int32(r * 3 - 100))
        ps.append(String("row-") + String(r))
        pf.append(Float32(r) * Float32(0.5))
        pu.append(UInt8(r % 251))
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", DType.int64, True))
    sb.add_field(Field("k1", DType.float64, True))
    sb.add_field(Field("id", DType.int64, True))
    sb.add_field(Field("p32", DType.int32, True))
    sb.add_field(Field("ps", ArrowType.STRING, True))
    sb.add_field(Field("pf", DType.float32, True))
    sb.add_field(Field("pu", DType.uint8, True))
    var rbb = RecordBatchBuilder.with_capacity(7)
    rbb.add_column(_pcol[DType.int64](c0^))
    rbb.add_column(_pcol[DType.float64](c1^))
    rbb.add_column(_pcol[DType.int64](id^))
    rbb.add_column(_pcol[DType.int32](p32^))
    rbb.add_column(_scol(ps))
    rbb.add_column(_pcol[DType.float32](pf^))
    rbb.add_column(_pcol[DType.uint8](pu^))
    return rbb.build(sb.build())


def _a_check(
    got: RecordBatch, k0: List[Int], k1: List[Int], ids: List[Int]
) raises:
    var bv = BatchView(got)
    assert_equal(bv.n_rows(), len(ids), "A row count")
    for pos in range(len(ids)):
        var r = ids[pos]
        _expect[DType.int64](bv, 0, pos, _a_k0(k0[r]), "A k0")
        _expect[DType.float64](bv, 1, pos, _a_k1(k1[r]), "A k1")
        _expect[DType.int64](bv, 2, pos, Int64(r), "A id")
        _expect[DType.int32](bv, 3, pos, Int32(r * 3 - 100), "A p32")
        _expect_str(bv, 4, pos, String("row-") + String(r), "A ps")
        _expect[DType.float32](bv, 5, pos, Float32(r) * Float32(0.5), "A pf")
        _expect[DType.uint8](bv, 6, pos, UInt8(r % 251), "A pu")


def test_spill_order_config_a() raises:
    var storage = LocalDiskSpillStorage.with_unlimited(_root("a"))
    for seed in range(3):
        for n in [3, 7, 64]:
            var rng = _Rng(seed * 101 + n)
            var k0 = _gen_idx(rng, n, 4)
            var k1 = _gen_idx(rng, n, 4)
            var d0 = rng.below(2) == 1
            var d1 = rng.below(2) == 1
            var cuts = _cuts(rng, n)
            var batches = List[RecordBatch]()
            for b in range(3):
                batches.append(_a_batch(k0, k1, cuts[b], cuts[b + 1]))
            var want = _expected_ids(k0, k1, d0, d1)
            for plan in _plans():
                var buf = _ABuf.make_empty(8)
                buf.set_direction(0, _dir(d0))
                buf.set_direction(1, _dir(d1))
                _drive(buf, batches, plan, storage)
                var out = buf.drain_to_record_batch()
                _a_check(out.take(), k0, k1, want)
    storage.cleanup()


# =============================================================================
# Config B
# =============================================================================

comptime _B_K0 = SortKeyColumn_Typed[DType.int16, 0]
comptime _B_K1 = SortKeyColumn_String[1]
comptime _B_KB = SortKeyBlock[_B_K0, _B_K1]
comptime _B_P0 = PayloadCol_Typed[DType.int64, 2]
comptime _B_P1 = PayloadCol_Typed[DType.uint32, 3]
comptime _BBuf = SortBuffer[_B_KB, _B_P0, _B_P1]


def _str_dom(i: Int) -> String:
    var d: List[String] = ["", "Z", "a", "ab", "abc"]
    return d[i]


def _b_k0(i: Int) -> Int16:
    var d: List[Int16] = [-300, -1, 0, 32000]
    return d[i]


def _b_batch(
    k0: List[Int], k1: List[Int], lo: Int, hi: Int
) raises -> RecordBatch:
    var c0 = List[Int16]()
    var c1 = List[String]()
    var id = List[Int64]()
    var pu = List[UInt32]()
    for r in range(lo, hi):
        c0.append(_b_k0(k0[r]))
        c1.append(_str_dom(k1[r]))
        id.append(Int64(r))
        pu.append(UInt32(r * 7 + 1))
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", DType.int16, True))
    sb.add_field(Field("k1", ArrowType.STRING, True))
    sb.add_field(Field("id", DType.int64, True))
    sb.add_field(Field("pu", DType.uint32, True))
    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(_pcol[DType.int16](c0^))
    rbb.add_column(_scol(c1))
    rbb.add_column(_pcol[DType.int64](id^))
    rbb.add_column(_pcol[DType.uint32](pu^))
    return rbb.build(sb.build())


def _b_check(
    got: RecordBatch, k0: List[Int], k1: List[Int], ids: List[Int]
) raises:
    var bv = BatchView(got)
    assert_equal(bv.n_rows(), len(ids), "B row count")
    for pos in range(len(ids)):
        var r = ids[pos]
        _expect[DType.int16](bv, 0, pos, _b_k0(k0[r]), "B k0")
        _expect_str(bv, 1, pos, _str_dom(k1[r]), "B k1")
        _expect[DType.int64](bv, 2, pos, Int64(r), "B id")
        _expect[DType.uint32](bv, 3, pos, UInt32(r * 7 + 1), "B pu")


def test_spill_order_config_b() raises:
    var storage = LocalDiskSpillStorage.with_unlimited(_root("b"))
    for seed in range(3):
        for n in [3, 7, 64]:
            var rng = _Rng(seed * 103 + n)
            var k0 = _gen_idx(rng, n, 4)
            var k1 = _gen_idx(rng, n, 5)
            var d0 = rng.below(2) == 1
            var d1 = rng.below(2) == 1
            var cuts = _cuts(rng, n)
            var batches = List[RecordBatch]()
            for b in range(3):
                batches.append(_b_batch(k0, k1, cuts[b], cuts[b + 1]))
            var want = _expected_ids(k0, k1, d0, d1)
            for plan in _plans():
                var buf = _BBuf.make_empty(8)
                buf.set_direction(0, _dir(d0))
                buf.set_direction(1, _dir(d1))
                _drive(buf, batches, plan, storage)
                var out = buf.drain_to_record_batch()
                _b_check(out.take(), k0, k1, want)
    storage.cleanup()


# =============================================================================
# Config C: FLOAT32 key with -inf, +inf and NaN (NaN sorts above +inf)
# =============================================================================

comptime _C_K0 = SortKeyColumn_Typed[DType.float32, 0]
comptime _C_K1 = SortKeyColumn_Typed[DType.uint64, 1]
comptime _C_KB = SortKeyBlock[_C_K0, _C_K1]
comptime _C_P0 = PayloadCol_Typed[DType.int64, 2]
comptime _C_P1 = PayloadCol_Typed[DType.uint32, 3]
comptime _CBuf = SortBuffer[_C_KB, _C_P0, _C_P1]


def _c_k0(i: Int) -> Float32:
    var d: List[Float32] = [
        -inf[DType.float32](),
        -1.5,
        0.0,
        2.5,
        inf[DType.float32](),
        nan[DType.float32](),
    ]
    return d[i]


def _c_k1(i: Int) -> UInt64:
    var d: List[UInt64] = [0, 5, UInt64(1) << UInt64(63)]
    return d[i]


def _c_batch(
    k0: List[Int], k1: List[Int], lo: Int, hi: Int
) raises -> RecordBatch:
    var c0 = List[Float32]()
    var c1 = List[UInt64]()
    var id = List[Int64]()
    var pu = List[UInt32]()
    for r in range(lo, hi):
        c0.append(_c_k0(k0[r]))
        c1.append(_c_k1(k1[r]))
        id.append(Int64(r))
        pu.append(UInt32(r * 7 + 1))
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", DType.float32, True))
    sb.add_field(Field("k1", DType.uint64, True))
    sb.add_field(Field("id", DType.int64, True))
    sb.add_field(Field("pu", DType.uint32, True))
    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(_pcol[DType.float32](c0^))
    rbb.add_column(_pcol[DType.uint64](c1^))
    rbb.add_column(_pcol[DType.int64](id^))
    rbb.add_column(_pcol[DType.uint32](pu^))
    return rbb.build(sb.build())


def _c_check(
    got: RecordBatch, k0: List[Int], k1: List[Int], ids: List[Int]
) raises:
    var bv = BatchView(got)
    assert_equal(bv.n_rows(), len(ids), "C row count")
    for pos in range(len(ids)):
        var r = ids[pos]
        _expect[DType.float32](bv, 0, pos, _c_k0(k0[r]), "C k0")
        _expect[DType.uint64](bv, 1, pos, _c_k1(k1[r]), "C k1")
        _expect[DType.int64](bv, 2, pos, Int64(r), "C id")
        _expect[DType.uint32](bv, 3, pos, UInt32(r * 7 + 1), "C pu")


def test_spill_order_config_c() raises:
    var storage = LocalDiskSpillStorage.with_unlimited(_root("c"))
    for seed in range(3):
        for n in [3, 7, 64]:
            var rng = _Rng(seed * 107 + n)
            var k0 = _gen_idx(rng, n, 6)
            var k1 = _gen_idx(rng, n, 3)
            var d0 = rng.below(2) == 1
            var d1 = rng.below(2) == 1
            var cuts = _cuts(rng, n)
            var batches = List[RecordBatch]()
            for b in range(3):
                batches.append(_c_batch(k0, k1, cuts[b], cuts[b + 1]))
            var want = _expected_ids(k0, k1, d0, d1)
            for plan in _plans():
                var buf = _CBuf.make_empty(8)
                buf.set_direction(0, _dir(d0))
                buf.set_direction(1, _dir(d1))
                _drive(buf, batches, plan, storage)
                var out = buf.drain_to_record_batch()
                _c_check(out.take(), k0, k1, want)
    storage.cleanup()


# =============================================================================
# Config D
# =============================================================================

comptime _D_K0 = SortKeyColumn_String[0]
comptime _D_K1 = SortKeyColumn_Typed[DType.int32, 1]
comptime _D_KB = SortKeyBlock[_D_K0, _D_K1]
comptime _D_P0 = PayloadCol_Typed[DType.int64, 2]
comptime _D_P1 = PayloadCol_Typed[DType.uint32, 3]
comptime _DBuf = SortBuffer[_D_KB, _D_P0, _D_P1]


def _d_k1(i: Int) -> Int32:
    var d: List[Int32] = [-7, 0, 9]
    return d[i]


def _d_batch(
    k0: List[Int], k1: List[Int], lo: Int, hi: Int
) raises -> RecordBatch:
    var c0 = List[String]()
    var c1 = List[Int32]()
    var id = List[Int64]()
    var pu = List[UInt32]()
    for r in range(lo, hi):
        c0.append(_str_dom(k0[r]))
        c1.append(_d_k1(k1[r]))
        id.append(Int64(r))
        pu.append(UInt32(r * 7 + 1))
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", ArrowType.STRING, True))
    sb.add_field(Field("k1", DType.int32, True))
    sb.add_field(Field("id", DType.int64, True))
    sb.add_field(Field("pu", DType.uint32, True))
    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(_scol(c0))
    rbb.add_column(_pcol[DType.int32](c1^))
    rbb.add_column(_pcol[DType.int64](id^))
    rbb.add_column(_pcol[DType.uint32](pu^))
    return rbb.build(sb.build())


def _d_check(
    got: RecordBatch, k0: List[Int], k1: List[Int], ids: List[Int]
) raises:
    var bv = BatchView(got)
    assert_equal(bv.n_rows(), len(ids), "D row count")
    for pos in range(len(ids)):
        var r = ids[pos]
        _expect_str(bv, 0, pos, _str_dom(k0[r]), "D k0")
        _expect[DType.int32](bv, 1, pos, _d_k1(k1[r]), "D k1")
        _expect[DType.int64](bv, 2, pos, Int64(r), "D id")
        _expect[DType.uint32](bv, 3, pos, UInt32(r * 7 + 1), "D pu")


def test_spill_order_config_d() raises:
    var storage = LocalDiskSpillStorage.with_unlimited(_root("d"))
    for seed in range(3):
        for n in [3, 7, 64]:
            var rng = _Rng(seed * 109 + n)
            var k0 = _gen_idx(rng, n, 5)
            var k1 = _gen_idx(rng, n, 3)
            var d0 = rng.below(2) == 1
            var d1 = rng.below(2) == 1
            var cuts = _cuts(rng, n)
            var batches = List[RecordBatch]()
            for b in range(3):
                batches.append(_d_batch(k0, k1, cuts[b], cuts[b + 1]))
            var want = _expected_ids(k0, k1, d0, d1)
            for plan in _plans():
                var buf = _DBuf.make_empty(8)
                buf.set_direction(0, _dir(d0))
                buf.set_direction(1, _dir(d1))
                _drive(buf, batches, plan, storage)
                var out = buf.drain_to_record_batch()
                _d_check(out.take(), k0, k1, want)
    storage.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
