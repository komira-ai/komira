# =============================================================================
# A PLAN_EXCHANGE node is refused by name by the SDK's two plan walks that
# used to fall through on an unknown tag.
# =============================================================================
#
#   * `filter_refusal.keep_refusal_at_root` (via `_innermost_refusal`) cannot
#     raise, so it CARRIES the refusal: the plan it returns is the
#     `select(): PLAN_EXCHANGE: ...` refusal over the exchange, at the root,
#     even when the exchange sits under other verbs. Mutant: delete the
#     exchange arm; the walk falls through, returns the plan as it was, and
#     `test_keep_refusal_at_root_refuses_an_exchange*` go red.
#   * `plan_validator._validate_plan_node` raises
#     `VALIDATE_PLAN_EXCHANGE_REFUSED` by name. Mutant: delete the arm; the
#     generic "unknown plan tag 18" message is raised and the name assertion
#     goes red.
#   * `plan_validator._subtree_has_offset_limit` cannot raise, so it descends
#     the exchange: an offset LIMIT under an exchange still trips the RANGE
#     invariant. Mutant: delete the arm; the predicate answers False, the
#     nested slice passes `assert_offset_limit_is_root`, and the test goes red.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    ExprArray,
    LogicalPlan,
    PLAN_PROJECT,
    PLAN_EXCHANGE,
    SOURCE_PARQUET,
    EXCHANGE_KIND_GATHER,
)

from komira_sdk.filter_refusal import (
    _is_refusal,
    keep_refusal_at_root,
    SDK_PLAN_EXCHANGE_REFUSED,
)
from komira_sdk.plan_validator import (
    validate_plan,
    assert_offset_limit_is_root,
    plan_contains_range_offset,
    VALIDATE_PLAN_EXCHANGE_REFUSED,
)


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    return sb.build()


def _scan() -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema())


def _exchange(var child: LogicalPlan) raises -> LogicalPlan:
    return LogicalPlan.exchange(child^, EXCHANGE_KIND_GATHER)


def _refusal_name(p: LogicalPlan) -> String:
    return p._project.value()[].exprs[0].col_ref_name()


def test_keep_refusal_at_root_refuses_an_exchange() raises:
    var r = keep_refusal_at_root(_exchange(_scan()))
    assert_equal(Int(r.tag), Int(PLAN_PROJECT))
    assert_true(_is_refusal(r), "not a carried refusal")
    assert_true(String(SDK_PLAN_EXCHANGE_REFUSED) in _refusal_name(r), _refusal_name(r))
    assert_equal(Int(r._project.value()[].child[].tag), Int(PLAN_EXCHANGE))


def test_keep_refusal_at_root_refuses_an_exchange_under_a_verb() raises:
    """Under a filter, the refusal is still found and becomes the root."""
    var f = LogicalPlan.filter(Expr.col_ref("a"), _exchange(_scan()))
    var r = keep_refusal_at_root(f^)
    assert_true(_is_refusal(r), "the exchange under a filter was walked past")
    assert_true("PLAN_EXCHANGE" in _refusal_name(r), _refusal_name(r))


def test_validate_plan_refuses_an_exchange_by_name() raises:
    var raised = False
    try:
        validate_plan(_exchange(_scan()))
    except e:
        raised = True
        assert_true(String(VALIDATE_PLAN_EXCHANGE_REFUSED) in String(e), String(e))
    assert_true(raised, "validate_plan accepted an exchange")


def test_an_offset_limit_under_an_exchange_still_trips_the_range_invariant() raises:
    var nested = _exchange(LogicalPlan.limit(3, _scan(), offset=2))
    assert_true(plan_contains_range_offset(nested), "offset under exchange not seen")
    var raised = False
    try:
        assert_offset_limit_is_root(nested)
    except e:
        raised = True
        assert_true("RANGE invariant" in String(e), String(e))
    assert_true(raised, "a nested slice under an exchange passed the RANGE check")


def test_an_exchange_with_no_payload_holds_no_offset() raises:
    """An exchange node whose payload is missing answers False instead of
    dereferencing the empty payload. Catches the payload check dropped (the
    walk would abort on `Optional.value()`)."""
    assert_false(plan_contains_range_offset(LogicalPlan(PLAN_EXCHANGE, _schema())))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
