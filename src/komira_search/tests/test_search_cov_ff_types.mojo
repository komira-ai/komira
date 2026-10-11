# =============================================================================
# test_search_cov_ff_types.mojo: fast-field types the other suites do not
# write (narrow and unsigned integers, FLOAT32, nulls in float and keyword
# columns, a one-term keyword dictionary), read back through every accessor,
# and the accessors' refusals of the wrong field type.
# =============================================================================
#
#   1. The storage DType of every Arrow type a fast field accepts.
#   2. INT8 / INT16 / UINT8 / UINT16 / UINT32 / UINT64 columns with a null
#      materialize as that type: values, null position, null count.
#   3. A NUMERIC entry whose Arrow type has no storage DType is refused by the
#      materializer rather than read through a default width.
#   4. FLOAT32 and FLOAT64 columns with nulls, written by the sink: the per-doc
#      accessor, the resolver and the materializer agree on every value and
#      on every null; the FLOAT32 value is the f32 widened, not the bit pattern.
#   5. Keyword columns: a null materializes as a null row; a one-term
#      dictionary (code width 0) reads its term on every row; a dictionary
#      holding a term and its own prefix sorts the prefix first.
#   6. Each accessor refuses a field of the wrong type, and entry_meta_at an
#      index out of range.
#   7. The builder's token_counts reads a null as 0; a region with no field and
#      no document is empty.
#   8. The unsigned 64-bit bitpack helpers: width 0, a width out of range, a
#      run past the source, and a value with the top bit set round-trips.
# =============================================================================

from std.memory import bitcast
from std.sys import size_of
from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from komira_search.analyzer import (
    AnalyzedField,
    Token,
    FIELD_CLASS_NUMERIC,
    FIELD_CLASS_KEYWORD,
)
from komira_search.inverted import InvertedIndexBuilder
from komira_search.term_dict import TermDictBuilder
from komira_search.split import SplitView, serialize_split, DocStoreBuilder
from komira_search.sink import SearchSink
from komira_search.fast_fields import (
    FastFieldReader,
    FastFieldSpec,
    NumericFastFieldBuilder,
    KeywordFastFieldBuilder,
    serialize_fastfields_region,
    _storage_dtype_for_arrow_type_id,
    _pack_bits_lsb_first_u64,
    _unpack_bits_lsb_first_u64,
)


def _uuid() -> Array[UInt8, 16]:
    return Array[UInt8, 16](fill=3)


def _split_with_ff(var ff: List[UInt8], n: Int) raises -> List[UInt8]:
    """A split of `n` docs (each the one term "w") carrying `ff` as its
    fast-fields region."""
    var b = InvertedIndexBuilder.create("body")
    var ds = DocStoreBuilder(compress=False)
    for d in range(n):
        var toks = List[Token]()
        toks.append(Token(String("w"), 0))
        b.add_document(d, AnalyzedField(toks^))
        ds.append(String("d").as_bytes())
    var fi = b.finalize()
    return serialize_split(
        fi, TermDictBuilder.build_from_finalized(fi), ds, String("body"),
        _uuid(), 0, n - 1, n, fastfields_region=ff^,
    )


def _fieldnorm(n: Int) -> NumericFastFieldBuilder:
    var fnb = NumericFastFieldBuilder(ArrowType.INT64.type_id, DType.int64)
    for _ in range(n):
        fnb.append_int(1, False)
    return fnb^


def _one_numeric_split(
    at: ArrowType, dt: DType, values: List[Int], nulls: List[Bool]
) raises -> List[UInt8]:
    var specs = List[FastFieldSpec]()
    specs.append(FastFieldSpec(String("f"), 2, FIELD_CLASS_NUMERIC, at.type_id, dt))
    var nb = NumericFastFieldBuilder(at.type_id, dt)
    for i in range(len(values)):
        nb.append_int(values[i], nulls[i])
    var nums = List[NumericFastFieldBuilder]()
    nums.append(nb^)
    var ff = serialize_fastfields_region(
        specs, nums, List[KeywordFastFieldBuilder](), _fieldnorm(len(values))
    )
    return _split_with_ff(ff^, len(values))


def test_01_storage_dtype_map() raises:
    var ids: List[UInt8] = [
        ArrowType.INT8.type_id, ArrowType.INT16.type_id,
        ArrowType.INT32.type_id, ArrowType.INT64.type_id,
        ArrowType.UINT8.type_id, ArrowType.UINT16.type_id,
        ArrowType.UINT32.type_id, ArrowType.UINT64.type_id,
        ArrowType.FLOAT32.type_id, ArrowType.FLOAT64.type_id,
        ArrowType.DATE32.type_id, ArrowType.DATE64.type_id,
        ArrowType.TIMESTAMP.type_id, ArrowType.TIMESTAMP_S.type_id,
        ArrowType.TIMESTAMP_MS.type_id, ArrowType.TIMESTAMP_US.type_id,
        ArrowType.TIMESTAMP_NS.type_id,
    ]
    var want: List[DType] = [
        DType.int8, DType.int16, DType.int32, DType.int64,
        DType.uint8, DType.uint16, DType.uint32, DType.uint64,
        DType.float32, DType.float64,
        DType.int32, DType.int64,
        DType.int64, DType.int64, DType.int64, DType.int64, DType.int64,
    ]
    for i in range(len(ids)):
        assert_equal(
            _storage_dtype_for_arrow_type_id(ids[i]), want[i],
            "1: type id " + String(Int(ids[i])),
        )


def _check_narrow[dt: DType](at: ArrowType) raises:
    var values: List[Int] = [3, 0, 1, 7]
    var nulls: List[Bool] = [False, True, False, False]
    var bytes = _one_numeric_split(at, dt, values, nulls)
    var view = SplitView.parse(bytes^)
    var reader = FastFieldReader(view)
    var col = reader.fast_field_column(view, String("f"))
    var ctx = "2: " + String(dt)
    assert_equal(col.arrow_type.type_id, at.type_id, ctx + " arrow type")
    assert_equal(col.null_count(), 1, ctx + " one null")
    assert_true(col.is_null_at(1), ctx + " row 1 null")
    var arr = col.as_primitive[dt]()
    assert_equal(Int(arr.get(0)), 3, ctx + " row 0")
    assert_equal(Int(arr.get(2)), 1, ctx + " row 2")
    assert_equal(Int(arr.get(3)), 7, ctx + " row 3")


def test_02_narrow_and_unsigned_materialize() raises:
    _check_narrow[DType.int8](ArrowType.INT8)
    _check_narrow[DType.int16](ArrowType.INT16)
    _check_narrow[DType.uint8](ArrowType.UINT8)
    _check_narrow[DType.uint16](ArrowType.UINT16)
    _check_narrow[DType.uint32](ArrowType.UINT32)
    _check_narrow[DType.uint64](ArrowType.UINT64)


def test_03_numeric_without_storage_dtype_is_refused() raises:
    var values: List[Int] = [1, 2]
    var nulls: List[Bool] = [False, False]
    var bytes = _one_numeric_split(ArrowType.STRING, DType.int64, values, nulls)
    var view = SplitView.parse(bytes^)
    var reader = FastFieldReader(view)
    with assert_raises(contains="_materialize_numeric: unhandled storage DType"):
        _ = reader.fast_field_column(view, String("f"))


def _float_col[
    dt: DType
](
    raw: List[Scalar[dt]], null_idx: List[Int], at: ArrowType
) raises -> Column[HeapRegion]:
    var n = len(raw)
    comptime es = size_of[Scalar[dt]]()
    var buf = OwnedAlignedBuffer(max(n, 1) * es)
    for i in range(n):
        buf.set_typed[Scalar[dt]](i, raw[i])
    buf.set_length(Int64(n * es))
    var validity = Bitmap.create_all_valid(n)
    for k in range(len(null_idx)):
        validity.clear(null_idx[k])
    var arr = PrimitiveArray[dt](
        buf^, n, Optional[Bitmap[HeapRegion]](validity^), len(null_idx), 0
    )
    return Column.from_primitive_with_arrow_type[dt](arr^, at)


def _str_col(values: List[String]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings(values))


def _float_split() raises -> List[UInt8]:
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("f4", ArrowType.FLOAT32, True))
    sb.add_field(Field("f8", ArrowType.FLOAT64, True))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(4)
    rb.add_column(_str_col([String("a"), String("b"), String("c")]))
    rb.add_column(_str_col([String("s0"), String("s1"), String("s2")]))
    var f4: List[Float32] = [1.5, 0.0, -2.25]
    rb.add_column(_float_col[DType.float32](f4, [1], ArrowType.FLOAT32))
    var f8: List[Float64] = [0.0, 3.125, -0.5]
    rb.add_column(_float_col[DType.float64](f8, [0], ArrowType.FLOAT64))
    var batch = rb.build(schema.copy())
    var sink = SearchSink(
        String("b"), String("p"), String("i"), String("body"), _uuid()
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


def test_04_float_columns_with_nulls() raises:
    var bytes = _float_split()
    var view = SplitView.parse(bytes^)
    var reader = FastFieldReader(view)
    var r4 = reader.float_resolver(view, String("f4"))
    var r8 = reader.float_resolver(view, String("f8"))
    # FLOAT32: 1.5, null, -2.25.
    var want4: List[Float64] = [1.5, 0.0, -2.25]
    var want8: List[Float64] = [0.0, 3.125, -0.5]
    for d in range(3):
        var a = reader.fast_field_f64(view, String("f4"), d)
        var b = r4.f64_at(view, d)
        if d == 1:
            assert_false(Bool(a), "4: f4 row 1 null (accessor)")
            assert_false(Bool(b), "4: f4 row 1 null (resolver)")
        else:
            assert_equal(a.value(), want4[d], "4: f4 accessor row " + String(d))
            assert_equal(b.value(), want4[d], "4: f4 resolver row " + String(d))
        var c = reader.fast_field_f64(view, String("f8"), d)
        var e = r8.f64_at(view, d)
        if d == 0:
            assert_false(Bool(c), "4: f8 row 0 null (accessor)")
            assert_false(Bool(e), "4: f8 row 0 null (resolver)")
        else:
            assert_equal(c.value(), want8[d], "4: f8 accessor row " + String(d))
            assert_equal(e.value(), want8[d], "4: f8 resolver row " + String(d))
    var c4 = reader.fast_field_column(view, String("f4"))
    assert_equal(c4.arrow_type.type_id, ArrowType.FLOAT32.type_id, "4: f4 type")
    assert_equal(c4.null_count(), 1, "4: f4 one null")
    assert_true(c4.is_null_at(1), "4: f4 row 1 null (column)")
    var a4 = c4.as_primitive[DType.float32]()
    assert_equal(a4.get(0), Float32(1.5), "4: f4 column row 0")
    assert_equal(a4.get(2), Float32(-2.25), "4: f4 column row 2")
    var c8 = reader.fast_field_column(view, String("f8"))
    assert_equal(c8.arrow_type.type_id, ArrowType.FLOAT64.type_id, "4: f8 type")
    assert_equal(c8.null_count(), 1, "4: f8 one null")
    assert_true(c8.is_null_at(0), "4: f8 row 0 null (column)")
    var a8 = c8.as_primitive[DType.float64]()
    assert_equal(a8.get(1), 3.125, "4: f8 column row 1")
    assert_equal(a8.get(2), -0.5, "4: f8 column row 2")


def _kw_split(terms: List[String], nulls: List[Bool]) raises -> List[UInt8]:
    var specs = List[FastFieldSpec]()
    specs.append(
        FastFieldSpec(
            String("k"), 2, FIELD_CLASS_KEYWORD, ArrowType.STRING.type_id,
            DType.int64,
        )
    )
    var kb = KeywordFastFieldBuilder()
    for i in range(len(terms)):
        kb.append(terms[i], nulls[i])
    var kws = List[KeywordFastFieldBuilder]()
    kws.append(kb^)
    var ff = serialize_fastfields_region(
        specs, List[NumericFastFieldBuilder](), kws, _fieldnorm(len(terms))
    )
    return _split_with_ff(ff^, len(terms))


def test_05_keyword_columns() raises:
    # A null row, and a dictionary holding "abc" and its prefix "ab".
    var bytes = _kw_split(
        [String("abc"), String(""), String("ab"), String("abc")],
        [False, True, False, False],
    )
    var view = SplitView.parse(bytes^)
    var reader = FastFieldReader(view)
    var col = reader.fast_field_column(view, String("k"))
    assert_equal(col.dict_size(), 2, "5: two terms")
    assert_equal(col.null_count(), 1, "5: one null")
    assert_true(col.is_null_at(1), "5: row 1 null")
    # Sorted dictionary: "ab" (code 0) before "abc" (code 1).
    assert_equal(col.dict_code_at(0), 1, "5: row 0 is abc")
    assert_equal(col.dict_code_at(2), 0, "5: row 2 is ab")
    assert_equal(col.dict_code_at(3), 1, "5: row 3 is abc")
    assert_equal(
        reader.fast_field_keyword(view, String("k"), 2).value(), String("ab"),
        "5: accessor row 2",
    )
    # One term in every row: a code width of 0, read on every row.
    var one = _kw_split(
        [String("solo"), String("solo"), String("solo")], [False, False, False]
    )
    var v1 = SplitView.parse(one^)
    var r1 = FastFieldReader(v1)
    var kr = r1.keyword_resolver(v1, String("k"))
    for d in range(3):
        assert_equal(kr.keyword_at(v1, d).value(), String("solo"), "5: resolver")
        assert_equal(
            r1.fast_field_keyword(v1, String("k"), d).value(), String("solo"),
            "5: accessor",
        )


def test_06_wrong_type_refusals() raises:
    var bytes = _float_split()
    var view = SplitView.parse(bytes^)
    var reader = FastFieldReader(view)
    with assert_raises(contains="fast_field_i64: 'f8' is a float field"):
        _ = reader.fast_field_i64(view, String("f8"), 0)
    with assert_raises(contains="fast_field_f64: '__fieldnorm__' is not a float"):
        _ = reader.fast_field_f64(view, String("__fieldnorm__"), 0)
    with assert_raises(contains="fast_field_keyword: 'f4' is not a keyword"):
        _ = reader.fast_field_keyword(view, String("f4"), 0)
    with assert_raises(contains="keyword_resolver: 'f4' is not a keyword"):
        _ = reader.keyword_resolver(view, String("f4"))
    with assert_raises(contains="float_resolver: '__fieldnorm__' is not a float"):
        _ = reader.float_resolver(view, String("__fieldnorm__"))
    var n = reader.num_fields()
    assert_equal(n, 3, "6: f4, f8 and the fieldnorm")
    with assert_raises(contains="entry_meta_at: index 3 out of range [0, 3)"):
        _ = reader.entry_meta_at(n)
    with assert_raises(contains="entry_meta_at: index -1 out of range"):
        _ = reader.entry_meta_at(-1)
    var kbytes = _kw_split([String("x")], [False])
    var kview = SplitView.parse(kbytes^)
    var kreader = FastFieldReader(kview)
    with assert_raises(contains="fast_field_i64: 'k' is a keyword field"):
        _ = kreader.fast_field_i64(kview, String("k"), 0)


def test_07_builder_edges() raises:
    var nb = NumericFastFieldBuilder(ArrowType.INT64.type_id, DType.int64)
    nb.append_int(4, False)
    nb.append_int(9, True)
    nb.append_int(2, False)
    var tc = nb.token_counts()
    assert_equal(len(tc), 3, "7: three counts")
    assert_equal(tc[0], 4, "7: row 0")
    assert_equal(tc[1], 0, "7: a null reads 0")
    assert_equal(tc[2], 2, "7: row 2")
    var empty = serialize_fastfields_region(
        List[FastFieldSpec](),
        List[NumericFastFieldBuilder](),
        List[KeywordFastFieldBuilder](),
        NumericFastFieldBuilder(ArrowType.INT64.type_id, DType.int64),
    )
    assert_equal(len(empty), 0, "7: nothing to write, empty region")


def test_08_u64_bitpack() raises:
    var vals: List[UInt64] = [UInt64(0xFFFF_FFFF_FFFF_FFFE), UInt64(3)]
    var out = List[UInt8]()
    _pack_bits_lsb_first_u64(Span(vals), 2, 0, out)
    assert_equal(len(out), 0, "8: width 0 writes nothing")
    with assert_raises(contains="_pack_bits_lsb_first_u64: bit_width 65"):
        _pack_bits_lsb_first_u64(Span(vals), 2, 65, out)
    with assert_raises(contains="_pack_bits_lsb_first_u64: bit_width -1"):
        _pack_bits_lsb_first_u64(Span(vals), 2, -1, out)
    _pack_bits_lsb_first_u64(Span(vals), 2, 64, out)
    assert_equal(len(out), 16, "8: two 64-bit values")
    var back = List[UInt64]()
    _unpack_bits_lsb_first_u64(Span(out), 0, 2, 64, back)
    assert_equal(back[0], vals[0], "8: top bit set round-trips")
    assert_equal(back[1], UInt64(3), "8: value 1")
    var zeros = List[UInt64]()
    _unpack_bits_lsb_first_u64(Span(out), 0, 3, 0, zeros)
    assert_equal(len(zeros), 3, "8: width 0 reads count zeros")
    assert_equal(zeros[2], UInt64(0), "8: a zero")
    with assert_raises(contains="_unpack_bits_lsb_first_u64: bit_width 65"):
        _unpack_bits_lsb_first_u64(Span(out), 0, 1, 65, back)
    with assert_raises(contains="_unpack_bits_lsb_first_u64: bit_width -2"):
        _unpack_bits_lsb_first_u64(Span(out), 0, 1, -2, back)
    with assert_raises(contains="packed run [8, 24) exceeds source length 16"):
        _unpack_bits_lsb_first_u64(Span(out), 8, 2, 64, back)
    with assert_raises(contains="packed run [-1, 7) exceeds source length 16"):
        _unpack_bits_lsb_first_u64(Span(out), -1, 1, 64, back)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
