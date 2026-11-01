# test_hash_agg_consume_band.mojo — HashAggTable.consume_band.
#
# `consume_band` folds a decoded band (dictionary STRING key codes over a
# borrowed dictionary, a flat Float64 aggregand) into the same key block and
# states `feed_row` uses. Pinned here: it equals a `feed_row` fold of the same
# rows as a RecordBatch (groups, first-seen order, sums), honors the band's
# selection mask, folds a numeric key band like a numeric RecordBatch, and
# reads the CURRENT bytes of a scratch arena that is overwritten between two
# folds (a group stores its key bytes, not a view into the scratch).

from std.collections import List
from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.band_view import BandView
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from komira_agg.hash_agg_op_dt import CountOp, HashAggOpAgg, SumOp
from komira_op_agg_distinct.distinct_key_column import DistinctKeyColumn_Typed
from komira_op_agg_distinct.distinct_key_column_string import (
    DistinctKeyColumn_String,
)

from komira_op_agg_stage.agg_column import AggBlock, AggSlot
from komira_op_agg_stage.hash_agg import HashAggTable
from komira_op_agg_stage.key_block import AggKeyBlock

comptime F64 = DType.float64
comptime _Sum = AggSlot[HashAggOpAgg[SumOp[F64], 1]]
comptime _Cnt = AggSlot[HashAggOpAgg[CountOp[F64], 1]]
comptime _StrT = HashAggTable[AggKeyBlock[DistinctKeyColumn_String[0]], _Sum, _Cnt]
comptime _NumT = HashAggTable[
    AggKeyBlock[DistinctKeyColumn_Typed[DType.int64, 0]], _Sum, _Cnt
]

comptime _N = 12
comptime _DICT = 3  # "apple", "kiwi", "banana"
comptime _CODES = 0
comptime _DOFF = _CODES + _N * 4
comptime _DBYTES = _DOFF + (_DICT + 1) * 4
comptime _DLEN = 15  # 5 + 4 + 6
comptime _AGG = _DBYTES + 16
comptime _MASK = _AGG + _N * 8
comptime _TOTAL = _MASK + 8


def _li(*vals: Int64) -> List[Int64]:
    var out = List[Int64](capacity=len(vals))
    for i in range(len(vals)):
        out.append(vals[i])
    return out^


def _lb(*vals: Bool) -> List[Bool]:
    var out = List[Bool](capacity=len(vals))
    for i in range(len(vals)):
        out.append(vals[i])
    return out^


def _lf(*vals: Float64) -> List[Float64]:
    var out = List[Float64](capacity=len(vals))
    for i in range(len(vals)):
        out.append(vals[i])
    return out^


def _ls(*vals: StaticString) -> List[String]:
    var out = List[String](capacity=len(vals))
    for i in range(len(vals)):
        out.append(String(vals[i]))
    return out^


def _dict_words() -> List[String]:
    return _ls("apple", "kiwi", "banana")


def _code(r: Int) -> Int:
    return (r * 5 + 1) % _DICT


def _val(r: Int) -> Float64:
    return Float64(r) * 1.5 + 0.25


def _live(r: Int) -> Bool:
    return r % 4 != 2


def _fill(mut arena: OwnedAlignedBuffer, with_mask: Bool) raises:
    var words = _dict_words()
    var wc = arena.view_range_mut(_CODES, _N * 4)
    for r in range(_N):
        wc.set_typed[Int32](r, Int32(_code(r)))
    var wo = arena.view_range_mut(_DOFF, (_DICT + 1) * 4)
    var wb = arena.view_range_mut(_DBYTES, 16)
    var off = 0
    for d in range(_DICT):
        wo.set_typed[Int32](d, Int32(off))
        var b = words[d].as_bytes()
        for i in range(len(b)):
            wb.write_u8_at(off + i, b[i])
        off += len(b)
    wo.set_typed[Int32](_DICT, Int32(off))
    var wa = arena.view_range_mut(_AGG, _N * 8)
    for r in range(_N):
        wa.set_typed[Float64](r, _val(r))
    var wm = arena.view_range_mut(_MASK, 8)
    for i in range(8):
        wm.write_u8_at(i, 0)
    for r in range(_N):
        if (not with_mask) or _live(r):
            var cur = wm.read_u8_at(r >> 3)
            wm.write_u8_at(r >> 3, cur | (UInt8(1) << UInt8(r & 7)))


def _fold_band[o: Origin[mut=False]](
    mut t: _StrT, ref [o] arena: OwnedAlignedBuffer, with_mask: Bool
) raises:
    var band = BandView[o](_N, 2)
    band.push_dict_string_col(
        arena.view_range_ro(_CODES, _N * 4),
        arena.view_range_ro(_DOFF, (_DICT + 1) * 4),
        arena.view_range_ro(_DBYTES, _DLEN),
    )
    band.push_flat_col(arena.view_range_ro(_AGG, _N * 8))
    if with_mask:
        band.set_selection_mask(arena.view_range_ro(_MASK, 8))
    t.consume_band(band)


def _batch_of_band(with_mask: Bool) raises -> RecordBatch:
    var words = _dict_words()
    var keys = List[String]()
    var vals = List[Float64]()
    for r in range(_N):
        if (not with_mask) or _live(r):
            keys.append(words[_code(r)])
            vals.append(_val(r))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_string(StringArray.from_strings(keys)))
    rb.add_column(Column.from_primitive[F64](PrimitiveArray[F64].from_list(vals)))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, False))
    sb.add_field(Field("v", ArrowType.FLOAT64, False))
    return rb.build(sb.build())


def _same_drain(mut a: _StrT, mut b: _StrT) raises:
    var ra = a.drain_to_record_batch()
    var rb = b.drain_to_record_batch()
    ref x = ra.value()
    ref y = rb.value()
    assert_equal(x.num_rows(), y.num_rows(), "group count")
    var xs = x.column_at(1).as_primitive[F64]()
    var ys = y.column_at(1).as_primitive[F64]()
    var xc = x.column_at(2).as_primitive[DType.int64]()
    var yc = y.column_at(2).as_primitive[DType.int64]()
    for r in range(x.num_rows()):
        assert_equal(
            x.column_at(0).as_string().get(r), y.column_at(0).as_string().get(r), "key"
        )
        assert_equal(xs.get(r), ys.get(r), "sum (same order, same bits)")
        assert_equal(xc.get(r), yc.get(r), "count")


def _check_band_equals_rows(with_mask: Bool) raises:
    var arena = OwnedAlignedBuffer(_TOTAL)
    _fill(arena, with_mask)
    var banded = _StrT(AggBlock[_Sum, _Cnt](_Sum(), _Cnt()))
    _fold_band(banded, arena, with_mask)
    var batch = _batch_of_band(with_mask)
    var bv = BatchView(batch)
    var rowed = _StrT(AggBlock[_Sum, _Cnt](_Sum(), _Cnt()))
    for r in range(bv.n_rows()):
        rowed.feed_row(bv, r)
    _same_drain(banded, rowed)


def test_band_fold_equals_row_fold() raises:
    _check_band_equals_rows(False)


def test_band_fold_honors_the_selection_mask() raises:
    _check_band_equals_rows(True)


def _fold_num[o: Origin[mut=False]](
    mut t: _NumT, ref [o] arena: OwnedAlignedBuffer, n: Int
) raises:
    var band = BandView[o](n, 2)
    band.push_flat_col(arena.view_range_ro(0, n * 8))
    band.push_flat_col(arena.view_range_ro(n * 8, n * 8))
    t.consume_band(band)


def test_numeric_key_band_equals_row_fold() raises:
    var n = 10
    var arena = OwnedAlignedBuffer(n * 16)
    var wk = arena.view_range_mut(0, n * 8)
    var wv = arena.view_range_mut(n * 8, n * 8)
    var keys = List[Int64]()
    var vals = List[Float64]()
    for r in range(n):
        keys.append(Int64(r % 3 - 1))
        vals.append(Float64(r) + 0.5)
        wk.set_typed[Int64](r, keys[r])
        wv.set_typed[Float64](r, vals[r])
    var banded = _NumT(AggBlock[_Sum, _Cnt](_Sum(), _Cnt()))
    _fold_num(banded, arena, n)
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(keys)))
    rb.add_column(Column.from_primitive[F64](PrimitiveArray[F64].from_list(vals)))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.FLOAT64, False))
    var batch = rb.build(sb.build())
    var bv = BatchView(batch)
    var rowed = _NumT(AggBlock[_Sum, _Cnt](_Sum(), _Cnt()))
    for r in range(n):
        rowed.feed_row(bv, r)
    var ra = banded.drain_to_record_batch()
    var rr = rowed.drain_to_record_batch()
    assert_equal(ra.value().num_rows(), 3, "keys -1, 0, 1")
    for r in range(3):
        assert_equal(
            ra.value().column_at(0).as_primitive[DType.int64]().get(r),
            rr.value().column_at(0).as_primitive[DType.int64]().get(r),
            "key",
        )
        assert_equal(
            ra.value().column_at(1).as_primitive[F64]().get(r),
            rr.value().column_at(1).as_primitive[F64]().get(r),
            "sum",
        )


def test_reused_scratch_folds_the_current_bytes() raises:
    # Fold a band, overwrite the arena with different dictionary words, fold
    # again: the first fold's groups keep their own key bytes.
    var arena = OwnedAlignedBuffer(_TOTAL)
    _fill(arena, False)
    var t = _StrT(AggBlock[_Sum, _Cnt](_Sum(), _Cnt()))
    _fold_band(t, arena, False)
    assert_equal(t.size(), 3, "apple, kiwi, banana")
    var wb = arena.view_range_mut(_DBYTES, 16)
    var upper = String("APPLEKIWIBANANA")
    var other = upper.as_bytes()
    for i in range(_DLEN):
        wb.write_u8_at(i, other[i])
    _fold_band(t, arena, False)
    assert_equal(t.size(), 6, "the upper-case words are new groups")
    var res = t.drain_to_record_batch()
    ref out = res.value()
    var keys = out.column_at(0).as_string()
    assert_equal(keys.get(0), String("kiwi"), "row 0 code 1 first")
    assert_equal(keys.get(3), String("KIWI"), "second fold, same order")
    var c = out.column_at(2).as_primitive[DType.int64]()
    for g in range(6):
        assert_equal(c.get(g), Int64(4), "12 rows over 3 codes, per fold")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
