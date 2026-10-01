# =============================================================================
# test_search_inverted.mojo — the inverted-index unit test
# =============================================================================
#
# A 10-case test plan, plus the A1
# salt-sentinel regression test (a term whose FNV hash has top-16 bits == 0,
# inserted as the FIRST term => term_id 0, must be FOUND not lost/duplicated)
# and the case-8 FNV known-answer test.
#
# Coverage (enumerated cases):
#   1.  single-doc, single-term
#   2.  single-doc, repeated term (TF counting)
#   3.  multi-doc accumulation + doc-freq
#   4.  cross-doc TF + ascending doc-ids
#   5.  sorted drain (ordinal == lexicographic, NOT insertion order)
#   6.  empty field / finalize-then-add raises / zero-doc clean finalize
#   7.  128-doc block boundary (in-memory shape that feeds the split writer transform)
#   8.  FNV cross-check (the fnv1a_64_over_bytes export) — known answers
#   9.  hash-collision tiebreak (distinct terms stay distinct under probing)
#   10. add_text_column driver (the Arrow seam)
#   A1. salt-sentinel regression (top-16-bits-zero hash as term_id 0)
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.collections.batch_view import batch_view_over

from komira_eval import fnv1a_64_over_bytes

from komira_search.analyzer import (
    AnalyzedField,
    AnalyzerConfig,
    Token,
    FIELD_CLASS_TEXT,
)
from komira_search.inverted import (
    InvertedIndexBuilder,
    FinalizedIndex,
    TermEntry,
)


# -----------------------------------------------------------------------------
# Test helpers
# -----------------------------------------------------------------------------


def _af(terms: List[String]) -> AnalyzedField:
    """Build an AnalyzedField from a flat list of term strings (positions
    assigned in emission order). The analyzer is bypassed here — these unit
    tests drive the BUILDER directly with synthetic token multisets."""
    var toks = List[Token]()
    for i in range(len(terms)):
        toks.append(Token(terms[i], i))
    return AnalyzedField(toks^)


def _span_to_list(s: Span[Int, _]) -> List[Int]:
    var out = List[Int]()
    for i in range(len(s)):
        out.append(s[i])
    return out^


def _bytes_to_string(s: Span[UInt8, _]) -> String:
    var buf = List[UInt8]()
    for i in range(len(s)):
        buf.append(s[i])
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


def _assert_int_list(
    got: List[Int], expected: List[Int], ctx: String
) raises:
    assert_equal(
        len(got),
        len(expected),
        ctx + ": len " + String(len(got)) + " != " + String(len(expected)),
    )
    for i in range(len(expected)):
        assert_equal(got[i], expected[i], ctx + "[" + String(i) + "]")


# Find the ordinal of a term by its bytes in a FinalizedIndex (lex-ordinal
# random access). Returns -1 if absent.
def _ordinal_of(idx: FinalizedIndex, term: String) raises -> Int:
    for o in range(idx.num_terms()):
        if _bytes_to_string(idx.term_bytes_at(o)) == term:
            return o
    return -1


# -----------------------------------------------------------------------------
# 1. Single-doc, single-term
# -----------------------------------------------------------------------------


def test_01_single_doc_single_term() raises:
    var b = InvertedIndexBuilder.create("body")
    b.add_document(0, _af([String("hello")]))
    var idx = b.finalize()
    assert_equal(idx.num_terms(), 1, "1: num_terms")
    assert_equal(_bytes_to_string(idx.term_bytes_at(0)), String("hello"), "1: term")
    assert_equal(idx.doc_freq_at(0), 1, "1: doc_freq")
    _assert_int_list(
        _span_to_list(idx.posting_doc_ids_at(0)), [0], "1: doc_ids"
    )
    _assert_int_list(_span_to_list(idx.posting_tfs_at(0)), [1], "1: tfs")


# -----------------------------------------------------------------------------
# 2. Single-doc, repeated term (TF counting)
# -----------------------------------------------------------------------------


def test_02_repeated_term_tf() raises:
    var b = InvertedIndexBuilder.create("body")
    # tokens ["fox","fox","quick"] -> fox tf=2, quick tf=1, both doc_freq=1.
    b.add_document(
        0, _af([String("fox"), String("fox"), String("quick")])
    )
    var idx = b.finalize()
    assert_equal(idx.num_terms(), 2, "2: num_terms")
    var o_fox = _ordinal_of(idx, "fox")
    var o_quick = _ordinal_of(idx, "quick")
    assert_true(o_fox >= 0 and o_quick >= 0, "2: both terms present")
    assert_equal(idx.doc_freq_at(o_fox), 1, "2: fox doc_freq")
    assert_equal(idx.doc_freq_at(o_quick), 1, "2: quick doc_freq")
    _assert_int_list(_span_to_list(idx.posting_tfs_at(o_fox)), [2], "2: fox tf")
    _assert_int_list(
        _span_to_list(idx.posting_tfs_at(o_quick)), [1], "2: quick tf"
    )
    _assert_int_list(
        _span_to_list(idx.posting_doc_ids_at(o_fox)), [0], "2: fox doc_id"
    )


# -----------------------------------------------------------------------------
# 3. Multi-doc accumulation + doc-freq
# -----------------------------------------------------------------------------


def test_03_multi_doc_accumulation() raises:
    var b = InvertedIndexBuilder.create("body")
    b.add_document(0, _af([String("a"), String("b")]))
    b.add_document(1, _af([String("a")]))
    b.add_document(2, _af([String("a"), String("b")]))
    var idx = b.finalize()
    assert_equal(idx.num_terms(), 2, "3: num_terms")
    var oa = _ordinal_of(idx, "a")
    var ob = _ordinal_of(idx, "b")
    assert_equal(idx.doc_freq_at(oa), 3, "3: a doc_freq")
    _assert_int_list(
        _span_to_list(idx.posting_doc_ids_at(oa)), [0, 1, 2], "3: a doc_ids"
    )
    _assert_int_list(
        _span_to_list(idx.posting_tfs_at(oa)), [1, 1, 1], "3: a tfs"
    )
    assert_equal(idx.doc_freq_at(ob), 2, "3: b doc_freq")
    _assert_int_list(
        _span_to_list(idx.posting_doc_ids_at(ob)), [0, 2], "3: b doc_ids"
    )
    _assert_int_list(_span_to_list(idx.posting_tfs_at(ob)), [1, 1], "3: b tfs")


# -----------------------------------------------------------------------------
# 4. Cross-doc TF + ascending doc-ids
# -----------------------------------------------------------------------------


def test_04_cross_doc_tf_ascending() raises:
    var b = InvertedIndexBuilder.create("body")
    # term "a": tf=3 in doc 5, tf=1 in doc 9, tf=2 in doc 40 (added in order).
    b.add_document(5, _af([String("a"), String("a"), String("a")]))
    b.add_document(9, _af([String("a")]))
    b.add_document(40, _af([String("a"), String("a")]))
    var idx = b.finalize()
    assert_equal(idx.num_terms(), 1, "4: num_terms")
    assert_equal(idx.doc_freq_at(0), 3, "4: doc_freq")
    _assert_int_list(
        _span_to_list(idx.posting_doc_ids_at(0)), [5, 9, 40], "4: doc_ids"
    )
    _assert_int_list(_span_to_list(idx.posting_tfs_at(0)), [3, 1, 2], "4: tfs")


# -----------------------------------------------------------------------------
# 5. Sorted drain (ordinal == lexicographic, NOT insertion order)
# -----------------------------------------------------------------------------


def test_05_sorted_drain_lexicographic() raises:
    var b = InvertedIndexBuilder.create("body")
    # Insert in NON-sorted order: zebra, apple, mango.
    b.add_document(0, _af([String("zebra")]))
    b.add_document(1, _af([String("apple")]))
    b.add_document(2, _af([String("mango")]))
    var idx = b.finalize()
    assert_equal(idx.num_terms(), 3, "5: num_terms")
    # Ordinal follows lexicographic byte order, NOT insertion order.
    assert_equal(_bytes_to_string(idx.term_bytes_at(0)), String("apple"), "5: ord0")
    assert_equal(_bytes_to_string(idx.term_bytes_at(1)), String("mango"), "5: ord1")
    assert_equal(_bytes_to_string(idx.term_bytes_at(2)), String("zebra"), "5: ord2")
    # The postings still belong to the right term after the permutation.
    _assert_int_list(
        _span_to_list(idx.posting_doc_ids_at(0)), [1], "5: apple doc_id"
    )
    _assert_int_list(
        _span_to_list(idx.posting_doc_ids_at(2)), [0], "5: zebra doc_id"
    )


# -----------------------------------------------------------------------------
# 6. Empty field / finalize-then-add raises / zero-doc clean finalize
# -----------------------------------------------------------------------------


def test_06a_empty_field() raises:
    var b = InvertedIndexBuilder.create("body")
    b.add_document(0, _af(List[String]()))
    var idx = b.finalize()
    assert_equal(idx.num_terms(), 0, "6a: empty doc -> 0 terms")


def test_06b_zero_doc_finalize() raises:
    var b = InvertedIndexBuilder.create("body")
    var idx = b.finalize()
    assert_equal(idx.num_terms(), 0, "6b: zero docs -> empty index")
    assert_equal(idx.field_name(), String("body"), "6b: field name")


def test_06c_add_after_finalize_raises() raises:
    var b = InvertedIndexBuilder.create("body")
    b.add_document(0, _af([String("x")]))
    # finalize sets _finalized = True; the moved-out FinalizedIndex is discarded
    # here (we only need the side effect on `b`).
    _ = b.finalize()
    with assert_raises():
        b.add_document(1, _af([String("y")]))


# -----------------------------------------------------------------------------
# 6d. Monotonicity is a HARD raise
# -----------------------------------------------------------------------------


def test_06d_monotonicity_raises() raises:
    var b = InvertedIndexBuilder.create("body")
    b.add_document(5, _af([String("a")]))
    with assert_raises():
        b.add_document(3, _af([String("b")]))  # 3 < 5 -> hard raise


# -----------------------------------------------------------------------------
# 7. 128-doc block boundary (in-memory shape that feeds the split writer transform)
# -----------------------------------------------------------------------------


def test_07_block_boundary_129() raises:
    var b = InvertedIndexBuilder.create("body")
    # Single term across docs 0..128 (129 docs, tf=1 each).
    for d in range(129):
        b.add_document(d, _af([String("term")]))
    var idx = b.finalize()
    assert_equal(idx.num_terms(), 1, "7: num_terms")
    assert_equal(idx.doc_freq_at(0), 129, "7: doc_freq")
    var dids = _span_to_list(idx.posting_doc_ids_at(0))
    assert_equal(len(dids), 129, "7: doc_ids len")
    # ascending contiguous 0..128
    for d in range(129):
        assert_equal(dids[d], d, "7: doc_id[" + String(d) + "]")
    assert_equal(len(idx.posting_tfs_at(0)), 129, "7: tfs len")


# -----------------------------------------------------------------------------
# 8. FNV cross-check (the net-new export) — known-answer vectors
# -----------------------------------------------------------------------------


def test_08_fnv_known_answers() raises:
    # Empty span -> FNV-1a-64 offset basis.
    var empty = List[UInt8]()
    assert_equal(
        fnv1a_64_over_bytes(Span(empty)),
        UInt64(0xCBF29CE484222325),
        "8: empty -> offset basis",
    )
    # "a" -> 0xaf63dc4c8601ec8c (canonical FNV-1a-64 vector).
    var a = String("a")
    assert_equal(
        fnv1a_64_over_bytes(a.as_bytes()),
        UInt64(0xAF63DC4C8601EC8C),
        "8: 'a' -> known answer",
    )
    # Determinism: same input -> same hash.
    var s = String("hello world")
    assert_equal(
        fnv1a_64_over_bytes(s.as_bytes()),
        fnv1a_64_over_bytes(s.as_bytes()),
        "8: deterministic",
    )


# -----------------------------------------------------------------------------
# 9. Hash-collision tiebreak (distinct terms stay distinct under probing)
# -----------------------------------------------------------------------------


def test_09_collision_tiebreak() raises:
    # Tiny directory forces heavy probing; assert distinct terms never merge.
    var b = InvertedIndexBuilder.create_with_capacity("body", 4, 64)
    var n = 50
    # Each doc has a unique term -> n distinct terms, each doc_freq 1.
    for d in range(n):
        b.add_document(d, _af([String("t") + String(d)]))
    var idx = b.finalize()
    assert_equal(idx.num_terms(), n, "9: all distinct terms preserved")
    # Every term resolves to exactly its own single-doc posting.
    for d in range(n):
        var o = _ordinal_of(idx, String("t") + String(d))
        assert_true(o >= 0, "9: term t" + String(d) + " present")
        assert_equal(idx.doc_freq_at(o), 1, "9: t" + String(d) + " doc_freq")
        _assert_int_list(
            _span_to_list(idx.posting_doc_ids_at(o)),
            [d],
            "9: t" + String(d) + " doc_id",
        )


# -----------------------------------------------------------------------------
# A1. Salt-sentinel regression
# -----------------------------------------------------------------------------


def test_A1_salt_sentinel_zero_top16() raises:
    # "oqda" has FNV-1a-64 hash 0xc5b4674b4b6e, whose top-16 bits == 0
    # (verified offline). Inserted as the FIRST term => term_id 0. WITHOUT the
    # `| (1 << 15)` salt-force, salt would be 0 and the packed directory word
    # for term_id 0 would be (0 << 48) | 0 == 0 == EMPTY sentinel — the term
    # would alias EMPTY and be lost/duplicated. With the force, salt == 0x8000
    # (nonzero), so the term is FOUND. This is the load-bearing A1 invariant.
    var h = fnv1a_64_over_bytes(String("oqda").as_bytes())
    assert_equal(h >> 48, UInt64(0), "A1: precondition top-16 bits zero")

    var b = InvertedIndexBuilder.create("body")
    # term_id 0 is "oqda". Add it again in a later doc; it MUST resolve to the
    # SAME term (found, not duplicated) — proving it didn't alias EMPTY.
    b.add_document(0, _af([String("oqda")]))
    b.add_document(1, _af([String("oqda"), String("other")]))
    var idx = b.finalize()
    # Exactly 2 distinct terms: "oqda" (doc_freq 2) + "other" (doc_freq 1).
    assert_equal(idx.num_terms(), 2, "A1: distinct term count")
    var o_oqda = _ordinal_of(idx, "oqda")
    assert_true(o_oqda >= 0, "A1: oqda found")
    assert_equal(idx.doc_freq_at(o_oqda), 2, "A1: oqda doc_freq == 2 (not lost)")
    _assert_int_list(
        _span_to_list(idx.posting_doc_ids_at(o_oqda)),
        [0, 1],
        "A1: oqda doc_ids",
    )


# -----------------------------------------------------------------------------
# 10. add_text_column driver (the Arrow seam)
# -----------------------------------------------------------------------------


def _make_text_batch() raises -> RecordBatch:
    var values: List[String] = [
        String("Hello World"),
        String("the quick fox"),
        String("hello again"),
    ]
    var sa = StringArray.from_strings(values)
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(1)
    rb.add_column(Column.from_string(sa^))
    return rb.build(schema^)


def test_10_add_text_column() raises:
    var batch = _make_text_batch()
    var bv = batch_view_over(batch)
    var col = bv.col_str(0)
    var cfg = AnalyzerConfig.text("body")  # lowercase + fold + english stopwords

    var b = InvertedIndexBuilder.create("body")
    var token_counts = List[Int]()  # out-param (the per-doc fieldnorm)
    b.add_text_column(col, 10, cfg, token_counts)  # base 10 -> 10, 11, 12
    var idx = b.finalize()

    # The additive out-param captures the per-row token count from the
    # SAME single tokenization. Row 0 "Hello World" -> 2, Row 1 "the quick fox"
    # -> 2 ("the" stopworded), Row 2 "hello again" -> 2. The doc-freqs/postings
    # below are UNCHANGED by the out-param addition.
    assert_equal(len(token_counts), 3, "10: J3 token_counts length")
    _assert_int_list(token_counts, [2, 2, 2], "10: J3 per-doc token counts")

    # Row 0 "Hello World"  -> hello, world  (doc 10)
    # Row 1 "the quick fox" -> quick, fox    (doc 11; "the" is a stopword)
    # Row 2 "hello again"   -> hello, again  (doc 12)
    # Distinct terms: hello, world, quick, fox, again.
    assert_equal(idx.num_terms(), 5, "10: distinct terms")

    var o_hello = _ordinal_of(idx, "hello")
    assert_true(o_hello >= 0, "10: hello present")
    assert_equal(idx.doc_freq_at(o_hello), 2, "10: hello doc_freq (rows 0,2)")
    _assert_int_list(
        _span_to_list(idx.posting_doc_ids_at(o_hello)),
        [10, 12],
        "10: hello doc_ids (base 10)",
    )

    var o_fox = _ordinal_of(idx, "fox")
    assert_true(o_fox >= 0, "10: fox present")
    _assert_int_list(
        _span_to_list(idx.posting_doc_ids_at(o_fox)), [11], "10: fox doc_id"
    )

    # "the" is a stopword -> must NOT be a term.
    assert_equal(_ordinal_of(idx, "the"), -1, "10: 'the' stopworded out")


# -----------------------------------------------------------------------------
# 11. TF-reduce regression (search index-build perf)
# -----------------------------------------------------------------------------
#
# Pins the byte-identical invariant of the per-doc TF reduce: the
# O(1)-per-token term_id-indexed accumulator (`_doc_tf_by_term` +
# first-occurrence-ordered `_doc_touched`, both builder fields reused across
# docs) must produce exactly what an O(distinct) per-token linear scan over
# parallel (doc_term_ids, doc_tfs) lists would. The three properties it
# must preserve, all asserted below against hand-computed golden values:
#   (a) FIRST-OCCURRENCE posting-append order within a doc, under heavily
#       INTERLEAVED repeats (the order distinct terms are first seen in the
#       token multiset is the order their postings/ordinals derive from — a
#       regression here reorders the term directory and changes split bytes).
#   (b) Per-doc accumulator RESET: a term's TF in doc A must NOT leak into
#       doc B (the touched-only zero-reset between docs). A bug that skipped
#       the reset would inflate doc B's TF by doc A's count.
#   (c) A term first inserted MID-DOC (the accumulator grow path) tallies
#       correctly for the remainder of that same doc.


def test_11_tf_reduce_interleaved_first_occurrence() raises:
    var b = InvertedIndexBuilder.create("body")

    # Doc 0: interleaved multiset. First-occurrence order is c, a, b, d
    # (NOT lexicographic, NOT sorted). TF: c=3, a=2, b=2, d=1.
    #   tokens: c a b a c b c d
    b.add_document(
        0,
        _af(
            [
                String("c"),
                String("a"),
                String("b"),
                String("a"),
                String("c"),
                String("b"),
                String("c"),
                String("d"),
            ]
        ),
    )
    # Doc 1: a NEW term "e" appears mid-doc (accumulator grow), and "a" recurs
    # so its per-doc accumulator must have been reset to 0 after doc 0.
    #   tokens: a e a  -> a tf=2 (doc 1 only, NOT 2+doc0's 2), e tf=1
    b.add_document(1, _af([String("a"), String("e"), String("a")]))
    var idx = b.finalize()

    # Distinct terms across both docs: a, b, c, d, e -> 5.
    assert_equal(idx.num_terms(), 5, "11: distinct terms")

    # (a) + (b): "a" appears in BOTH docs. doc 0 tf=2, doc 1 tf=2 (the reset
    # proves doc 1 did not inherit doc 0's count). doc-freq=2 (one posting per
    # doc), doc_ids ascending [0, 1].
    var o_a = _ordinal_of(idx, "a")
    assert_true(o_a >= 0, "11: a present")
    assert_equal(idx.doc_freq_at(o_a), 2, "11: a doc_freq")
    _assert_int_list(
        _span_to_list(idx.posting_doc_ids_at(o_a)), [0, 1], "11: a doc_ids"
    )
    _assert_int_list(
        _span_to_list(idx.posting_tfs_at(o_a)), [2, 2], "11: a tfs per doc"
    )

    # "c" only in doc 0, tf=3 (the interleaved c a b a c b c d).
    var o_c = _ordinal_of(idx, "c")
    assert_true(o_c >= 0, "11: c present")
    assert_equal(idx.doc_freq_at(o_c), 1, "11: c doc_freq")
    _assert_int_list(
        _span_to_list(idx.posting_doc_ids_at(o_c)), [0], "11: c doc_id"
    )
    _assert_int_list(_span_to_list(idx.posting_tfs_at(o_c)), [3], "11: c tf")

    # "b" only in doc 0, tf=2.
    var o_b = _ordinal_of(idx, "b")
    assert_equal(idx.doc_freq_at(o_b), 1, "11: b doc_freq")
    _assert_int_list(_span_to_list(idx.posting_tfs_at(o_b)), [2], "11: b tf")

    # "d" only in doc 0, tf=1.
    var o_d = _ordinal_of(idx, "d")
    _assert_int_list(_span_to_list(idx.posting_tfs_at(o_d)), [1], "11: d tf")

    # (c) "e" is first inserted mid-doc-1, tf=1, doc 1 only.
    var o_e = _ordinal_of(idx, "e")
    assert_true(o_e >= 0, "11: e present (inserted mid-doc-1)")
    assert_equal(idx.doc_freq_at(o_e), 1, "11: e doc_freq")
    _assert_int_list(
        _span_to_list(idx.posting_doc_ids_at(o_e)), [1], "11: e doc_id"
    )
    _assert_int_list(_span_to_list(idx.posting_tfs_at(o_e)), [1], "11: e tf")


def test_12_tf_reduce_term_id_order_vs_lex() raises:
    """The build-order term_ids derive from FIRST-OCCURRENCE order across the
    whole stream; the finalized ORDINALS are lexicographic. A TF-reduce bug
    that changed first-occurrence ordering would change the build-order
    term_ids (and thus the directory), which this pins via the per-doc TF
    tallies surviving the lex re-sort unchanged."""
    var b = InvertedIndexBuilder.create("body")
    # First-occurrence order: zebra, mango, apple (reverse lexicographic).
    # Each recurs so the accumulator is exercised; the lex drain must still
    # yield apple < mango < zebra with the correct per-doc TFs.
    b.add_document(
        0,
        _af(
            [
                String("zebra"),
                String("mango"),
                String("zebra"),
                String("apple"),
                String("mango"),
                String("zebra"),
            ]
        ),
    )
    var idx = b.finalize()
    assert_equal(idx.num_terms(), 3, "12: distinct terms")
    # Ordinals are lexicographic: apple=0, mango=1, zebra=2.
    assert_equal(_bytes_to_string(idx.term_bytes_at(0)), "apple", "12: ord0")
    assert_equal(_bytes_to_string(idx.term_bytes_at(1)), "mango", "12: ord1")
    assert_equal(_bytes_to_string(idx.term_bytes_at(2)), "zebra", "12: ord2")
    # TFs: zebra=3, mango=2, apple=1 — by lex ordinal.
    _assert_int_list(_span_to_list(idx.posting_tfs_at(0)), [1], "12: apple tf")
    _assert_int_list(_span_to_list(idx.posting_tfs_at(1)), [2], "12: mango tf")
    _assert_int_list(_span_to_list(idx.posting_tfs_at(2)), [3], "12: zebra tf")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
