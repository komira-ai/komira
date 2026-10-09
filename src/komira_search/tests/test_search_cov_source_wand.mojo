# =============================================================================
# test_search_cov_source_wand.mojo: the three scorers (brute, WAND, BMW) on
# splits that reach their rarer arms.
# =============================================================================
#
#   1. A split whose postings name a doc-id past its doc_count is refused by
#      the brute walk, the WAND merge and the BMW merge, each naming the doc.
#   2. BMW over a skewed query whose common term has a second block that cannot
#      reach theta: that block is decoded doc-ids only, and the result (rows,
#      scores, total) equals the brute walk's.
#   3. BMW over the same split with the rare term's posting count set to 0 on
#      disk: the term is treated as exhausted, and the result still equals the
#      brute walk's over the same bytes.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray

from komira_search.analyzer import AnalyzerConfig, AnalyzedField, Token
from komira_search.inverted import InvertedIndexBuilder
from komira_search.term_dict import TermDictBuilder, TermDictionary
from komira_search.split import SplitView, serialize_split, DocStoreBuilder
from komira_search.sink import SearchSink
from komira_search.source import QueryIR, SearchCore, SearchResult


def _q(text: String, top_k: Int) -> QueryIR:
    return QueryIR(String("body"), text.copy(), top_k, AnalyzerConfig.text("body"))


def _short_split(n: Int, doc_count: Int, blockmax: Bool) raises -> List[UInt8]:
    """`n` docs indexed (doc 0 holds "r c", the rest "c"), but the header and
    footer claim `doc_count` docs."""
    var b = InvertedIndexBuilder.create("body")
    var ds = DocStoreBuilder(compress=False)
    var counts = List[Int]()
    for d in range(n):
        var toks = List[Token]()
        if d == 0:
            toks.append(Token(String("r"), 0))
        toks.append(Token(String("c"), len(toks)))
        counts.append(len(toks))
        b.add_document(d, AnalyzedField(toks^))
        ds.append(String("d").as_bytes())
    var fi = b.finalize()
    var total = 0
    for i in range(len(counts)):
        total += counts[i]
    if not blockmax:
        counts.clear()
    return serialize_split(
        fi, TermDictBuilder.build_from_finalized(fi), ds, String("body"),
        Array[UInt8, 16](fill=4), 0, doc_count - 1, doc_count,
        total_token_count=total, token_counts=counts^,
    )


def test_01_doc_id_past_doc_count() raises:
    var brute = SearchCore(_short_split(3, 1, False))
    with assert_raises(contains="SearchCore.search: posting doc_id 1 maps to out-of-range slot 1"):
        _ = brute.search_no_wand(_q("c", 10))
    with assert_raises(contains="_wand_accumulate: posting doc_id 1 maps to out-of-range slot 1"):
        _ = brute.search(_q("r c", 10))
    var bmw = SearchCore(_short_split(20, 2, True))
    with assert_raises(contains="_bmw_accumulate: posting doc_id 2 maps to out-of-range slot 2"):
        _ = bmw.search_bmw(_q("r c", 10))


def _skewed_split() raises -> List[UInt8]:
    """200 docs of six tokens: doc 0 is "r c c c c c", the others "c x x x x x"
    (block 0 of "c" holds tf 5; block 1, docs 128..199, holds tf 1 only)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    var schema = sb.build()
    var body = List[String]()
    var src = List[String]()
    for d in range(200):
        body.append(String("r c c c c c") if d == 0 else String("c x x x x x"))
        src.append(String("s") + String(d))
    var rb = RecordBatchBuilder.with_capacity(2)
    rb.add_column(Column.from_string(StringArray.from_strings(body)))
    rb.add_column(Column.from_string(StringArray.from_strings(src)))
    var batch = rb.build(schema.copy())
    var sink = SearchSink(
        String("b"), String("p"), String("i"), String("body"), Array[UInt8, 16](fill=5)
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


def _same(a: SearchResult, b: SearchResult, ctx: String) raises:
    assert_equal(a.total_matches, b.total_matches, ctx + ": total")
    assert_equal(a.batch.num_rows(), b.batch.num_rows(), ctx + ": rows")
    var ia = a.batch.column_at(1).as_primitive[DType.int64]()
    var ib = b.batch.column_at(1).as_primitive[DType.int64]()
    var sa = a.batch.column_at(0).as_primitive[DType.float64]()
    var sbb = b.batch.column_at(0).as_primitive[DType.float64]()
    for i in range(a.batch.num_rows()):
        assert_equal(ia.get(i), ib.get(i), ctx + ": id row " + String(i))
        assert_equal(sa.get(i), sbb.get(i), ctx + ": score row " + String(i))


def test_02_bmw_skips_a_block_decode() raises:
    var core = SearchCore(_skewed_split())
    for k in [1, 3]:
        var bmw = core.search_bmw(_q("r c", k))
        var brute = core.search_no_wand(_q("r c", k))
        _same(bmw, brute, "2: k=" + String(k))
        assert_equal(bmw.total_matches, 200, "2: every doc matches c")
        assert_equal(
            Int(bmw.batch.column_at(1).as_primitive[DType.int64]().get(0)), 0,
            "2: doc 0 leads",
        )


def test_03_bmw_term_with_no_postings() raises:
    var bytes = _skewed_split()
    var view = SplitView.parse(bytes.copy())
    var td_bytes = List[UInt8]()
    for b in view.term_dict_region():
        td_bytes.append(b)
    var td = TermDictionary.deserialize(td_bytes^)
    var r: List[UInt8] = [0x72]
    var info = td.lookup_info(Span(r))
    var at = view.postings_offset() + info.value().posting_offset
    assert_equal(Int(bytes[at]), 1, "3: r's doc count on disk is 1")
    bytes[at] = 0
    var core = SearchCore(bytes^)
    var bmw = core.search_bmw(_q("r c", 1))
    var brute = core.search_no_wand(_q("r c", 1))
    _same(bmw, brute, "3")
    assert_equal(bmw.total_matches, 200, "3: c still matches every doc")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
