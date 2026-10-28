# =============================================================================
# test_payload_narrow_parity: the host rule against the optimizer's table
# =============================================================================
#
# Every row of golden/payload_narrow.txt names a fixture; the first block is
# the 83-row parity table of komira_optimizer's payload-narrowing pass (the
# rule the host rule replaced, now deleted), verbatim, over its own fixtures
# (fixtures.mojo), the rest are this package's (extra_fixtures.mojo). For
# every row, the host rule `derive_payload_narrow`, given each scan's
# statistics as its footer entry, must render to the row. Every mismatch is
# reported, and on any mismatch the rule's rows for the whole file are
# printed.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_ir.logical_plan import (
    SOURCE_CSV,
    SOURCE_JSON,
    SOURCE_ORC,
    SOURCE_IN_MEMORY,
)
from komira_lowering_rules.payload_narrow import derive_payload_narrow

from komira_lowering_rules_conformance.extra_fixtures import build, extra_names
from komira_lowering_rules_conformance.golden import GoldenRow, parse_golden, read_golden
from komira_lowering_rules_conformance.render import case_footers, render, row

comptime GOLDEN = "golden/payload_narrow.txt"
comptime OPTIMIZER_TABLE_ROWS = 83
"""The rows of komira_optimizer's parity table, the golden file's first block."""


def test_host_rule_matches_every_golden_row() raises:
    var golden = read_golden(GOLDEN)
    var problems = List[String]()
    var host_rows = String()
    for i in range(len(golden)):
        ref g = golden[i]
        var plan = build(g.name)
        var host = row(g.name, render(derive_payload_narrow(plan, case_footers(plan))))
        host_rows += host + "\n"
        if host != g.text:
            problems.append("line " + String(g.line) + ": golden `" + g.text + "` host `" + host + "`")
    if len(problems) > 0:
        print("the host rule's rows:")
        print(host_rows)
        var msg = String(len(problems)) + " problem(s):"
        for i in range(len(problems)):
            msg += "\n  " + problems[i]
        raise Error(msg)


def test_golden_is_the_optimizer_table_then_the_extras() raises:
    # The row count is pinned and the rows after the optimizer's block are
    # exactly the extra cases, in order. Catches: a dropped or added row, or
    # an extra case with no golden row (or a golden row with no extra case).
    var golden = read_golden(GOLDEN)
    var extras = extra_names()
    assert_equal(len(golden), OPTIMIZER_TABLE_ROWS + len(extras))
    for i in range(len(extras)):
        assert_equal(golden[OPTIMIZER_TABLE_ROWS + i].name, extras[i])


def test_the_golden_rows_reach_every_outcome() raises:
    # Rows that narrow to each width and rows with a scan that narrows
    # nothing, so a rule that always answered one way could not match them.
    # Catches: a golden file that lost its variety.
    var golden = read_golden(GOLDEN)
    var one = False
    var two = False
    var four = False
    var nothing = False
    for i in range(len(golden)):
        var t = golden[i].text + " "
        if t.find(":1:") >= 0:
            one = True
        if t.find(":2:") >= 0:
            two = True
        if t.find(":4:") >= 0:
            four = True
        if t.find(": | ") >= 0 or t.endswith(": "):
            nothing = True
    assert_true(one and two and four and nothing)


def test_the_non_parquet_cases_carry_their_source_type() raises:
    # Catches: a fixture whose scan is not the kind its name says (the
    # positional `LogicalPlan.scan` builds a CSV source for a type it has no
    # arm for), which would leave that kind untested.
    var names = List[String]()
    var types = List[UInt8]()
    names.append("side_csv_scan")
    types.append(SOURCE_CSV)
    names.append("side_ndjson_scan")
    types.append(SOURCE_JSON)
    names.append("side_orc_scan")
    types.append(SOURCE_ORC)
    names.append("refuse_non_parquet_side")
    types.append(SOURCE_IN_MEMORY)
    for i in range(len(names)):
        var plan = build(names[i])
        assert_equal(plan.join_data_ref().left[].scan_data_ref().source_type, types[i], names[i])


def test_golden_reader_refuses_a_malformed_file() raises:
    # Catches: a line without its ` =>`, or a case named twice, read silently.
    var got = List[String]()
    for c in range(2):
        try:
            if c == 0:
                _ = parse_golden("# comment\nbase scan#0:\n")
            else:
                _ = parse_golden("base =>\n\nbase => scan#0:\n")
            got.append("accepted")
        except e:
            got.append(String(e))
    assert_equal(got[0], "golden line 2: expected exactly one ` =>`: base scan#0:")
    assert_equal(got[1], "golden line 3: case base is also on line 1")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
