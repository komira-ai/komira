# =============================================================================
# test_search_cov_merge.mojo: the cross-split merge under the float and string
# sort keys, a page past every hit, and the metric fold's minimum.
# =============================================================================
#
#   1. F64 keys, descending, missing last: a higher key ranks first; an equal
#      key across splits with different doc-ids falls to doc_id order; the
#      missing row is last; the merged keys travel with their rows.
#   2. STR keys, ascending, missing first: the missing row comes first, then
#      the keys in byte order; the merged keys travel with their rows.
#   3. A page starting past every hit is empty and still sums the totals.
#   4. merge_agg_results folds min and max across splits (a later split's lower
#      minimum and higher maximum win), count and sum add.
#   5. The same doc_id with an equal key (and the same doc_id with both keys
#      missing) in two splits falls to split order: the earlier split first.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab

from komira_search.source import (
    SearchResult,
    SortKeyColumn,
    AggSpec,
    AggResult,
    AggResults,
    AGG_KIND_MIN,
    AGG_KIND_MAX,
    SORT_ASC,
    SORT_DESC,
    MISSING_LAST,
    MISSING_FIRST,
    SORT_MODE_SCORE,
    SORT_MODE_F64,
    SORT_MODE_STR,
    _assemble_hit_batch,
)
from komira_search.merge import merge_search_results, merge_agg_results


def _result_f64(
    ids: List[Int64], keys: List[Float64], missing: List[Bool], total: Int
) raises -> SearchResult:
    var scores = List[Float64]()
    var srcs = List[String]()
    for i in range(len(ids)):
        scores.append(1.0)
        srcs.append(String("s") + String(ids[i]))
    var sk = SortKeyColumn(SORT_MODE_F64)
    for i in range(len(ids)):
        sk.key_f64.append(keys[i])
        sk.missing.append(missing[i])
    return SearchResult(
        _assemble_hit_batch(scores^, ids.copy(), srcs^), total, AggResults(), sk^
    )


def _result_str(
    ids: List[Int64], keys: List[String], missing: List[Bool], total: Int
) raises -> SearchResult:
    var scores = List[Float64]()
    var srcs = List[String]()
    for i in range(len(ids)):
        scores.append(1.0)
        srcs.append(String("s") + String(ids[i]))
    var sk = SortKeyColumn(SORT_MODE_STR)
    for i in range(len(ids)):
        sk.key_str.append(keys[i])
        sk.missing.append(missing[i])
    return SearchResult(
        _assemble_hit_batch(scores^, ids.copy(), srcs^), total, AggResults(), sk^
    )


def _ids(r: SearchResult) raises -> List[Int]:
    var out = List[Int]()
    var arr = r.batch.column_at(1).as_primitive[DType.int64]()
    for i in range(r.batch.num_rows()):
        out.append(Int(arr.get(i)))
    return out^


def test_01_f64_desc_missing_last() raises:
    var results = Slab[SearchResult]()
    results.append(_result_f64([0, 1], [2.0, 0.0], [False, True], 2))
    results.append(_result_f64([0, 2], [5.0, 2.0], [False, False], 2))
    var m = merge_search_results(
        results^, 0, 10, SORT_MODE_SCORE, SORT_DESC, MISSING_LAST
    )
    var ids = _ids(m.result)
    var want_ids: List[Int] = [0, 0, 2, 1]
    var want_split: List[Int] = [1, 0, 1, 0]
    var want_key: List[Float64] = [5.0, 2.0, 2.0]
    assert_equal(len(ids), 4, "1: four rows")
    for i in range(4):
        assert_equal(ids[i], want_ids[i], "1: id row " + String(i))
        assert_equal(m.hit_split_index[i], want_split[i], "1: split row " + String(i))
    for i in range(3):
        assert_equal(m.result.sort_keys.key_f64[i], want_key[i], "1: key row " + String(i))
        assert_false(m.result.sort_keys.missing[i], "1: present row " + String(i))
    assert_true(m.result.sort_keys.missing[3], "1: the missing row is last")
    assert_equal(m.result.total_matches, 4, "1: totals add")


def test_02_str_asc_missing_first() raises:
    var results = Slab[SearchResult]()
    results.append(
        _result_str([0, 1], [String("pear"), String("")], [False, True], 2)
    )
    results.append(_result_str([0], [String("apple")], [False], 1))
    var m = merge_search_results(
        results^, 0, 10, SORT_MODE_SCORE, SORT_ASC, MISSING_FIRST
    )
    var ids = _ids(m.result)
    var want_ids: List[Int] = [1, 0, 0]
    var want_split: List[Int] = [0, 1, 0]
    assert_equal(len(ids), 3, "2: three rows")
    for i in range(3):
        assert_equal(ids[i], want_ids[i], "2: id row " + String(i))
        assert_equal(m.hit_split_index[i], want_split[i], "2: split row " + String(i))
    assert_true(m.result.sort_keys.missing[0], "2: the missing row is first")
    assert_equal(m.result.sort_keys.key_str[1], String("apple"), "2: apple")
    assert_equal(m.result.sort_keys.key_str[2], String("pear"), "2: pear")


def test_03_page_past_every_hit() raises:
    var results = Slab[SearchResult]()
    results.append(_result_f64([0, 1], [2.0, 3.0], [False, False], 9))
    results.append(_result_f64([4], [1.0], [False], 5))
    var m = merge_search_results(
        results^, 10, 5, SORT_MODE_SCORE, SORT_DESC, MISSING_LAST
    )
    assert_equal(m.result.batch.num_rows(), 0, "3: empty page")
    assert_equal(len(m.hit_split_index), 0, "3: no provenance rows")
    assert_equal(m.result.total_matches, 14, "3: totals still add")


def _metric(kind: UInt8, mn: Float64, mx: Float64, n: Int) -> SearchResult:
    var r = AggResult(String("m"), kind)
    r.min = mn
    r.max = mx
    r.sum = mn + mx
    r.count = n
    r.has_value = True
    var rs = List[AggResult]()
    rs.append(r^)
    return SearchResult(RecordBatch(), 0, AggResults(rs^))


def test_04_metric_fold() raises:
    var results = Slab[SearchResult]()
    results.append(_metric(AGG_KIND_MIN, 5.0, 6.0, 2))
    results.append(_metric(AGG_KIND_MIN, 1.0, 9.0, 3))
    results.append(_metric(AGG_KIND_MIN, 3.0, 4.0, 1))
    var specs = List[AggSpec]()
    specs.append(AggSpec(String("m"), AGG_KIND_MIN, String("f")))
    var merged = merge_agg_results(results, specs)
    ref r = merged.results[0]
    assert_equal(r.min, 1.0, "4: the lower minimum wins")
    assert_equal(r.max, 9.0, "4: the higher maximum wins")
    assert_equal(r.count, 6, "4: counts add")
    assert_equal(r.sum, 28.0, "4: sums add")


def _assert_split_order(
    ids: List[Int], m_split: List[Int], label: String
) raises:
    var want_ids: List[Int] = [3, 3, 4, 4]
    var want_split: List[Int] = [0, 1, 0, 1]
    assert_equal(len(ids), 4, label + ": four rows")
    for i in range(4):
        assert_equal(ids[i], want_ids[i], label + ": id row " + String(i))
        assert_equal(m_split[i], want_split[i], label + ": split row " + String(i))


def test_05_same_doc_id_tie_falls_to_split_order() raises:
    # Both splits hold doc_id 3 with key 2.0 and doc_id 4 with no key: only the
    # split index can order each pair.
    var results = Slab[SearchResult]()
    results.append(_result_f64([3, 4], [2.0, 0.0], [False, True], 2))
    results.append(_result_f64([3, 4], [2.0, 0.0], [False, True], 2))
    var m = merge_search_results(
        results^, 0, 10, SORT_MODE_SCORE, SORT_DESC, MISSING_LAST
    )
    _assert_split_order(_ids(m.result), m.hit_split_index.copy(), "5")
    # The same rows under string keys, ascending, missing last.
    var rs = Slab[SearchResult]()
    rs.append(_result_str([3, 4], [String("k"), String("")], [False, True], 2))
    rs.append(_result_str([3, 4], [String("k"), String("")], [False, True], 2))
    var ms = merge_search_results(
        rs^, 0, 10, SORT_MODE_SCORE, SORT_ASC, MISSING_LAST
    )
    _assert_split_order(_ids(ms.result), ms.hit_split_index.copy(), "5s")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
