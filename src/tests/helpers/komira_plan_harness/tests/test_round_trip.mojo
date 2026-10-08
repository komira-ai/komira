# render -> text -> parse -> compare is equal for a batch of every type, and
# the text is a fixed point of parse + print, under each order mode.
#
# Defects these catch: a cell the renderer writes that the parser refuses
# or rewrites (an escape, a float decimal the parser does not read back to
# the same bits, a header line the parser does not take); a comparison that
# disagrees with itself on identical inputs (NaN, -0.0, nested values).

from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_harness import CanonPolicy, compare_canon, parse_canon, render_batch
from komira_plan_harness.fixtures_every_type import every_type_batch


def _round_trip(var policy: CanonPolicy) raises:
    var batch = every_type_batch()
    var rendered = render_batch(batch, policy^)
    var text = rendered.to_text()
    var parsed = parse_canon(text)
    var report = compare_canon(parsed, rendered)
    if not report.ok():
        raise Error(String("round trip differs: ") + String(report))
    assert_equal(parsed.to_text(), text)
    assert_equal(parsed.num_rows(), 3)
    assert_equal(parsed.num_columns(), rendered.num_columns())
    # And the other way round: the parsed text as the actual side.
    assert_true(compare_canon(rendered, parsed).ok())


def test_round_trip_total() raises:
    _round_trip(CanonPolicy.total())


def test_round_trip_unordered() raises:
    _round_trip(CanonPolicy.unordered())


def test_round_trip_keyed() raises:
    var keys: List[String] = ["i32", "s"]
    _round_trip(CanonPolicy.keyed(keys))


def test_zero_rows_and_zero_columns() raises:
    var empty = parse_canon(
        "#! komira-plan-conformance v1\n#  order: total\n#  float: ulps=0\n\n\n\n"
    )
    assert_equal(empty.num_columns(), 0)
    assert_equal(empty.num_rows(), 2)
    assert_equal(parse_canon(empty.to_text()).to_text(), empty.to_text())
    var no_rows = parse_canon(
        "#! komira-plan-conformance v1\n#  order: total\n#  float: ulps=0\nk:int32\n"
    )
    assert_equal(no_rows.num_rows(), 0)
    assert_true(compare_canon(no_rows, no_rows.copy()).ok())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
