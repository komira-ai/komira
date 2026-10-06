# =============================================================================
# test_search_e2e_scan_equals_core.mojo
#   The `komira.search.index` scan over splits published to the local
#   filesystem returns what `SearchCore` returns over the same corpus held in
#   memory.
# =============================================================================
#
# The three corpus splits are published through `SearchMetastore` into a
# `LocalFsConditionalStore` rooted in TEST_TMPDIR. The scan runs over
# `MetastoreSearchCatalog` built on a NEW store object over that directory,
# so every split it reads comes off disk through the catalog's live list.
#
#   test_scan_over_localfs_equals_core: for each query (a term, a two-term
#   match, `café` and `cafe` (the index folds `café` to `cafe`, so both match
#   the `café` and `cafe` documents), `Zürich` and the ASCII `Zurich` (only
#   the fold lets `Zurich` match the `Zürich`/`zürich` documents; `Zürich`
#   alone needs only lowercasing), the CJK term `東京`, a term in no split,
#   and the no-query scan) three oracles must agree with the drained scan:
#     * the HAND table: the exact documents (their `_source` tags) corpus.mojo's
#       table says match, written by hand. This is the only oracle that does
#       not run `SearchCore`, so it is the one that catches a matching or
#       analyzer defect (the scan's split reader runs `SearchCore` too, and a
#       defect there moves both other oracles with it);
#     * the baseline: `SearchCore` over the in-memory split bytes, split by
#       split in publish order, row for row (score, split-local id, source):
#       this proves the store, the catalog, the order and the transport;
#     * one `SearchCore` over the whole corpus in a single split: the same
#       documents (the sorted `_source` cells), wherever the split boundaries
#       fall.
#   The execution resolves the catalog's generation, 3 (three publishes, no
#   retire).
#   Defects caught: a split the catalog drops or reads twice, bytes that
#   change on the way through the store (any row differs), a split read in
#   the wrong order, a wrong document matched (even with the right count),
#   and a missing diacritic fold (`cafe`/`café`, `Zurich`).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_objectstore import LocalFsConditionalStore, RetryPolicy

from komira_search_scan.search_scan_kind import SearchScanResolver

from komira_runtime_paths import test_tmpdir

from komira_search_e2e.corpus import (
    INDEX_NAME,
    NUM_SPLITS,
    corpus_split,
    split_doc_count,
    split_sources,
    whole_corpus_split,
)
from komira_search_e2e.catalog import (
    MetastoreSearchCatalog,
    open_metastore,
    publish_split,
)
from komira_search_e2e.rows import (
    baseline_rows,
    core_sources,
    scan_rows,
    sorted_strings,
)


comptime _Catalog = MetastoreSearchCatalog[LocalFsConditionalStore]


def _docs(pairs: List[Int]) raises -> List[String]:
    """The sorted `_source` tags of the documents `pairs` names, as flat
    (split, doc) pairs: the hand table's answer for one query."""
    var out = List[String]()
    for i in range(0, len(pairs), 2):
        out.append(split_sources(pairs[i])[pairs[i + 1]])
    return sorted_strings(out^)


def _every_doc() raises -> List[Int]:
    var out = List[Int]()
    for s in range(NUM_SPLITS):
        for d in range(split_doc_count(s)):
            out.append(s)
            out.append(d)
    return out^


def _check_query(
    rt: SearchScanResolver[_Catalog],
    splits: List[List[UInt8]],
    whole: List[UInt8],
    query: String,
    hand: List[Int],
) raises:
    var what = String("query '") + query + String("'")
    var got = scan_rows(rt, String(INDEX_NAME), query)
    assert_equal(got.generation, Int64(3), what + ": resolved generation")
    var want = baseline_rows(splits, query)
    assert_equal(len(got.rows), len(want), what + ": rows vs baseline")
    for i in range(len(want)):
        assert_equal(got.rows[i], want[i], what + ": row " + String(i))
    var want_docs = _docs(hand)
    var got_docs = sorted_strings(got.sources.copy())
    assert_equal(len(got_docs), len(want_docs), what + ": hand table count")
    for i in range(len(want_docs)):
        assert_equal(
            got_docs[i], want_docs[i], what + ": hand table doc " + String(i)
        )
    var one_split = sorted_strings(core_sources(whole, query))
    var scanned = sorted_strings(got.sources.copy())
    assert_equal(len(scanned), len(one_split), what + ": vs whole corpus")
    for i in range(len(one_split)):
        assert_equal(
            scanned[i], one_split[i], what + ": whole-corpus doc " + String(i)
        )


def test_scan_over_localfs_equals_core() raises:
    var root = test_tmpdir() + String("/scan")
    var index = String(INDEX_NAME)
    var writer_store = LocalFsConditionalStore(root)
    var writer = open_metastore(writer_store, index, RetryPolicy.fast_test())
    var splits = List[List[UInt8]]()
    for s in range(NUM_SPLITS):
        splits.append(corpus_split(s))
        _ = publish_split(
            writer, writer_store, index, s, splits[s], split_doc_count(s)
        )
    var whole = whole_corpus_split()

    var rt = SearchScanResolver[_Catalog](
        _Catalog(LocalFsConditionalStore(root), index.copy())
    )
    # (split, doc) pairs from corpus.mojo's table.
    var alpha: List[Int] = [0, 0, 0, 1, 1, 0, 2, 0]
    var alpha_delta: List[Int] = [0, 0, 0, 1, 1, 0, 2, 0, 0, 2, 1, 1, 2, 2]
    var cafe: List[Int] = [1, 0, 2, 1]
    var zurich: List[Int] = [0, 2, 2, 3]
    var tokyo: List[Int] = [0, 0, 2, 0]
    _check_query(rt, splits, whole, String("alpha"), alpha)
    _check_query(rt, splits, whole, String("alpha delta"), alpha_delta)
    _check_query(rt, splits, whole, String("café"), cafe)
    _check_query(rt, splits, whole, String("cafe"), cafe)
    _check_query(rt, splits, whole, String("Zürich"), zurich)
    _check_query(rt, splits, whole, String("Zurich"), zurich)
    _check_query(rt, splits, whole, String("東京"), tokyo)
    _check_query(rt, splits, whole, String("nowhere"), List[Int]())
    _check_query(rt, splits, whole, String(""), _every_doc())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
