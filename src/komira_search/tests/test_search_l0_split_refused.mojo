# =============================================================================
# test_search_l0_split_refused.mojo — SearchCore refuses an L0-posting split
# =============================================================================
#
# A split may carry an `l0_posting` region (the additive footer slot after the
# blockmax pair) whose postings live outside the term dictionary. SearchCore
# reads only the term dictionary and the postings region, so on such a split
# every query term misses and every query returns 0 hits with no error. This
# suite pins that SearchCore construction raises instead, naming the region.
#
# Coverage (enumerated cases):
#   1. SearchCore(bytes) on a split carrying an l0_posting region raises, and
#      the message names `l0_posting`.
#   2. SearchCore.from_view(view) on the same split raises the same way (the
#      path komira_search_scan uses).
#   3. control: the same split shape WITHOUT an l0_posting region (empty term
#      dictionary, 2 doc-store slots) still constructs, and a query returns 0
#      hits. The refusal is keyed on the region, not on an empty term dict.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_search.analyzer import AnalyzerConfig
from komira_search.inverted import InvertedIndexBuilder
from komira_search.term_dict import TermDictBuilder
from komira_search.split import serialize_split, DocStoreBuilder, SplitView
from komira_search.source import QueryIR, SearchCore


def _uuid(seed: UInt8) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=0)
    for i in range(16):
        u[i] = seed + UInt8(i)
    return u^


def _split_bytes(with_l0: Bool) raises -> List[UInt8]:
    """A split with an empty term dictionary and postings region and 2
    doc-store slots; with `with_l0` it also carries a 4-byte l0_posting
    region, the shape `serialize_split` accepts for an L0 split."""
    var b = InvertedIndexBuilder.create("body")
    var fi = b.finalize()
    var td = TermDictBuilder.build_from_finalized(fi)
    var ds = DocStoreBuilder(compress=False)
    ds.append(String("r0").as_bytes())
    ds.append(String("r1").as_bytes())
    var l0 = List[UInt8]()
    if with_l0:
        l0 = [UInt8(1), UInt8(2), UInt8(3), UInt8(250)]
    return serialize_split(
        fi,
        td^,
        ds,
        String("body"),
        _uuid(7),
        0,
        1,
        2,
        total_token_count=4,
        l0_posting_region=l0^,
    )


def test_1_search_core_refuses_l0_posting_split() raises:
    var bytes = _split_bytes(with_l0=True)
    assert_true(SplitView.parse(bytes.copy()).has_l0_posting())
    with assert_raises(contains="l0_posting"):
        _ = SearchCore(bytes^)


def test_2_from_view_refuses_l0_posting_split() raises:
    var view = SplitView.parse(_split_bytes(with_l0=True))
    assert_true(view.has_l0_posting())
    with assert_raises(contains="l0_posting"):
        _ = SearchCore.from_view(view^)


def test_3_split_without_l0_posting_still_constructs() raises:
    var view = SplitView.parse(_split_bytes(with_l0=False))
    assert_false(view.has_l0_posting())
    var core = SearchCore.from_view(view^)
    var q = QueryIR(
        String("body"), String("alpha"), 10, AnalyzerConfig.text("body")
    )
    var r = core.search(q)
    assert_equal(r.total_matches, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
