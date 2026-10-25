# =============================================================================
# test_search_sort_pagination.mojo — P1.3 SORT + PAGINATION proof
# =============================================================================
#
# Source of truth: the search shim design notes
# (the Step-0 design) + the BINDING PRE-IMPL AMENDMENTS A1-A9 (folded into the
# impl; these SUPERSEDE the doc body).
#
# Engine-side unit suite over an IN-MEMORY split built by the P0.4 writer
# (SearchSink) + the P1.1 fast-fields — NO S3 / MinIO. Mirrors the P1.2
# test_search_filter_pushdown style. Covers:
#
#   1.  default _score desc unchanged (golden-pin — proves ZERO regression).
#   2.  _doc asc / desc (doc-id order).
#   3.  numeric fast-field asc / desc; _score column is still pure match score.
#   4.  keyword fast-field asc (byte-wise ascending).
#   5.  date fast-field desc (FIELD_CLASS_DATE over fast_field_i64).
#   6.  missing _last (default) — null sort cell sorts to the END for asc + desc.
#   7.  missing _first — the null doc sorts to the FRONT.
#   8.  doc_id tiebreak — equal sort keys order by ascending doc_id.
#   9.  from/size slice — from=2,size=2 over 5 -> indices 2,3; from>=total ->
#       empty; from=0 == full.
#   10. from+size with FF sort (sort=price desc, from=1, size=2 -> 2nd+3rd).
#   11. true total — total_matches==len(touched) regardless of page slice.
#   12. size=0 count-only (A6) — empty hits + the true total, no spurious hit.
#   (Case 13, the Searcher fingerprint distinctness of sort and from, runs with
#   the search runtime package, which this package's tests do not depend on.)
#   14. A3 eviction test — fill the heap to capacity then push lower-key
#       candidates; eviction honors the SORT KEY, not the score (would be
#       silent-wrong if push/_swap weren't routed through the mode-aware compare).
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_almost_equal,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.bitmap import Bitmap
from komira_buffer.heap_region import HeapRegion
from std.sys import size_of

from komira_search.analyzer import AnalyzerConfig
from komira_search.sink import SearchSink
from komira_search.split import SplitView
from komira_search.fast_fields import FastFieldReader
from komira_search.source import (
    QueryIR,
    SearchCore,
    SearchResult,
    hit_schema,
    SORT_DESC,
    SORT_ASC,
    MISSING_LAST,
    MISSING_FIRST,
    SORT_FIELD_SCORE,
    SORT_FIELD_DOC,
)

from komira_search_http.search_query import (
    search_json_to_queryir,
    parse_track_total_hits,
    sort_is_by_score,
)
from komira_search_http.search_gates import gate_sort_against_fastfields
from komira_search_http.envelopes import (
    hitbatch_to_hits_envelope,
    TRACK_TOTAL_TRUE,
    TRACK_TOTAL_FALSE,
    TRACK_TOTAL_DEFAULT,
)


# -----------------------------------------------------------------------------
# Fixture helpers (mirror test_search_filter_pushdown).
# -----------------------------------------------------------------------------


def _uuid(seed: UInt8) -> InlineArray[UInt8, 16]:
    var u = InlineArray[UInt8, 16](fill=0)
    for i in range(16):
        u[i] = seed + UInt8(i)
    return u^


def _text_cfg() -> AnalyzerConfig:
    return AnalyzerConfig.text("body")


def _str_col(values: List[String]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings(values))


def _i64_col(values: List[Int64]) raises -> Column[HeapRegion]:
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(values)
    )


def _f64_col(values: List[Float64]) raises -> Column[HeapRegion]:
    return Column.from_primitive[DType.float64](
        PrimitiveArray[DType.float64].from_list(values)
    )


def _date32_col(days: List[Int32]) raises -> Column[HeapRegion]:
    return Column.from_primitive_with_arrow_type[DType.int32](
        PrimitiveArray[DType.int32].from_list(days), ArrowType.DATE32
    )


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


def _drive_sink(
    var batch: RecordBatch, var schema: Schema, seed: UInt8
) raises -> List[UInt8]:
    var sink = SearchSink(
        String("bucket"),
        String("prefix"),
        String("idx"),
        String("body"),
        _uuid(seed),
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


# HitBatch column accessors (Float64 _score, Int64 _id, STRING _source).


def _score_at(batch: RecordBatch, row: Int) raises -> Float64:
    return Float64(batch.column_at(0).as_primitive[DType.float64]().get(row))


def _id_at(batch: RecordBatch, row: Int) raises -> Int64:
    return Int64(batch.column_at(1).as_primitive[DType.int64]().get(row))


def _ids(hits: RecordBatch) raises -> List[Int]:
    var out = List[Int]()
    for r in range(hits.num_rows()):
        out.append(Int(_id_at(hits, r)))
    return out^


def _result_ids(var result: SearchResult) raises -> List[Int]:
    """Extract the doc-id order from a SearchResult (RecordBatch is Movable-only,
    so the batch is taken out via the swap-then-move take_batch())."""
    var batch = result.take_batch()
    return _ids(batch)


def _assert_ids(got: List[Int], expect: List[Int], msg: String) raises:
    """Element-wise List[Int] equality (assert_equal has no List[Int] overload)."""
    assert_equal(len(got), len(expect), msg + " (length)")
    for i in range(len(expect)):
        assert_equal(got[i], expect[i], msg + " (index " + String(i) + ")")


# The standard fixture: every doc matches `match("alpha")`.
#   _source = "d<i>".
#   status KEYWORD; price INT64; rating FLOAT64; event_day DATE32.
def _fixture_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("status", ArrowType.STRING, True))  # keyword
    sb.add_field(Field("price", ArrowType.INT64, True))
    sb.add_field(Field("rating", ArrowType.FLOAT64, True))
    sb.add_field(Field("event_day", ArrowType.DATE32, True))
    return sb.build()


# 5 docs all containing "alpha" once (so the BM25 _score is byte-identical
# across all 5 — the sort key is the ONLY discriminator for the FF-sort cases):
#   doc0: status="cherry" price=150 rating=4.5 day=19300
#   doc1: status="apple"  price=50  rating=1.5 day=19000
#   doc2: status="banana" price=100 rating=3.5 day=19200
#   doc3: status="date"   price=100 rating=2.5 day=19100   <- price tie w/ doc2
#   doc4: status="egg"    price=200 rating=5.5 day=19400
def _build_fixture(seed: UInt8) raises -> List[UInt8]:
    var schema = _fixture_schema()
    var rb = RecordBatchBuilder.with_capacity(6)
    rb.add_column(_str_col([
        String("alpha"), String("alpha"), String("alpha"),
        String("alpha"), String("alpha"),
    ]))
    rb.add_column(_str_col([
        String("d0"), String("d1"), String("d2"), String("d3"), String("d4"),
    ]))
    rb.add_column(_str_col([
        String("cherry"), String("apple"), String("banana"),
        String("date"), String("egg"),
    ]))
    rb.add_column(_i64_col([
        Int64(150), Int64(50), Int64(100), Int64(100), Int64(200),
    ]))
    rb.add_column(_f64_col([
        Float64(4.5), Float64(1.5), Float64(3.5), Float64(2.5), Float64(5.5),
    ]))
    rb.add_column(_date32_col([
        Int32(19300), Int32(19000), Int32(19200), Int32(19100), Int32(19400),
    ]))
    var batch = rb.build(schema.copy())
    return _drive_sink(batch^, schema^, seed)


def _q(
    var sort_field: String,
    sort_order: UInt8 = SORT_ASC,
    missing_order: UInt8 = MISSING_LAST,
    from_offset: Int = 0,
    top_k: Int = 10,
) raises -> QueryIR:
    """Build a match("alpha") QueryIR with the given sort/page knobs (no
    filter)."""
    return QueryIR(
        String("body"), String("alpha"), top_k, _text_cfg(), 0,
        None, sort_field^, sort_order, missing_order, from_offset,
    )


# =============================================================================
# Case 1 — default _score desc unchanged (golden-pin; proves ZERO regression).
# =============================================================================


def test_01_default_score_desc_unchanged() raises:
    var bytes = _build_fixture(1)
    var core = SearchCore(bytes^)
    # sort_field="" -> SORT_MODE_SCORE, EXACTLY the pre-P1.3 path. All 5 docs
    # carry the same BM25 score (single-occurrence "alpha"), so the result is
    # purely the score-tie -> ascending doc_id ordering: [0,1,2,3,4].
    var q = QueryIR(String("body"), String("alpha"), 10, _text_cfg())
    var result = core.search(q)
    var ids = _ids(result.batch)
    assert_equal(len(ids), 5, "1: all 5 docs")
    for i in range(5):
        assert_equal(ids[i], i, "1: score-tie -> ascending doc_id (golden)")
    assert_equal(result.total_matches, 5, "1: true total")


# =============================================================================
# Case 2 — _doc asc / desc.
# =============================================================================


def test_02_doc_order() raises:
    var bytes = _build_fixture(2)
    var core = SearchCore(bytes^)
    var asc = _result_ids(core.search(_q(SORT_FIELD_DOC, SORT_ASC)))
    assert_equal(len(asc), 5)
    for i in range(5):
        assert_equal(asc[i], i, "2: _doc asc -> [0..4]")
    var desc = _result_ids(core.search(_q(SORT_FIELD_DOC, SORT_DESC)))
    for i in range(5):
        assert_equal(desc[i], 4 - i, "2: _doc desc -> [4..0]")


# =============================================================================
# Case 3 — numeric fast-field asc / desc; _score still pure match score.
# =============================================================================


def test_03_numeric_field_order() raises:
    var bytes = _build_fixture(3)
    var core = SearchCore(bytes^)
    # prices: d0=150 d1=50 d2=100 d3=100 d4=200.
    # asc: 50(d1) < 100(d2,d3 tie -> doc_id asc -> d2,d3) < 150(d0) < 200(d4).
    var asc_result = core.search(_q(String("price"), SORT_ASC))
    var asc_batch = asc_result.take_batch()
    var asc = _ids(asc_batch)
    _assert_ids(asc, [1, 2, 3, 0, 4], "3: price asc")
    # _score column is the PURE BM25 match score (sort does NOT alter scoring) —
    # all 5 single-occurrence docs share the same score.
    var s0 = _score_at(asc_batch, 0)
    for r in range(asc_batch.num_rows()):
        assert_almost_equal(
            _score_at(asc_batch, r), s0, msg="3: _score is pure match score"
        )
    assert_true(s0 > 0.0, "3: a positive match score")
    # desc: 200(d4) > 150(d0) > 100(d2,d3 -> doc_id asc) > 50(d1).
    var desc = _result_ids(core.search(_q(String("price"), SORT_DESC)))
    _assert_ids(desc, [4, 0, 2, 3, 1], "3: price desc")


# =============================================================================
# Case 4 — keyword fast-field asc (byte-wise ascending).
# =============================================================================


def test_04_keyword_field_asc() raises:
    var bytes = _build_fixture(4)
    var core = SearchCore(bytes^)
    # status: d0=cherry d1=apple d2=banana d3=date d4=egg.
    # asc byte-wise: apple(d1) < banana(d2) < cherry(d0) < date(d3) < egg(d4).
    var asc = _result_ids(core.search(_q(String("status"), SORT_ASC)))
    _assert_ids(asc, [1, 2, 0, 3, 4], "4: keyword asc")


# =============================================================================
# Case 5 — date fast-field desc (FIELD_CLASS_DATE over fast_field_i64).
# =============================================================================


def test_05_date_field_desc() raises:
    var bytes = _build_fixture(5)
    var core = SearchCore(bytes^)
    # days: d0=19300 d1=19000 d2=19200 d3=19100 d4=19400.
    # desc: 19400(d4) > 19300(d0) > 19200(d2) > 19100(d3) > 19000(d1).
    var desc = _result_ids(core.search(_q(String("event_day"), SORT_DESC)))
    _assert_ids(desc, [4, 0, 2, 3, 1], "5: date desc")


# =============================================================================
# Nullable fixture — for the missing-bucket + doc-id-tiebreak cases.
# =============================================================================
#
# 4 docs all matching "alpha":
#   doc0: price=100  (present)
#   doc1: price=NULL (missing)
#   doc2: price=100  (present; ties doc0)
#   doc3: price=200  (present)
def _build_null_fixture(seed: UInt8) raises -> List[UInt8]:
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("price", ArrowType.INT64, True))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(3)
    rb.add_column(_str_col([
        String("alpha"), String("alpha"), String("alpha"), String("alpha"),
    ]))
    rb.add_column(_str_col([
        String("d0"), String("d1"), String("d2"), String("d3"),
    ]))
    # price: d1 is NULL.
    rb.add_column(_i64_col_nullable(
        [Int64(100), Int64(0), Int64(100), Int64(200)], [1]
    ))
    var batch = rb.build(schema.copy())
    return _drive_sink(batch^, schema^, seed)


# =============================================================================
# Case 6 — missing _last (default): null sorts to the END for asc AND desc.
# =============================================================================


def test_06_missing_last() raises:
    var bytes = _build_null_fixture(6)
    var core = SearchCore(bytes^)
    # asc, missing _last: 100(d0,d2 -> doc_id asc) < 200(d3) < NULL(d1 last).
    var asc = _result_ids(core.search(_q(String("price"), SORT_ASC, MISSING_LAST)))
    assert_equal(len(asc), 4)
    assert_equal(asc[3], 1, "6: null sorts LAST (asc)")
    _assert_ids(asc, [0, 2, 3, 1], "6: missing-last asc")
    # desc, missing _last: 200(d3) > 100(d0,d2 -> doc_id asc) > NULL(d1 last).
    var desc = _result_ids(core.search(_q(String("price"), SORT_DESC, MISSING_LAST)))
    assert_equal(desc[3], 1, "6: null sorts LAST (desc) — a fixed end")
    _assert_ids(desc, [3, 0, 2, 1], "6: missing-last desc")


# =============================================================================
# Case 7 — missing _first: the null doc sorts to the FRONT.
# =============================================================================


def test_07_missing_first() raises:
    var bytes = _build_null_fixture(7)
    var core = SearchCore(bytes^)
    # asc, missing _first: NULL(d1 first) < 100(d0,d2) < 200(d3).
    var asc = _result_ids(core.search(_q(String("price"), SORT_ASC, MISSING_FIRST)))
    assert_equal(asc[0], 1, "7: null sorts FIRST (asc)")
    _assert_ids(asc, [1, 0, 2, 3], "7: missing-first asc")
    # desc, missing _first: NULL(d1 first) > 200(d3) > 100(d0,d2).
    var desc = _result_ids(core.search(_q(String("price"), SORT_DESC, MISSING_FIRST)))
    assert_equal(desc[0], 1, "7: null sorts FIRST (desc)")
    _assert_ids(desc, [1, 3, 0, 2], "7: missing-first desc")


# =============================================================================
# Case 8 — doc_id tiebreak (equal sort keys -> ascending doc_id).
# =============================================================================


def test_08_doc_id_tiebreak() raises:
    var bytes = _build_null_fixture(8)
    var core = SearchCore(bytes^)
    # d0 and d2 both price==100. Whatever the order, the equal-key pair MUST be
    # in ascending doc_id (d0 before d2) — deterministic.
    var asc = _result_ids(core.search(_q(String("price"), SORT_ASC, MISSING_LAST)))
    # find positions of d0 and d2.
    var p0 = -1
    var p2 = -1
    for i in range(len(asc)):
        if asc[i] == 0:
            p0 = i
        elif asc[i] == 2:
            p2 = i
    assert_true(p0 >= 0 and p2 >= 0, "8: both tied docs present")
    assert_true(p0 < p2, "8: equal keys -> ascending doc_id (d0 before d2)")
    # And under DESC the tie STILL breaks ascending doc_id (the tiebreak is a
    # fixed final order, not order-flipped).
    var desc = _result_ids(core.search(_q(String("price"), SORT_DESC, MISSING_LAST)))
    var q0 = -1
    var q2 = -1
    for i in range(len(desc)):
        if desc[i] == 0:
            q0 = i
        elif desc[i] == 2:
            q2 = i
    assert_true(q0 < q2, "8: equal keys -> ascending doc_id under desc too")


# =============================================================================
# Case 9 — from/size slice (from=2,size=2 over 5 -> indices 2,3; from>=total
# -> empty; from=0 == full).
# =============================================================================


def test_09_from_size_slice() raises:
    var bytes = _build_fixture(9)
    var core = SearchCore(bytes^)
    # Full _doc asc order is [0,1,2,3,4]. from=2,size=2 -> [2,3].
    var page = _result_ids(
        core.search(_q(SORT_FIELD_DOC, SORT_ASC, MISSING_LAST, 2, 2))
    )
    _assert_ids(page, [2, 3], "9: from=2,size=2 -> [2,3]")
    # from >= total -> empty page (still 0-row schema-valid).
    var empty_result = core.search(
        _q(SORT_FIELD_DOC, SORT_ASC, MISSING_LAST, 99, 2)
    )
    assert_equal(empty_result.batch.num_rows(), 0, "9: from>=total -> empty")
    assert_equal(empty_result.batch.num_columns(), 3, "9: schema intact")
    assert_equal(empty_result.total_matches, 5, "9: true total still 5")
    # from=0 == full build.
    var full = _result_ids(
        core.search(_q(SORT_FIELD_DOC, SORT_ASC, MISSING_LAST, 0, 10))
    )
    _assert_ids(full, [0, 1, 2, 3, 4], "9: from=0 -> full")


# =============================================================================
# Case 10 — from+size with fast-field sort.
# =============================================================================


def test_10_from_size_with_ff_sort() raises:
    var bytes = _build_fixture(10)
    var core = SearchCore(bytes^)
    # price desc full order: [4(200),0(150),2(100),3(100),1(50)].
    # from=1,size=2 -> the 2nd+3rd: [0,2].
    var page = _result_ids(
        core.search(_q(String("price"), SORT_DESC, MISSING_LAST, 1, 2))
    )
    _assert_ids(page, [0, 2], "10: price desc from=1 size=2 -> [0,2]")


# =============================================================================
# Case 11 — true total (page < total, total_matches == len(touched)).
# =============================================================================


def test_11_true_total() raises:
    var bytes = _build_fixture(11)
    var core = SearchCore(bytes^)
    # 5 matches, size=2 -> a 2-hit page but total_matches == 5.
    var result = core.search(_q(String("price"), SORT_ASC, MISSING_LAST, 0, 2))
    assert_equal(result.batch.num_rows(), 2, "11: page has size=2 rows")
    assert_equal(result.total_matches, 5, "11: total_matches is the true total")


# =============================================================================
# Case 12 — size=0 count-only (A6): empty hits + true total, no spurious hit.
# =============================================================================


def test_12_size_zero_count_only() raises:
    var bytes = _build_fixture(12)
    var core = SearchCore(bytes^)
    # from=0,size=0 -> empty hits array, the true total. The heap-capacity clamp
    # (window<=0 -> cap 1) MUST NOT leak one spurious hit.
    var result = core.search(_q(String("price"), SORT_ASC, MISSING_LAST, 0, 0))
    assert_equal(result.batch.num_rows(), 0, "12: size=0 -> ZERO hits")
    assert_equal(result.batch.num_columns(), 3, "12: schema intact")
    assert_equal(result.total_matches, 5, "12: true total surfaced")
    # The default _score path with size=0 also returns no spurious hit.
    var score0 = core.search(
        QueryIR(String("body"), String("alpha"), 0, _text_cfg())
    )
    assert_equal(score0.batch.num_rows(), 0, "12: score sort size=0 -> ZERO")
    assert_equal(score0.total_matches, 5, "12: score sort true total")


# =============================================================================
# Case 14 — A3 eviction: full heap eviction honors the SORT KEY, not score.
# =============================================================================


def test_14_eviction_honors_sort_key() raises:
    # All docs carry the SAME BM25 score (single "alpha"), so if push/_swap's
    # root-evict comparison wrongly ran on SCORE (the pre-P1.3 inlined compare),
    # the retained top-k would be a doc_id-arbitrary subset rather than the
    # smallest sort keys. We sort price ASC with size=2 (capacity 2), so the
    # heap must EVICT to keep only the 2 SMALLEST prices: d1(50) and a 100-doc.
    var bytes = _build_fixture(14)
    var core = SearchCore(bytes^)
    # prices: d0=150 d1=50 d2=100 d3=100 d4=200. The 2 smallest are 50(d1) and
    # 100 (d2,d3 -> d2 by doc_id). With capacity=2 the heap must retain {d1,d2}.
    var page = _result_ids(
        core.search(_q(String("price"), SORT_ASC, MISSING_LAST, 0, 2))
    )
    _assert_ids(page, [1, 2], "14: size=2 retains the 2 SMALLEST keys")
    # Mirror desc: the 2 LARGEST prices are 200(d4) and 150(d0).
    var page_d = _result_ids(
        core.search(_q(String("price"), SORT_DESC, MISSING_LAST, 0, 2))
    )
    _assert_ids(page_d, [4, 0], "14: desc retains the 2 LARGEST keys")


# =============================================================================
# Shim helpers.
# =============================================================================


def _qir(body: String) raises -> QueryIR:
    return search_json_to_queryir(Span(body.as_bytes()), Int64(0))


def _make_hitbatch(
    scores: List[Float64], ids: List[Int64], sources: List[String]
) raises -> RecordBatch:
    var sa = PrimitiveArray[DType.float64].from_list(scores)
    var ia = PrimitiveArray[DType.int64].from_list(ids)
    var srca = StringArray.from_strings(sources)
    var rb = RecordBatchBuilder.with_capacity(3)
    rb.add_column(Column.from_primitive[DType.float64](sa))
    rb.add_column(Column.from_primitive[DType.int64](ia))
    rb.add_column(Column.from_string(srca^))
    return rb.build(hit_schema())


# =============================================================================
# Shim Case 15 — each sort element form -> the right (field, order, missing).
# =============================================================================


def test_15_shim_sort_element_forms() raises:
    # bare "price" -> (price, asc, last).
    var q1 = _qir(String('{"query":{"match":{"body":"alpha"}},"sort":["price"]}'))
    assert_equal(q1.sort_field, String("price"), "15: bare field")
    assert_equal(Int(q1.sort_order), Int(SORT_ASC), "15: bare -> asc default")
    assert_equal(Int(q1.missing_order), Int(MISSING_LAST), "15: default last")

    # {"price":{"order":"desc"}} -> (price, desc, last).
    var q2 = _qir(String(
        '{"query":{"match":{"body":"alpha"}},'
        '"sort":[{"price":{"order":"desc"}}]}'
    ))
    assert_equal(q2.sort_field, String("price"))
    assert_equal(Int(q2.sort_order), Int(SORT_DESC), "15: explicit desc")

    # {"price":"desc"} shorthand -> (price, desc, last).
    var q3 = _qir(String(
        '{"query":{"match":{"body":"alpha"}},"sort":[{"price":"desc"}]}'
    ))
    assert_equal(q3.sort_field, String("price"))
    assert_equal(Int(q3.sort_order), Int(SORT_DESC), "15: shorthand desc")

    # {"date":{"order":"asc","missing":"_first"}} -> (date, asc, first).
    var q4 = _qir(String(
        '{"query":{"match":{"body":"alpha"}},'
        '"sort":[{"date":{"order":"asc","missing":"_first"}}]}'
    ))
    assert_equal(q4.sort_field, String("date"))
    assert_equal(Int(q4.sort_order), Int(SORT_ASC))
    assert_equal(Int(q4.missing_order), Int(MISSING_FIRST), "15: missing _first")

    # "_score" -> (_score, desc).
    var q5 = _qir(String(
        '{"query":{"match":{"body":"alpha"}},"sort":["_score"]}'
    ))
    assert_equal(q5.sort_field, SORT_FIELD_SCORE)
    assert_equal(Int(q5.sort_order), Int(SORT_DESC), "15: _score -> desc")

    # "_doc" -> (_doc, asc).
    var q6 = _qir(String(
        '{"query":{"match":{"body":"alpha"}},"sort":["_doc"]}'
    ))
    assert_equal(q6.sort_field, SORT_FIELD_DOC)
    assert_equal(Int(q6.sort_order), Int(SORT_ASC), "15: _doc -> asc")


# =============================================================================
# Shim Case 16 — from/size parse; from<0 -> 400; from+size>10000 -> 400.
# =============================================================================


def test_16_shim_from_size() raises:
    var q = _qir(String(
        '{"query":{"match":{"body":"alpha"}},"from":5,"size":3}'
    ))
    assert_equal(q.from_offset, 5, "16: from parsed")
    assert_equal(q.top_k, 3, "16: size parsed")

    # from < 0 -> 400.
    var threw_neg = False
    try:
        var _bad = _qir(String(
            '{"query":{"match":{"body":"alpha"}},"from":-1}'
        ))
    except:
        threw_neg = True
    assert_true(threw_neg, "16: from<0 -> 400")

    # from + size > 10000 -> 400 (max_result_window).
    var threw_window = False
    try:
        var _bad2 = _qir(String(
            '{"query":{"match":{"body":"alpha"}},"from":9999,"size":2}'
        ))
    except:
        threw_window = True
    assert_true(threw_window, "16: from+size>10000 -> 400")


# =============================================================================
# Shim Case 17 — multi-level / search_after -> 400.
# =============================================================================


def test_17_shim_structural_400() raises:
    # multi-level sort -> 400 (NOT silent-truncate).
    var threw_multi = False
    try:
        var _q = _qir(String(
            '{"query":{"match":{"body":"alpha"}},"sort":["a","b"]}'
        ))
    except:
        threw_multi = True
    assert_true(threw_multi, "17: multi-level sort -> 400")

    # search_after -> 400 (DEFER).
    var threw_after = False
    try:
        var _q2 = _qir(String(
            '{"query":{"match":{"body":"alpha"}},"search_after":[5]}'
        ))
    except:
        threw_after = True
    assert_true(threw_after, "17: search_after -> 400")


# =============================================================================
# Shim Case 18 — sort gate: non-fast-field / TEXT -> 400; _score/_doc allowed.
# =============================================================================


def test_18_shim_sort_gate() raises:
    var bytes = _build_fixture(18)
    var view = SplitView.parse(bytes.copy())
    var reader = FastFieldReader(view)

    # _score / _doc / "" are always allowed (no raise). The gate now RETURNS the
    # (possibly `.keyword`-resolved) query — discard it here.
    _ = gate_sort_against_fastfields(_q(String("")), reader)
    _ = gate_sort_against_fastfields(_q(SORT_FIELD_SCORE, SORT_DESC), reader)
    _ = gate_sort_against_fastfields(_q(SORT_FIELD_DOC, SORT_ASC), reader)
    # A valid fast-field sort passes.
    _ = gate_sort_against_fastfields(_q(String("price")), reader)

    # TEXT-field sort ("body" is the matched text field — only in the inverted
    # index) -> 400.
    var threw_text = False
    try:
        _ = gate_sort_against_fastfields(_q(String("body")), reader)
    except:
        threw_text = True
    assert_true(threw_text, "18: sort on text/non-fast-field -> 400")

    # non-existent field -> 400.
    var threw_absent = False
    try:
        _ = gate_sort_against_fastfields(_q(String("nonexistent")), reader)
    except:
        threw_absent = True
    assert_true(threw_absent, "18: sort on absent field -> 400")


# =============================================================================
# Shim Case 19 — envelope total = total_matches (NOT page size); cap -> gte.
# =============================================================================


def test_19_envelope_total() raises:
    # A 2-row page but total_matches == 7: render value 7 (the true total), NOT
    # the page row count (the pre-P1.3 bug).
    var scores: List[Float64] = [1.5, 0.9]
    var ids: List[Int64] = [Int64(0), Int64(1)]
    var sources: List[String] = [
        String('{"body":"a"}'), String('{"body":"b"}'),
    ]
    var hb = _make_hitbatch(scores, ids, sources)
    var env = hitbatch_to_hits_envelope(
        hb, String("docs"), List[String](), 7, TRACK_TOTAL_DEFAULT, True
    )
    assert_true(
        env.find('"total":{"value":7,"relation":"eq"}') >= 0,
        "19: total = total_matches (7), not page size (2)",
    )

    # Cap: total_matches > 10000 -> value 10000, relation gte (default mode).
    var hb2 = _make_hitbatch(scores, ids, sources)
    var env_cap = hitbatch_to_hits_envelope(
        hb2, String("docs"), List[String](), 50000, TRACK_TOTAL_DEFAULT, True
    )
    assert_true(
        env_cap.find('"total":{"value":10000,"relation":"gte"}') >= 0,
        "19: >10000 caps + flips relation gte",
    )


# =============================================================================
# Shim Case 20 — track_total_hits true / false / default rendering.
# =============================================================================


def test_20_envelope_track_total_modes() raises:
    var scores: List[Float64] = [1.5]
    var ids: List[Int64] = [Int64(0)]
    var sources: List[String] = [String('{"body":"a"}')]

    # true: exact value, relation always eq (even above the cap).
    var hb_t = _make_hitbatch(scores, ids, sources)
    var env_t = hitbatch_to_hits_envelope(
        hb_t, String("docs"), List[String](), 50000, TRACK_TOTAL_TRUE, True
    )
    assert_true(
        env_t.find('"total":{"value":50000,"relation":"eq"}') >= 0,
        "20: track_total true -> exact eq (no cap)",
    )

    # false: the hits.total object is OMITTED entirely (not value:0). NOTE the
    # static _shards object also carries a `"total":1` member, so the omission
    # check targets the hits.total OBJECT shape ('"total":{') specifically.
    var hb_f = _make_hitbatch(scores, ids, sources)
    var env_f = hitbatch_to_hits_envelope(
        hb_f, String("docs"), List[String](), 50000, TRACK_TOTAL_FALSE, True
    )
    assert_true(
        env_f.find('"total":{') < 0,
        "20: track_total false -> hits.total OMITTED",
    )
    assert_true(
        env_f.find('"value":50000') < 0,
        "20: track_total false -> no leaked total value",
    )

    # default with a small total: exact eq.
    var hb_d = _make_hitbatch(scores, ids, sources)
    var env_d = hitbatch_to_hits_envelope(
        hb_d, String("docs"), List[String](), 5, TRACK_TOTAL_DEFAULT, True
    )
    assert_true(
        env_d.find('"total":{"value":5,"relation":"eq"}') >= 0,
        "20: default small total -> exact eq",
    )


# =============================================================================
# Shim Case 21 — max_score null under field sort (A7).
# =============================================================================


def test_21_envelope_max_score_field_sort() raises:
    var scores: List[Float64] = [1.5, 0.9]
    var ids: List[Int64] = [Int64(0), Int64(1)]
    var sources: List[String] = [
        String('{"body":"a"}'), String('{"body":"b"}'),
    ]
    # sorted_by_score True -> max_score is the top score.
    var hb_s = _make_hitbatch(scores, ids, sources)
    var env_s = hitbatch_to_hits_envelope(
        hb_s, String("docs"), List[String](), 2, TRACK_TOTAL_DEFAULT, True
    )
    assert_true(env_s.find('"max_score":1.5') >= 0, "21: score sort -> top score")

    # sorted_by_score False (a field sort) -> max_score null (A7).
    var hb_f = _make_hitbatch(scores, ids, sources)
    var env_f = hitbatch_to_hits_envelope(
        hb_f, String("docs"), List[String](), 2, TRACK_TOTAL_DEFAULT, False
    )
    assert_true(env_f.find('"max_score":null') >= 0, "21: field sort -> null")

    # sort_is_by_score: "" and "_score" -> True; a field -> False.
    assert_true(sort_is_by_score(_q(String(""))), "21: '' is score sort")
    assert_true(sort_is_by_score(_q(SORT_FIELD_SCORE, SORT_DESC)), "21: _score")
    assert_false(sort_is_by_score(_q(String("price"))), "21: field NOT score")


# =============================================================================
# Shim Case 22 — track_total_hits body parse (true/false/default).
# =============================================================================


def test_22_parse_track_total_hits() raises:
    var t = parse_track_total_hits(Span(String(
        '{"query":{"match":{"body":"a"}},"track_total_hits":true}'
    ).as_bytes()))
    assert_equal(Int(t), Int(TRACK_TOTAL_TRUE), "22: true")
    var f = parse_track_total_hits(Span(String(
        '{"query":{"match":{"body":"a"}},"track_total_hits":false}'
    ).as_bytes()))
    assert_equal(Int(f), Int(TRACK_TOTAL_FALSE), "22: false")
    var d = parse_track_total_hits(Span(String(
        '{"query":{"match":{"body":"a"}}}'
    ).as_bytes()))
    assert_equal(Int(d), Int(TRACK_TOTAL_DEFAULT), "22: absent -> default")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
