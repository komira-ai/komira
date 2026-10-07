# =============================================================================
# test_corpus_checks.mojo -- each check in corpus.mojo, fed a planted defect.
# =============================================================================
#
# test_corpus passes on a clean corpus; this file shows each check can fail,
# on made-up registrations, file lists and texts (no file is read):
#   a case registered in two shards, or under a shard it does not name;
#   a case with no expectation, with two, and an orphan expectation file;
#   a plan nested past the wire's depth limit (plan_wire_admit refuses it);
#   an expectation whose column type differs from the plan's, with a message
#   that names both sides; one with no derivation; one whose order header
#   differs from the case's policy;
#   .err files: the accepted form and each refusal;
#   a dataset line with a wrong member, a wrong kind, a null in a non-nullable
#   column, and an orphan dataset file.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_plan_expr.expr import BIN_EQ, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_harness import CanonPolicy
from komira_plan_ir.logical_plan import LogicalPlan
from komira_plan_conformance import (
    Case,
    Registered,
    all_datasets,
    check_dataset,
    check_dataset_files,
    check_expectation,
    check_files,
    check_partition,
    check_schema,
    check_wire,
    parse_err,
)
from komira_plan_conformance.datasets import bool_pairs, ints_nullable, scan


def _ints() raises -> LogicalPlan:
    return scan(ints_nullable())


def _too_deep() raises -> LogicalPlan:
    var p = scan(ints_nullable())
    for _ in range(40):
        p = LogicalPlan.filter(
            Expr.binary(
                BIN_EQ,
                Expr.col_ref("id"),
                Expr.literal(ScalarValue.from_int64(Int64(1))),
            ),
            p^,
        )
    return p^


def _case(id: String, shard: String) -> Case:
    return Case.hand(id, shard, _ints, CanonPolicy.unordered())


def _any_contains(problems: List[String], needle: String) -> Bool:
    for p in problems:
        if p.find(needle) >= 0:
            return True
    return False


def _shards() -> List[String]:
    return [String("filter_3vl"), String("agg_grouping")]


def test_partition_clean() raises:
    var regs: List[Registered] = [
        Registered("filter_3vl", _case("a", "filter_3vl")),
        Registered("agg_grouping", _case("b", "agg_grouping")),
    ]
    assert_equal(len(check_partition(regs, _shards())), 0)


def test_partition_case_in_two_shards() raises:
    var regs: List[Registered] = [
        Registered("filter_3vl", _case("a", "filter_3vl")),
        Registered("agg_grouping", _case("a", "filter_3vl")),
    ]
    var p = check_partition(regs, _shards())
    assert_true(_any_contains(p, "registered 2 times, in shards filter_3vl, agg_grouping"))
    assert_true(_any_contains(p, "registered in shard 'agg_grouping' but names shard 'filter_3vl'"))


def test_partition_unknown_shard() raises:
    var regs: List[Registered] = [Registered("nope", _case("a", "nope"))]
    assert_true(_any_contains(check_partition(regs, _shards()), "which is not a shard"))


def test_files_clean() raises:
    var cases: List[Case] = [_case("a", "filter_3vl")]
    assert_equal(len(check_files(cases, [String("expect/filter_3vl/a.tsv")])), 0)


def test_files_missing_second_and_orphan() raises:
    var cases: List[Case] = [_case("a", "filter_3vl"), _case("b", "filter_3vl")]
    var p = check_files(
        cases,
        [
            String("expect/filter_3vl/a.tsv"),
            String("expect/filter_3vl/a.err"),
            String("expect/filter_3vl/zzz.tsv"),
            String("expect/stray.tsv"),
        ],
    )
    assert_true(_any_contains(p, "filter_3vl/b (HAND) has no expectation file expect/filter_3vl/b.tsv"))
    assert_true(_any_contains(p, "second expectation file expect/filter_3vl/a.err"))
    assert_true(_any_contains(p, "expect/filter_3vl/zzz.tsv is an orphan"))
    assert_true(_any_contains(p, "expect/stray.tsv is an orphan"))
    assert_equal(len(p), 4)


def test_wire_refuses_a_plan_past_the_depth_limit() raises:
    var problems = List[String]()
    _ = check_wire(Case.hand("deep", "filter_3vl", _too_deep, CanonPolicy.unordered()), problems)
    assert_true(_any_contains(problems, "plan_wire_admit refused its bytes: PLAN_WIRE_TOO_DEEP"))


def test_wire_clean() raises:
    var problems = List[String]()
    var plan = check_wire(_case("a", "filter_3vl"), problems)
    assert_equal(len(problems), 0)
    assert_true(Bool(plan))


comptime _HEAD = "#! komira-plan-conformance v1\n#  order: none\n#  float: ulps=0\n"


def test_expectation_clean() raises:
    var plan = _ints()
    var text = String(_HEAD) + "# derivation: §1.2\nid:int64\tx:int64?\n1\t1\n"
    assert_equal(len(check_expectation(_case("a", "filter_3vl"), text, plan)), 0)


def test_expectation_wrong_type_names_both_sides() raises:
    var plan = _ints()
    var text = String(_HEAD) + "# derivation: §1.2\nid:int64\tx:int32?\n"
    var p = check_expectation(_case("a", "filter_3vl"), text, plan)
    assert_equal(len(p), 1)
    assert_true(p[0].find("the expectation says `x:int32?`") >= 0)
    assert_true(p[0].find("the plan's root output schema says `x:int64?`") >= 0)
    assert_true(p[0].find("which side is wrong") >= 0)


def test_schema_column_count() raises:
    var p = check_schema("l", [String("a:int64")], [String("a:int64"), String("b:bool?")])
    assert_true(_any_contains(p, "the expectation has 1 columns [a:int64]"))


def test_expectation_needs_a_derivation() raises:
    var plan = _ints()
    var text = String(_HEAD) + "id:int64\tx:int64?\n"
    assert_true(_any_contains(check_expectation(_case("a", "filter_3vl"), text, plan), "needs a `# derivation:` comment"))
    # A derivation that cites no item is refused too.
    var uncited = String(_HEAD) + "# derivation: by inspection\nid:int64\tx:int64?\n"
    assert_true(_any_contains(check_expectation(_case("a", "filter_3vl"), uncited, plan), "needs a `# derivation:` comment"))


def test_expectation_policy_must_match_the_case() raises:
    var plan = _ints()
    var text = String(
        "#! komira-plan-conformance v1\n#  order: total\n#  float: ulps=0\n"
        "# derivation: §1.2\nid:int64\tx:int64?\n"
    )
    assert_true(_any_contains(check_expectation(_case("a", "filter_3vl"), text, plan), "order/float header differs"))


def test_err_accepted() raises:
    var e = parse_err("# derivation: §5.3\nprefix: PLAN_ENDPOINT_EXEC_FAILED(-3)\nkind: Arithmetic\n")
    assert_equal(e.prefix(), "PLAN_ENDPOINT_EXEC_FAILED(-3)")
    assert_equal(e.kind, "Arithmetic")
    assert_true(not e.text)


def test_err_refusals() raises:
    with assert_raises(contains="needs both"):
        _ = parse_err("prefix: PLAN_ENDPOINT_X(1)\n")
    with assert_raises(contains="does not start with"):
        _ = parse_err("prefix: ENDPOINT_X(1)\nkind: k\n")
    with assert_raises(contains="integer <code>"):
        _ = parse_err("prefix: PLAN_ENDPOINT_X(1a)\nkind: k\n")
    with assert_raises(contains="<NAME> in [A-Z0-9_]"):
        _ = parse_err("prefix: PLAN_ENDPOINT_x(1)\nkind: k\n")
    with assert_raises(contains="unknown key"):
        _ = parse_err("prefix: PLAN_ENDPOINT_X(1)\nkind: k\nwhy: no\n")
    with assert_raises(contains="a second kind"):
        _ = parse_err("prefix: PLAN_ENDPOINT_X(1)\nkind: k\nkind: j\n")


def test_dataset_clean() raises:
    assert_equal(len(check_dataset(bool_pairs(), '{"id": 1, "a": true, "b": null}\n')), 0)


def test_dataset_defects() raises:
    var p = check_dataset(
        bool_pairs(),
        '{"id": 1, "b": true, "a": null}\n{"id": null, "a": true, "b": true}\n'
        + '{"id": 3, "a": 1, "b": true}\n{"id": 4, "a": true}\n[1]\n',
    )
    assert_true(_any_contains(p, ":1: member 1 is 'b', the schema's column is 'a'"))
    assert_true(_any_contains(p, ":2: 'id' is null in a non-nullable column"))
    assert_true(_any_contains(p, ":3: 'a' is 1, not a bool"))
    assert_true(_any_contains(p, ":4: 2 members, the schema 3 columns"))
    assert_true(_any_contains(p, ":5: not a JSON object"))


def test_dataset_files() raises:
    var p = check_dataset_files(
        all_datasets(),
        [String("bool_pairs.jsonl"), String("groups.jsonl"), String("extra.csv")],
    )
    assert_true(_any_contains(p, "datasets/ints_nullable.jsonl is missing"))
    assert_true(_any_contains(p, "datasets/extra.csv is an orphan"))
    assert_equal(len(p), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
