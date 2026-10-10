# =============================================================================
# test_join_gather_fixed_dict_arms -- the DICTIONARY, BOOL and fixed-width arms
# of `emit_gather_column_projected` that the narrow-width test does not reach
# =============================================================================
#
# Every source column is WINDOWED (`_offset = 3` over a longer physical column)
# and, where it carries validity, its bitmap is the WHOLE-column one read at
# `_offset + idx`; a gather that drops `_offset` on the value read or on the
# validity read returns the wrong row.
#
# Cases
#   A  DICTIONARY, outer side, source validity: codes at `_offset + idx`, `-1`
#      writes code 0 and is NULL, the dictionary offsets / bytes / size are
#      carried whole.
#   B  DICTIONARY, inner side, source validity.
#   C  DICTIONARY with no validity on an inner and an outer side, and an all-empty
#      dictionary (zero dictionary bytes).
#   D  DICTIONARY with no `_offsets`, then with no `_dict_data`: each refused.
#   E  BOOL, outer side, source validity.
#   F  Fixed widths 8/4/2/1/16/32 on the OUTER side over a nullable source,
#      `count > 16` so the prefetch look-ahead runs: values at `_offset + idx`,
#      `-1` slots zero-filled, NULLs from both `-1` and the source bitmap.
#   G  The same widths on the INNER side.
#   H  Decimal precision/scale on both sides: carried from the COLUMN when it
#      has them, else from the SCHEMA field.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_join_assembly.compiler_join_assembly import (
    emit_gather_column_projected,
)


comptime _BASE: Int = 3
comptime _N: Int = 60
"""Physical rows per source column; the window is `[_BASE, _N)`."""


def _is_src_null(phys: Int) -> Bool:
    return phys % 5 == 1


def _bitmap(n: Int) -> Bitmap[HeapRegion]:
    var bm = Bitmap.create(n)
    for i in range(n):
        if _is_src_null(i):
            bm.clear(i)
        else:
            bm.set(i)
    return bm^


def _window_nulls() -> Int:
    var c = 0
    for i in range(_BASE, _N):
        if _is_src_null(i):
            c += 1
    return c


def _indices(count: Int, with_sentinels: Bool) -> List[Int]:
    var out = List[Int]()
    for j in range(count):
        if with_sentinels and (j % 6 == 2):
            out.append(-1)
        else:
            out.append((j * 13 + 5) % (_N - _BASE))
    return out^


def _one_col_batch(
    var col: Column[HeapRegion], var field: Field
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(field^)
    var bb = RecordBatchBuilder()
    bb.add_column(col^)
    return bb.build(sb.build())


def _gather(ref batch: RecordBatch, idx: List[Int], nullable: Bool) raises -> RecordBatch:
    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()
    emit_gather_column_projected(
        batch, 0, String("out"), nullable, idx, len(idx), builder, sb
    )
    return builder.build(sb.build())


def _check_validity(
    ref col: Column[HeapRegion], idx: List[Int], src_validity: Bool, tag: String
) raises:
    var want = 0
    for i in range(len(idx)):
        var null = idx[i] == -1 or (src_validity and _is_src_null(_BASE + idx[i]))
        if null:
            want += 1
            assert_false(col._validity.value().test(i), tag + " NULL at " + String(i))
        else:
            assert_true(col._validity.value().test(i), tag + " valid at " + String(i))
    assert_equal(col._null_count, want, tag + " null_count")


# =============================================================================
# DICTIONARY
# =============================================================================


def _dict_words() -> List[String]:
    var d = List[String]()
    d.append(String("alpha"))
    d.append(String("b"))
    d.append(String("gamma-gamma"))
    d.append(String("dd"))
    d.append(String("e"))
    return d^


def _code(phys: Int) -> Int32:
    return Int32((phys * 3 + 1) % 5)


def _dict_col(with_validity: Bool, var words: List[String]) raises -> Column[HeapRegion]:
    var codes = List[Scalar[DType.int32]]()
    for i in range(_N):
        codes.append(_code(i) % Int32(len(words)))
    var arr = StringDictionaryArray.from_parts(
        PrimitiveArray[DType.int32].from_list(codes),
        StringArray.from_strings(words),
    )
    var full = Column.from_dictionary(arr)
    var col = full.share()
    col._offset = _BASE
    col._length = _N - _BASE
    if with_validity:
        col._validity = _bitmap(_N)
        col._null_count = _window_nulls()
    return col^


def _check_dict(
    ref out: Column[HeapRegion],
    ref src: Column[HeapRegion],
    idx: List[Int],
    n_words: Int,
    tag: String,
) raises:
    assert_true(out.arrow_type == ArrowType.DICTIONARY, tag + " tag")
    assert_equal(out._dict_size, src._dict_size, tag + " dict size")
    for i in range(len(idx)):
        var got = Int(out._data.get_typed[Int32](i))
        if idx[i] == -1:
            assert_equal(got, 0, tag + " -1 writes code 0")
        else:
            assert_equal(
                got,
                Int(_code(_BASE + idx[i]) % Int32(n_words)),
                tag + " code at " + String(i),
            )
    var nb = (src._dict_size + 1) * 4
    assert_equal(Int(out._offsets.value().len()), nb, tag + " dict offsets length")
    for k in range(src._dict_size + 1):
        assert_equal(
            Int(out._offsets.value().get_typed[Int32](k)),
            Int(src._offsets.value().get_typed[Int32](k)),
            tag + " dict offset " + String(k),
        )
    var dl = src._dict_data.value().len()
    assert_equal(out._dict_data.value().len(), dl, tag + " dict bytes length")
    for k in range(dl):
        assert_equal(
            Int(out._dict_data.value().get_typed[Scalar[DType.uint8]](k)),
            Int(src._dict_data.value().get_typed[Scalar[DType.uint8]](k)),
            tag + " dict byte " + String(k),
        )


def test_a_dictionary_outer_side_over_nullable_window() raises:
    var batch = _one_col_batch(
        _dict_col(True, _dict_words()),
        Field(String("v"), ArrowType.DICTIONARY, True),
    )
    var idx = _indices(41, True)
    var out = _gather(batch, idx, True)
    _check_dict(out.column_at(0), batch.column_at(0), idx, 5, "§A")
    _check_validity(out.column_at(0), idx, True, "§A")


def test_b_dictionary_inner_side_over_nullable_window() raises:
    var batch = _one_col_batch(
        _dict_col(True, _dict_words()),
        Field(String("v"), ArrowType.DICTIONARY, True),
    )
    var idx = _indices(37, False)
    var out = _gather(batch, idx, False)
    _check_dict(out.column_at(0), batch.column_at(0), idx, 5, "§B")
    _check_validity(out.column_at(0), idx, True, "§B")


def test_c_dictionary_without_validity_and_empty_dictionary_bytes() raises:
    var batch = _one_col_batch(
        _dict_col(False, _dict_words()),
        Field(String("v"), ArrowType.DICTIONARY, False),
    )
    var idx = _indices(19, False)
    var out = _gather(batch, idx, False)
    assert_false(out.column_at(0)._validity.__bool__(), "§C no bitmap")
    _check_dict(out.column_at(0), batch.column_at(0), idx, 5, "§C")

    # Outer side over the same bitmap-less source: only `-1` is NULL.
    var sidx = _indices(19, True)
    var outer = _gather(batch, sidx, True)
    _check_dict(outer.column_at(0), batch.column_at(0), sidx, 5, "§C outer")
    _check_validity(outer.column_at(0), sidx, False, "§C outer")

    var empty = List[String]()
    empty.append(String(""))
    var batch2 = _one_col_batch(
        _dict_col(False, empty^), Field(String("v"), ArrowType.DICTIONARY, False)
    )
    var out2 = _gather(batch2, idx, False)
    _check_dict(out2.column_at(0), batch2.column_at(0), idx, 1, "§C empty")


def test_d_malformed_dictionary_is_refused() raises:
    var idx = _indices(6, False)
    var no_off = _dict_col(False, _dict_words())
    no_off._offsets = None
    var b1 = _one_col_batch(no_off^, Field(String("v"), ArrowType.DICTIONARY, False))
    var raised = False
    try:
        _ = _gather(b1, idx, False)
    except e:
        raised = True
        assert_true(String(e).find("missing _offsets") >= 0, "§D msg " + String(e))
    assert_true(raised, "§D no _offsets must raise")

    var no_dict = _dict_col(False, _dict_words())
    no_dict._dict_data = None
    var b2 = _one_col_batch(no_dict^, Field(String("v"), ArrowType.DICTIONARY, False))
    raised = False
    try:
        _ = _gather(b2, idx, False)
    except e:
        raised = True
        assert_true(String(e).find("missing _dict_data") >= 0, "§D msg " + String(e))
    assert_true(raised, "§D no _dict_data must raise")


# =============================================================================
# BOOL
# =============================================================================


def _flag(phys: Int) -> Bool:
    """Period 4, which does not divide `_BASE = 3`: `_flag(_BASE + i)` differs
    from `_flag(i)` for most `i`, so a value read that drops `_offset` is
    caught."""
    return phys % 4 == 1


def test_e_bool_outer_side_over_nullable_window() raises:
    var flags = BooleanArray.allocate(_N)
    for i in range(_N):
        flags.set(i, _flag(i))
    var col = Column.from_boolean(flags).share()
    col._offset = _BASE
    col._length = _N - _BASE
    col._validity = _bitmap(_N)
    col._null_count = _window_nulls()
    var batch = _one_col_batch(col^, Field(String("v"), ArrowType.BOOL, True))
    var idx = _indices(43, True)
    var out = _gather(batch, idx, True)
    ref oc = out.column_at(0)
    _check_validity(oc, idx, True, "§E")
    var vals = oc.as_boolean()
    for i in range(len(idx)):
        if idx[i] != -1:
            assert_equal(vals.get(i), _flag(_BASE + idx[i]), "§E value at " + String(i))


# =============================================================================
# Fixed widths
# =============================================================================


def _byte(phys: Int, k: Int) -> UInt8:
    """Byte `k` of physical element `phys`: never 0, distinct per element at
    k == 0 for phys < 250."""
    return UInt8((phys * 31 + k * 7) % 250 + 1)


def _fixed_col(
    at: ArrowType, w: Int, with_validity: Bool, dec_p: Int = 0, dec_s: Int = 0
) raises -> Column[HeapRegion]:
    var buf = OwnedAlignedBuffer(_N * w)
    for i in range(_N):
        for k in range(w):
            buf.set_typed[Scalar[DType.uint8]](i * w + k, _byte(i, k))
    buf.set_length(Int64(_N * w))
    var validity = Optional[Bitmap[HeapRegion]](None)
    var nulls = 0
    if with_validity:
        validity = _bitmap(_N)
        nulls = _window_nulls()
    var col = Column[HeapRegion](
        arrow_type=at,
        data=buf^,
        offsets=Optional[OwnedAlignedBuffer](None),
        validity=validity^,
        length=_N - _BASE,
        null_count=nulls,
        offset=_BASE,
    )
    col._decimal_p = dec_p
    col._decimal_s = dec_s
    return col^


def _check_fixed(
    ref col: Column[HeapRegion], idx: List[Int], w: Int, tag: String
) raises:
    assert_equal(Int(col._data.len()), len(idx) * w, tag + " data length")
    for i in range(len(idx)):
        for k in range(w):
            var got = Int(col._data.get_typed[Scalar[DType.uint8]](i * w + k))
            if idx[i] == -1:
                assert_equal(got, 0, tag + " -1 slot zero-filled at " + String(i))
            else:
                assert_equal(
                    got,
                    Int(_byte(_BASE + idx[i], k)),
                    tag + " byte " + String(k) + " of row " + String(i),
                )


def _types() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.INT64)
    t.append(ArrowType.INT32)
    t.append(ArrowType.INT16)
    t.append(ArrowType.INT8)
    t.append(ArrowType.DECIMAL128)
    t.append(ArrowType.DECIMAL256)
    return t^


def _widths() -> List[Int]:
    var w = List[Int]()
    w.append(8)
    w.append(4)
    w.append(2)
    w.append(1)
    w.append(16)
    w.append(32)
    return w^


def test_f_fixed_widths_outer_side_over_nullable_window() raises:
    var ts = _types()
    var ws = _widths()
    var idx = _indices(47, True)
    for t in range(len(ts)):
        var tag = "§F w=" + String(ws[t])
        var batch = _one_col_batch(
            _fixed_col(ts[t], ws[t], True), Field(String("v"), ts[t], True)
        )
        var out = _gather(batch, idx, True)
        _check_fixed(out.column_at(0), idx, ws[t], tag)
        _check_validity(out.column_at(0), idx, True, tag)


def test_g_fixed_widths_inner_side() raises:
    var ts = _types()
    var ws = _widths()
    var idx = _indices(45, False)
    for t in range(len(ts)):
        var tag = "§G w=" + String(ws[t])
        var batch = _one_col_batch(
            _fixed_col(ts[t], ws[t], False), Field(String("v"), ts[t], False)
        )
        var out = _gather(batch, idx, False)
        _check_fixed(out.column_at(0), idx, ws[t], tag)
        assert_false(out.column_at(0)._validity.__bool__(), tag + " no bitmap")


def _dec_field(at: ArrowType, p: Int, s: Int) -> Field:
    var f = Field(String("v"), at, True)
    f.decimal_precision = p
    f.decimal_scale = s
    return f^


def test_h_decimal_precision_from_column_then_schema() raises:
    var ts = List[ArrowType]()
    ts.append(ArrowType.DECIMAL128)
    ts.append(ArrowType.DECIMAL256)
    var ws = List[Int]()
    ws.append(16)
    ws.append(32)
    for t in range(2):
        for side in range(2):
            var nullable = side == 1
            var idx = _indices(20, nullable)
            var tag = "§H w=" + String(ws[t]) + " nullable=" + String(nullable)
            # The COLUMN carries (12, 2); the schema says (30, 9): column wins.
            var b1 = _one_col_batch(
                _fixed_col(ts[t], ws[t], False, 12, 2), _dec_field(ts[t], 30, 9)
            )
            var o1 = _gather(b1, idx, nullable)
            assert_equal(o1.column_at(0)._decimal_p, 12, tag + " column p")
            assert_equal(o1.column_at(0)._decimal_s, 2, tag + " column s")
            # The column has none: the schema field's (30, 9) is used.
            var b2 = _one_col_batch(
                _fixed_col(ts[t], ws[t], False), _dec_field(ts[t], 30, 9)
            )
            var o2 = _gather(b2, idx, nullable)
            assert_equal(o2.column_at(0)._decimal_p, 30, tag + " schema p")
            assert_equal(o2.column_at(0)._decimal_s, 9, tag + " schema s")
            _check_fixed(o2.column_at(0), idx, ws[t], tag)


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_dictionary_outer_side_over_nullable_window]()
    suite.test[test_b_dictionary_inner_side_over_nullable_window]()
    suite.test[test_c_dictionary_without_validity_and_empty_dictionary_bytes]()
    suite.test[test_d_malformed_dictionary_is_refused]()
    suite.test[test_e_bool_outer_side_over_nullable_window]()
    suite.test[test_f_fixed_widths_outer_side_over_nullable_window]()
    suite.test[test_g_fixed_widths_inner_side]()
    suite.test[test_h_decimal_precision_from_column_then_schema]()
    suite^.run()
