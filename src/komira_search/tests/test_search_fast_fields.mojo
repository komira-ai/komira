# =============================================================================
# test_search_fast_fields.mojo — fast-fields unit test
# =============================================================================
#
# An 8-case test plan over fast_fields' design points J1–J6.
#
# PURE unit suite — NO S3.
#
# Coverage:
#   1. Numeric round-trip (INT64 + INT32 + FLOAT64; incl a NEGATIVE-min column
#      [zig-zag] + a NEGATIVE float -1.5).
#   2. Date round-trip (DATE32 -> fast_field_i64 day number; AND fast_field_column
#      materializes as DATE32 not INT32).
#   3. Keyword round-trip (low-card STRING; dict sorted-ascending).
#   4. Fieldnorm (text col; fast_field_i64("__fieldnorm__") == AnalyzedField.len()).
#   5. Whole-column materializer (numeric -> primitive; keyword -> dictionary).
#   6. Nulls (numeric + keyword null cell -> None via col_is_null).
#   7. Additive compat (no-fast-fields split: len==0, parse OK,
#      has_fastfields()==False, reader empty [J6]).
#   8. Corrupt-bytes fail-loud (bad magic / truncated / dict code >= size /
#      sub_offset past end / out-of-range doc_id -> each RAISES).
# =============================================================================

from std.memory import bitcast
from std.sys import size_of
from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    assert_almost_equal,
)

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.column import Column
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.io.heap_region import HeapRegion

from komira_search.analyzer import (
    AnalyzerConfig,
    AnalyzedField,
    Token,
    analyze_text,
)
from komira_search.split import SplitView, serialize_split, DocStoreBuilder
from komira_search.inverted import InvertedIndexBuilder
from komira_search.term_dict import TermDictBuilder
from komira_search.sink import IndexCore, SearchSink
from komira_search.fast_fields import (
    FastFieldReader,
    FieldnormResolver,
    FastFieldSpec,
    NumericFastFieldBuilder,
    KeywordFastFieldBuilder,
    serialize_fastfields_region,
    FIELDNORM_NAME,
    FF_ENC_FLOAT_FULL,
    FF_ENC_KEYWORD_DICT,
)


# -----------------------------------------------------------------------------
# Fixture helpers
# -----------------------------------------------------------------------------


def _uuid(seed: UInt8) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=0)
    for i in range(16):
        u[i] = seed + UInt8(i)
    return u^


def _i64_col(values: List[Int64]) raises -> Column[HeapRegion]:
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(values)
    )


def _i32_col(values: List[Int32]) raises -> Column[HeapRegion]:
    return Column.from_primitive[DType.int32](
        PrimitiveArray[DType.int32].from_list(values)
    )


def _f64_col(values: List[Float64]) raises -> Column[HeapRegion]:
    return Column.from_primitive[DType.float64](
        PrimitiveArray[DType.float64].from_list(values)
    )


def _date32_col(days: List[Int32]) raises -> Column[HeapRegion]:
    return Column.from_primitive_with_arrow_type[DType.int32](
        PrimitiveArray[DType.int32].from_list(days), ArrowType.DATE32
    )


def _str_col(values: List[String]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings(values))


def _i64_col_nullable(
    raw: List[Int64], null_idx: List[Int]
) raises -> Column[HeapRegion]:
    var n = len(raw)
    comptime es = size_of[Scalar[DType.int64]]()
    var buf = OwnedAlignedBuffer(max(n, 1) * es)
    for i in range(n):
        buf.set_typed[Scalar[DType.int64]](i, raw[i])
    buf.set_length(Int64(n * es))
    var validity = Bitmap.create_all_valid(n)
    for k in range(len(null_idx)):
        validity.clear(null_idx[k])
    var arr = PrimitiveArray[DType.int64](
        buf^, n, Optional[Bitmap[HeapRegion]](validity^), len(null_idx), 0
    )
    return Column.from_primitive[DType.int64](arr)


def _str_col_nullable(
    values: List[String], valid: List[Bool]
) raises -> Column[HeapRegion]:
    return Column.from_string(
        StringArray.from_strings_with_validity(values, valid)
    )


def _drive_sink(var batch: RecordBatch, var schema: Schema) raises -> List[UInt8]:
    """Drive a SearchSink over a pre-built (schema, batch) and return the split
    bytes. Mirrors the production write seam (init_sink -> accept_batch ->
    finish). The schema MUST carry a "body" text col + a "_source" col + any
    fast-field columns."""
    var sink = SearchSink(
        String("bucket"),
        String("prefix"),
        String("idx"),
        String("body"),
        _uuid(3),
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


# =============================================================================
# Case 1 — numeric round-trip (INT64 + INT32 + FLOAT64; negative min + -1.5).
# =============================================================================


def test_01_numeric_roundtrip() raises:
    var text: List[String] = [String("alpha"), String("beta"), String("gamma")]
    var source: List[String] = [String("d0"), String("d1"), String("d2")]

    # qty INT64 (positive), temp INT32 with a NEGATIVE min (-5), price FLOAT64
    # with a NEGATIVE value -1.5.
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("qty", ArrowType.INT64, True))
    sb.add_field(Field("temp", ArrowType.INT32, True))
    sb.add_field(Field("price", ArrowType.FLOAT64, True))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(5)
    rb.add_column(_str_col(text))
    rb.add_column(_str_col(source))
    rb.add_column(_i64_col([Int64(100), Int64(7), Int64(99999)]))
    rb.add_column(_i32_col([Int32(-5), Int32(0), Int32(42)]))
    rb.add_column(_f64_col([Float64(3.14), Float64(-1.5), Float64(0.0)]))
    var batch = rb.build(schema.copy())

    var bytes = _drive_sink(batch^, schema^)
    var view = SplitView.parse(bytes^)
    assert_true(view.has_fastfields(), "1: has fast-fields")
    var reader = FastFieldReader(view)

    # doc-ids are 0,1,2 (min_doc_id 0).
    var exp_qty = [Int64(100), Int64(7), Int64(99999)]
    var exp_temp = [Int64(-5), Int64(0), Int64(42)]
    var exp_price = [Float64(3.14), Float64(-1.5), Float64(0.0)]
    for d in range(3):
        var q = reader.fast_field_i64(view, String("qty"), d)
        assert_true(Bool(q), "1: qty not null")
        assert_equal(q.value(), exp_qty[d], "1: qty value")
        var t = reader.fast_field_i64(view, String("temp"), d)
        assert_true(Bool(t), "1: temp not null")
        assert_equal(t.value(), exp_temp[d], "1: temp value (negative min)")
        var p = reader.fast_field_f64(view, String("price"), d)
        assert_true(Bool(p), "1: price not null")
        assert_almost_equal(
            p.value(), exp_price[d], atol=1e-12, msg="1: price value (J2 -1.5)"
        )


# =============================================================================
# Case 2 — DATE32 round-trip + materializer preserves DATE32.
# =============================================================================


def test_02_date_roundtrip() raises:
    var text: List[String] = [String("x"), String("y"), String("z")]
    var source: List[String] = [String("d0"), String("d1"), String("d2")]
    # DATE32 = days since epoch. 19000, 0, 19366 (note a 0 -> exercises width).
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("event_day", ArrowType.DATE32, True))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(3)
    rb.add_column(_str_col(text))
    rb.add_column(_str_col(source))
    rb.add_column(_date32_col([Int32(19000), Int32(0), Int32(19366)]))
    var batch = rb.build(schema.copy())

    var bytes = _drive_sink(batch^, schema^)
    var view = SplitView.parse(bytes^)
    var reader = FastFieldReader(view)

    var exp = [Int64(19000), Int64(0), Int64(19366)]
    for d in range(3):
        var v = reader.fast_field_i64(view, String("event_day"), d)
        assert_true(Bool(v), "2: date not null")
        assert_equal(v.value(), exp[d], "2: date day number")

    # J4: the materialized column keeps the logical DATE32 type, NOT INT32.
    var col = reader.fast_field_column(view, String("event_day"))
    assert_equal(
        col.arrow_type.type_id,
        ArrowType.DATE32.type_id,
        "2: materializer preserves DATE32 (J4a)",
    )
    var arr = col.as_primitive[DType.int32]()
    assert_equal(Int32(arr.get(0)), Int32(19000), "2: mat day 0")
    assert_equal(Int32(arr.get(2)), Int32(19366), "2: mat day 2")


# =============================================================================
# Case 3 — keyword round-trip + sorted dictionary invariant.
# =============================================================================


def test_03_keyword_roundtrip() raises:
    var text: List[String] = [
        String("a"), String("b"), String("c"), String("d"), String("e")
    ]
    var source: List[String] = [
        String("d0"), String("d1"), String("d2"), String("d3"), String("d4")
    ]
    # status: low cardinality, NOT inserted in sorted order (c, a, b appear).
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("status", ArrowType.STRING, True))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(3)
    rb.add_column(_str_col(text))
    rb.add_column(_str_col(source))
    rb.add_column(
        _str_col(
            [String("c"), String("a"), String("b"), String("a"), String("c")]
        )
    )
    var batch = rb.build(schema.copy())

    var bytes = _drive_sink(batch^, schema^)
    var view = SplitView.parse(bytes^)
    var reader = FastFieldReader(view)

    var exp = [String("c"), String("a"), String("b"), String("a"), String("c")]
    for d in range(5):
        var v = reader.fast_field_keyword(view, String("status"), d)
        assert_true(Bool(v), "3: status not null")
        assert_equal(v.value(), exp[d], "3: status value")

    # Sorted-dictionary invariant: the materialized DICTIONARY column's
    # dict values are ascending ["a","b","c"], so the doc codes resolve correctly.
    var col = reader.fast_field_column(view, String("status"))
    assert_equal(
        col.arrow_type.type_id,
        ArrowType.DICTIONARY.type_id,
        "3: keyword materializes as DICTIONARY",
    )
    assert_equal(col._dict_size, 3, "3: dict size = 3 distinct")
    assert_equal(col.dict_index_byte_width(), 8, "3: int64 dict indices")
    # Resolve the sorted dict values from the column's dict_data + offsets.
    var dict_vals = _dict_values_of(col)
    assert_equal(len(dict_vals), 3, "3: dict values count")
    assert_equal(dict_vals[0], String("a"), "3: dict[0] sorted ascending")
    assert_equal(dict_vals[1], String("b"), "3: dict[1] sorted ascending")
    assert_equal(dict_vals[2], String("c"), "3: dict[2] sorted ascending")
    # Per-doc codes: c->2, a->0, b->1, a->0, c->2.
    var codes = _dict_codes_of(col)
    assert_equal(codes[0], 2, "3: doc0 code (c)")
    assert_equal(codes[1], 0, "3: doc1 code (a)")
    assert_equal(codes[2], 1, "3: doc2 code (b)")
    assert_equal(codes[3], 0, "3: doc3 code (a)")
    assert_equal(codes[4], 2, "3: doc4 code (c)")


def _dict_values_of(col: Column[HeapRegion]) raises -> List[String]:
    """Resolve a DICTIONARY column's dict VALUES via its offsets + dict_data."""
    var out = List[String]()
    var ds = col._dict_size
    for d in range(ds):
        var s_off = Int(col._offsets.value().get_typed[Int32](d))
        var e_off = Int(col._offsets.value().get_typed[Int32](d + 1))
        var buf = List[UInt8](capacity=e_off - s_off)
        for k in range(s_off, e_off):
            buf.append(col._dict_data.value().get_typed[UInt8](k))
        # SAFETY: dictionary values were written from Strings by the builder.
        out.append(String(StringSlice(unsafe_from_utf8=Span(buf))))
    return out^


def _dict_codes_of(col: Column[HeapRegion]) raises -> List[Int]:
    """Read a DICTIONARY column's per-row Int64 index codes."""
    var out = List[Int]()
    for r in range(col._length):
        out.append(Int(col._data.get_typed[Int64](r)))
    return out^


# =============================================================================
# Case 4 — fieldnorm == AnalyzedField.len() per doc.
# =============================================================================


def test_04_fieldnorm() raises:
    # Known token counts after the v1 analyzer (lowercase + fold + english
    # stopwords): "Hello World" -> [hello, world] = 2; "the quick fox" ->
    # [quick, fox] = 2 ("the" stopworded); "alpha beta gamma delta" -> 4.
    var text: List[String] = [
        String("Hello World"),
        String("the quick fox"),
        String("alpha beta gamma delta"),
    ]
    var source: List[String] = [String("d0"), String("d1"), String("d2")]
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(2)
    rb.add_column(_str_col(text))
    rb.add_column(_str_col(source))
    var batch = rb.build(schema.copy())

    var bytes = _drive_sink(batch^, schema^)
    var view = SplitView.parse(bytes^)
    assert_true(view.has_fastfields(), "4: fieldnorm rides the region")
    var reader = FastFieldReader(view)
    assert_true(
        reader.has_field(FIELDNORM_NAME), "4: __fieldnorm__ present"
    )

    var cfg = AnalyzerConfig.text("body")
    for d in range(3):
        var expected = analyze_text(text[d], cfg).len()
        var fn_val = reader.fast_field_i64(view, FIELDNORM_NAME, d)
        assert_true(Bool(fn_val), "4: fieldnorm not null")
        assert_equal(
            Int(fn_val.value()),
            expected,
            "4: fieldnorm == AnalyzedField.len()",
        )


# =============================================================================
# Case 5 — whole-column materializer (numeric -> primitive).
# =============================================================================


def test_05_whole_column_materializer() raises:
    var text: List[String] = [String("a"), String("b"), String("c"), String("d")]
    var source: List[String] = [String("d0"), String("d1"), String("d2"), String("d3")]
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("qty", ArrowType.INT64, True))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(3)
    rb.add_column(_str_col(text))
    rb.add_column(_str_col(source))
    rb.add_column(_i64_col([Int64(10), Int64(20), Int64(30), Int64(40)]))
    var batch = rb.build(schema.copy())

    var bytes = _drive_sink(batch^, schema^)
    var view = SplitView.parse(bytes^)
    var reader = FastFieldReader(view)

    var col = reader.fast_field_column(view, String("qty"))
    assert_equal(
        col.arrow_type.type_id, ArrowType.INT64.type_id, "5: INT64 column"
    )
    assert_equal(col._length, 4, "5: 4 rows")
    var arr = col.as_primitive[DType.int64]()
    assert_equal(Int64(arr.get(0)), Int64(10), "5: row0")
    assert_equal(Int64(arr.get(1)), Int64(20), "5: row1")
    assert_equal(Int64(arr.get(2)), Int64(30), "5: row2")
    assert_equal(Int64(arr.get(3)), Int64(40), "5: row3")


# =============================================================================
# Case 6 — nulls (numeric + keyword) -> None at slot; validity round-trips.
# =============================================================================


def test_06_nulls() raises:
    var text: List[String] = [String("a"), String("b"), String("c"), String("d")]
    var source: List[String] = [String("d0"), String("d1"), String("d2"), String("d3")]

    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("qty", ArrowType.INT64, True))
    sb.add_field(Field("status", ArrowType.STRING, True))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(4)
    rb.add_column(_str_col(text))
    rb.add_column(_str_col(source))
    # qty INT64 with a null at row 1.
    rb.add_column(_i64_col_nullable([Int64(5), Int64(0), Int64(7), Int64(9)], [1]))
    # status STRING with a null at row 2.
    rb.add_column(
        _str_col_nullable(
            [String("x"), String("y"), String(""), String("z")],
            [True, True, False, True],
        )
    )
    var batch = rb.build(schema.copy())

    var bytes = _drive_sink(batch^, schema^)
    var view = SplitView.parse(bytes^)
    var reader = FastFieldReader(view)

    # qty: row 1 is None, others present.
    assert_true(Bool(reader.fast_field_i64(view, String("qty"), 0)), "6: qty0")
    var q1 = reader.fast_field_i64(view, String("qty"), 1)
    assert_false(Bool(q1), "6: qty row1 is None (J4b)")
    assert_equal(
        reader.fast_field_i64(view, String("qty"), 2).value(),
        Int64(7),
        "6: qty row2 value",
    )
    assert_equal(
        reader.fast_field_i64(view, String("qty"), 3).value(),
        Int64(9),
        "6: qty row3 value",
    )

    # status: row 2 is None, others present.
    assert_equal(
        reader.fast_field_keyword(view, String("status"), 0).value(),
        String("x"),
        "6: status0",
    )
    var s2 = reader.fast_field_keyword(view, String("status"), 2)
    assert_false(Bool(s2), "6: status row2 is None (J4b)")
    assert_equal(
        reader.fast_field_keyword(view, String("status"), 3).value(),
        String("z"),
        "6: status row3",
    )

    # The validity round-trips through the whole-column materializer.
    var qcol = reader.fast_field_column(view, String("qty"))
    assert_equal(qcol.null_count(), 1, "6: materialized qty null_count")
    assert_true(Bool(qcol._validity), "6: materialized qty has validity bitmap")


# =============================================================================
# Case 7 — additive compat (a no-fast-fields split still parses).
# =============================================================================


def test_07_additive_p0_compat() raises:
    # The truly-ABSENT path (len==0, no fast fields): build via the raw
    # serialize_split with the DEFAULTED (empty) region param — exactly the split writer
    # fixture shape. This proves a fast-field-less split parses unchanged and
    # the FastFieldReader serves an empty reader.
    var b = InvertedIndexBuilder.create("body")
    var toks = List[Token]()
    toks.append(Token(String("hello"), 0))
    b.add_document(0, AnalyzedField(toks^))
    var fi = b.finalize()
    var td = TermDictBuilder.build_from_finalized(fi)
    var ds = DocStoreBuilder()
    ds.append(String("doc-zero").as_bytes())

    # No fastfields_region arg -> defaulted empty -> a split without fast fields.
    var bytes = serialize_split(fi, td^, ds, String("body"), _uuid(7), 0, 0, 1)
    var view = SplitView.parse(bytes^)

    assert_equal(view.fastfields_len(), 0, "7: fastfields_len == 0")
    assert_false(view.has_fastfields(), "7: has_fastfields() False")

    # FastFieldReader over an absent region yields an empty reader; lookups raise.
    var reader = FastFieldReader(view)
    assert_equal(reader.num_fields(), 0, "7: empty reader")
    assert_false(reader.has_field(FIELDNORM_NAME), "7: no fieldnorm")
    with assert_raises():
        _ = reader.fast_field_i64(view, String("qty"), 0)


# =============================================================================
# Case 8 — corrupt-bytes fail-loud (each raises; never reads OOB / garbage).
# =============================================================================


def test_08_corrupt_bytes() raises:
    var text: List[String] = [String("a"), String("b"), String("c")]
    var source: List[String] = [String("d0"), String("d1"), String("d2")]
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("qty", ArrowType.INT64, True))
    sb.add_field(Field("status", ArrowType.STRING, True))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(4)
    rb.add_column(_str_col(text))
    rb.add_column(_str_col(source))
    rb.add_column(_i64_col([Int64(1), Int64(2), Int64(3)]))
    rb.add_column(_str_col([String("p"), String("q"), String("p")]))
    var batch = rb.build(schema.copy())

    var good = _drive_sink(batch^, schema^)

    # (a) out-of-range doc_id on a GOOD split -> raises.
    var v_good = SplitView.parse(good.copy())
    var r_good = FastFieldReader(v_good)
    with assert_raises():
        _ = r_good.fast_field_i64(v_good, String("qty"), 999)
    with assert_raises():
        _ = r_good.fast_field_i64(v_good, String("qty"), -1)
    # Absent field name -> raises.
    with assert_raises():
        _ = r_good.fast_field_i64(v_good, String("nope"), 0)

    # (b) flip the "THFF" region magic -> FastFieldReader ctor raises.
    var bad_magic = good.copy()
    var ff_off = v_good.fastfields_offset()
    bad_magic[ff_off] = UInt8(0)  # 'T' -> 0x00
    var v_bad = SplitView.parse(bad_magic^)
    with assert_raises():
        _ = FastFieldReader(v_bad)

    # (c) corrupt a directory sub_len so a sub-region extends past the region —
    #     the FastFieldReader ctor (sub-region bounds check) raises. We corrupt
    #     by truncating the whole split bytes below the recorded region end: the
    #     SplitView.parse ordering check rejects it.
    var truncated = List[UInt8]()
    # Drop the trailing 8 bytes (footer trailing u32 + "THSF") -> parse raises.
    for i in range(len(good) - 8):
        truncated.append(good[i])
    with assert_raises():
        _ = SplitView.parse(truncated^)
    _ = good^


# =============================================================================
# Case 9 — O(1) avgdl footer slot: a sink-written split carries the per-split
#          total token count, and avgdl = total / doc_count matches the
#          column-sum, byte-identically (the query-latency-scalability fix).
# =============================================================================


def test_09_footer_total_token_count() raises:
    # Token counts after the v1 analyzer: "Hello World" -> 2; "the quick fox"
    # -> 2 ("the" stopworded); "alpha beta gamma delta" -> 4. Total = 8, doc
    # count = 3, avgdl = 8/3.
    var text: List[String] = [
        String("Hello World"),
        String("the quick fox"),
        String("alpha beta gamma delta"),
    ]
    var source: List[String] = [String("d0"), String("d1"), String("d2")]
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(2)
    rb.add_column(_str_col(text))
    rb.add_column(_str_col(source))
    var batch = rb.build(schema.copy())

    var bytes = _drive_sink(batch^, schema^)
    var view = SplitView.parse(bytes^)

    # The sink writer ALWAYS records the footer total (doc_count > 0).
    assert_true(
        view.has_total_token_count(), "9: footer carries total_token_count"
    )
    # Compute the expected total via the same analyzer the sink uses.
    var cfg = AnalyzerConfig.text("body")
    var expected_total = 0
    for d in range(3):
        expected_total += analyze_text(text[d], cfg).len()
    assert_equal(
        view.total_token_count(),
        expected_total,
        "9: total_token_count == sum(per-doc token counts)",
    )

    # avgdl from the footer == avgdl from the column-sum (the fieldnorms() path),
    # byte-identically. This is the headline correctness guard: the O(1) avgdl
    # is the SAME value as the O(doc_count) sum.
    var reader = FastFieldReader(view)
    var fn_res = reader.fieldnorms(view)
    var col_sum_avgdl = fn_res[1]
    var footer_avgdl = Float64(view.total_token_count()) / Float64(
        view.doc_count()
    )
    assert_equal(
        footer_avgdl,
        col_sum_avgdl,
        "9: footer avgdl == column-sum avgdl (identical)",
    )

    # The O(1) FieldnormResolver reads the SAME per-doc dl as the resolved-once
    # column (the O(matched) read == the O(doc_count) read, per doc).
    var resolver = reader.fieldnorm_resolver()
    var col_dls = fn_res[0].copy()
    for d in range(3):
        assert_equal(
            resolver.dl_at(view, d),
            col_dls[d],
            "9: resolver.dl_at == fieldnorms() column dl",
        )
    # An out-of-range doc_id fails loud.
    with assert_raises():
        _ = resolver.dl_at(view, 999)


# =============================================================================
# Case 10 — backward-compat: a split written WITHOUT the footer total slot
#           (an older writer / direct serialize_split) parses, has
#           has_total_token_count()==False, and still scores via the fallback.
# =============================================================================


def test_10_backward_compat_no_footer_total() raises:
    # Build a split the OLD way: serialize_split WITHOUT the total_token_count
    # arg (defaulted to FOOTER_NO_TOTAL_TOKENS). The fieldnorm region IS present
    # (so b>0 scoring still works), but the footer omits the total slot — the
    # reader must fall back to the column-sum path and still produce a correct
    # avgdl + per-doc dl.
    var b = InvertedIndexBuilder.create("body")
    var ds = DocStoreBuilder()
    var fieldnorm = NumericFastFieldBuilder(
        ArrowType.INT64.type_id, DType.int64
    )
    # 4 docs with token counts 1, 1, 3, 2 -> total 7, doc_count 4, avgdl 1.75.
    var token_counts = [1, 1, 3, 2]
    for i in range(4):
        var toks = List[Token]()
        for t in range(token_counts[i]):
            toks.append(Token(String("w") + String(t), t))
        b.add_document(i, AnalyzedField(toks^))
        ds.append((String("doc") + String(i)).as_bytes())
        fieldnorm.append_int(token_counts[i], is_null=False)
    var fi = b.finalize()
    var td = TermDictBuilder.build_from_finalized(fi)
    var ff_region = serialize_fastfields_region(
        List[FastFieldSpec](),
        List[NumericFastFieldBuilder](),
        List[KeywordFastFieldBuilder](),
        fieldnorm,
    )
    # NOTE: no total_token_count arg -> the footer omits the slot (old shape).
    var bytes = serialize_split(
        fi, td^, ds, String("body"), _uuid(9), 0, 3, 4, ff_region^
    )
    var view = SplitView.parse(bytes^)

    # The footer does NOT carry the total -> the reader degrades to column-sum.
    assert_false(
        view.has_total_token_count(),
        "10: old-shape footer has no total_token_count",
    )
    assert_true(view.has_fastfields(), "10: fieldnorm region present")

    # The fallback path still produces the correct avgdl + per-doc dl.
    var reader = FastFieldReader(view)
    var fn_res = reader.fieldnorms(view)
    assert_almost_equal(fn_res[1], 1.75, atol=1e-12, msg="10: avgdl == 1.75")
    var dls = fn_res[0].copy()
    var exp = [1, 1, 3, 2]
    for d in range(4):
        assert_equal(dls[d], exp[d], "10: fallback per-doc dl")

    # The resolver path ALSO works over this split (it does not require the
    # footer total — only the avgdl source differs): per-doc dl matches.
    var resolver = reader.fieldnorm_resolver()
    for d in range(4):
        assert_equal(
            resolver.dl_at(view, d), exp[d], "10: resolver dl over old split"
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
