# =============================================================================
# test_payload_narrow_parity: the host rule against the optimizer rule
# =============================================================================
#
# For every fixture: the host rule `derive_payload_narrow`, given each scan's
# statistics as its footer entry, the optimizer rule
# `narrow_join_payload_inplace` (the oracle), which stamps
# `ScanData.payload_narrow` from the same statistics on the plan, and the
# golden file must give the same specs for every scan. Every mismatch is
# reported, and on any mismatch the oracle's rendering of the whole fixture
# set is printed in the golden file's format.
#
# The oracle part (the import of komira_optimizer and `_oracle`) goes when
# the optimizer rule and `ScanData.payload_narrow` are deleted; the golden
# file then holds the oracle's decisions on its own.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    PLAN_CAST_TO_VARCHAR,
)
from komira_lowering_rules.payload_narrow import derive_payload_narrow
from komira_optimizer.optimizer_payload_narrow import narrow_join_payload_inplace

from komira_lowering_rules_conformance.fixtures import (
    cases,
    case_footers,
    render,
    render_slot,
)
from komira_lowering_rules_conformance.golden import (
    GoldenRow,
    parse_golden,
    read_golden,
    find_golden,
)

comptime GOLDEN = "golden/payload_narrow.tsv"


def _stamped(node: LogicalPlan, mut out: String) raises:
    """Append each scan's stamped specs, in scan pre-order."""
    if node.tag == PLAN_SCAN:
        if out.byte_length() > 0:
            out += " "
        out += render_slot(node.scan_data_ref().payload_narrow)
    elif node.tag == PLAN_JOIN:
        _stamped(node.join_data_ref().left[], out)
        _stamped(node.join_data_ref().right[], out)
    elif node.tag == PLAN_ASOF_JOIN:
        _stamped(node.asof_join_data_ref().left[], out)
        _stamped(node.asof_join_data_ref().right[], out)
    elif node.tag == PLAN_UNION:
        ref kids = node.union_data_ref().children
        for i in range(len(kids)):
            _stamped(kids[i][], out)
    elif node.tag == PLAN_FILTER:
        _stamped(node.filter_data_ref().child[], out)
    elif node.tag == PLAN_PROJECT:
        _stamped(node.project_data_ref().child[], out)
    elif node.tag == PLAN_AGGREGATE:
        _stamped(node.aggregate_data_ref().child[], out)
    elif node.tag == PLAN_SORT:
        _stamped(node.sort_data_ref().child[], out)
    elif node.tag == PLAN_LIMIT:
        _stamped(node.limit_data_ref().child[], out)
    elif node.tag == PLAN_DISTINCT:
        _stamped(node.distinct_data_ref().child[], out)
    elif node.tag == PLAN_TOPN:
        _stamped(node.topn_data_ref().child[], out)
    elif node.tag == PLAN_PARTITION_BY:
        _stamped(node.partition_by_data_ref().child[], out)
    elif node.tag == PLAN_PARTITION_TOPN:
        _stamped(node.partition_topn_data_ref().child[], out)
    elif node.tag == PLAN_CAST_TO_VARCHAR:
        _stamped(node.cast_to_varchar_data_ref().child[], out)


def _oracle(plan: LogicalPlan) raises -> String:
    """The optimizer rule's decisions on a copy of `plan`, rendered."""
    var p = plan.copy()
    _ = narrow_join_payload_inplace(p)
    var out = String()
    _stamped(p, out)
    return out^


def test_host_rule_oracle_and_golden_agree_on_every_fixture() raises:
    var golden = read_golden(GOLDEN)
    var all = cases()
    var problems = List[String]()
    var harvest = String()
    for i in range(len(all)):
        ref c = all[i]
        var host = render(derive_payload_narrow(c.plan, case_footers(c.plan)))
        var oracle = _oracle(c.plan)
        harvest += c.name + "\t" + oracle + "\n"
        var g = find_golden(golden, c.name)
        if g < 0:
            problems.append(c.name + ": no golden line")
            continue
        ref want = golden[g].specs
        if host != want or oracle != want:
            problems.append(
                c.name + ": golden " + want + " | host " + host + " | oracle " + oracle
            )
    for r in range(len(golden)):
        var known = False
        for i in range(len(all)):
            if all[i].name == golden[r].name:
                known = True
                break
        if not known:
            problems.append("golden line " + String(golden[r].line) + ": no fixture named " + golden[r].name)
    if len(problems) > 0:
        print("the oracle over the fixtures, as golden lines:")
        print(harvest)
        var msg = String(len(problems)) + " problem(s):"
        for i in range(len(problems)):
            msg += "\n  " + problems[i]
        raise Error(msg)
    assert_equal(len(golden), len(all))


def test_the_fixture_set_reaches_every_outcome() raises:
    # The golden file must hold cases that narrow to each width and cases
    # that narrow nothing, so a rule that always answered one way could not
    # match it. Catches: a fixture set that lost its variety.
    var golden = read_golden(GOLDEN)
    var one = False
    var two = False
    var four = False
    var nothing = False
    for i in range(len(golden)):
        ref s = golden[i].specs
        if s.find(":1:") >= 0:
            one = True
        if s.find(":2:") >= 0:
            two = True
        if s.find(":4:") >= 0:
            four = True
        if s.find("[]") >= 0:
            nothing = True
    assert_true(one and two and four and nothing)


def test_golden_reader_refuses_a_malformed_file() raises:
    # Catches: a line without its TAB, or a case named twice, read silently.
    var got = List[String]()
    for c in range(2):
        try:
            if c == 0:
                _ = parse_golden("# comment\nbase [] []\n")
            else:
                _ = parse_golden("base\t[]\n\nbase\t[]\n")
            got.append("accepted")
        except e:
            got.append(String(e))
    assert_equal(got[0], "golden line 2: expected <case> TAB <specs>: base [] []")
    assert_equal(got[1], "golden line 3: case base is also on line 1")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
