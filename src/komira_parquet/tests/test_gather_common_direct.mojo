# Direct tests of `gather_common.mojo`: the exclusive running rank of the
# definition levels (`value_index[r]` = how many of rows 0..r-1 are non-null,
# the position of row r's value in a nullable page's value stream) and the
# gathers' up-front check that `num_selected` is the intervals' total.
from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet_api.types import Encoding

from komira_parquet.gather_common import (
    _PageDefLevels,
    _PageExtent,
    _build_value_index,
    _check_num_selected,
)
from komira_parquet.selection_vector import SelectionInterval


def _rank(defs: List[UInt8]) -> List[Int]:
    var out = List[Int]()
    var n = 0
    for i in range(len(defs)):
        out.append(n)
        if defs[i] != 0:
            n += 1
    return out^


def test_value_index_is_the_exclusive_rank() raises:
    """[1, 0, 1, 1] ranks [0, 1, 1, 2]; any non-zero level counts (2, 255);
    no levels rank nothing; a longer pseudo-random run matches the
    definition."""
    var defs4: List[UInt8] = [1, 0, 1, 1]
    var got = _build_value_index(Span(defs4))
    var want: List[Int] = [0, 1, 1, 2]
    assert_equal(len(got), 4)
    for i in range(4):
        assert_equal(Int(got[i]), want[i])
    var odd: List[UInt8] = [0, 2, 255, 0, 1]
    var got2 = _build_value_index(Span(odd))
    var want2: List[Int] = [0, 0, 1, 2, 2]
    for i in range(5):
        assert_equal(Int(got2[i]), want2[i])
    var none = List[UInt8]()
    assert_equal(len(_build_value_index(Span(none))), 0)
    var defs = List[UInt8]()
    var s = UInt64(7)
    for _ in range(1000):
        s = s * 6364136223846793005 + 1442695040888963407
        defs.append(UInt8(Int(s >> 61) % 2))
    var got3 = _build_value_index(Span(defs))
    var want3 = _rank(defs)
    for i in range(1000):
        assert_equal(Int(got3[i]), want3[i])


def _refused(intervals: List[SelectionInterval], n: Int) -> String:
    try:
        _check_num_selected("who", Span(intervals), n)
    except e:
        return String(e)
    return String("")


def test_num_selected_check() raises:
    """The total is the sum of `select` (skips do not count). Equal passes,
    one off either way is refused with the caller's name. Two selects of
    2^32 - 1 total 2^33 - 2, which passes as itself and is refused as the
    UInt32-wrapped 2^32 - 2."""
    var iv: List[SelectionInterval] = [
        SelectionInterval(5, 3),
        SelectionInterval(0, 4),
    ]
    assert_equal(_refused(iv, 7), "")
    assert_equal(
        _refused(iv, 6),
        "who: the selection intervals select 7 rows, not num_selected = 6",
    )
    assert_true(_refused(iv, 8) != "")
    assert_equal(_refused(List[SelectionInterval](), 0), "")
    assert_true(_refused(List[SelectionInterval](), 1) != "")
    var big: List[SelectionInterval] = [
        SelectionInterval(0, UInt32.MAX),
        SelectionInterval(0, UInt32.MAX),
    ]
    assert_equal(_refused(big, (1 << 33) - 2), "")
    assert_true(_refused(big, (1 << 32) - 2) != "")


def test_page_records() raises:
    var e = _PageExtent(12, Encoding.RLE_DICTIONARY)
    var copy = e
    assert_equal(copy.num_values, 12)
    assert_true(copy.encoding == Encoding.RLE_DICTIONARY)
    var d = _PageDefLevels([UInt8(1), 0, 1], 2)
    assert_equal(len(d.defs), 3)
    assert_equal(d.num_non_null, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
