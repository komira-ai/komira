# =============================================================================
# test_route_decision.mojo — RouteDecision is DENY unless built otherwise, and
# a requirement leaves only a governed decision.
# =============================================================================
#
# Defects each test catches:
#   * the zero value reads as governed or public (a forgotten field opens);
#   * `requirement()` returns on a deny or a public decision (the inert
#     admin-on-empty-kind requirement would be checked);
#   * a governed decision loses its action, kind or id.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_authz_api import AuthzAction, AuthzResource
from komira_resource_gate import (
    ROUTE_OUTCOME_DENY,
    ROUTE_OUTCOME_GOVERNED,
    ROUTE_OUTCOME_PUBLIC,
    ResourceRequirement,
    RouteDecision,
)


def _requirement_error(d: RouteDecision) -> String:
    """The message `requirement()` raises, or "" when it returns."""
    try:
        _ = d.requirement()
    except e:
        return String(e)
    return String("")


def test_zero_value_is_deny() raises:
    var d = RouteDecision()
    assert_false(d.is_governed())
    assert_false(d.is_public())
    assert_equal(d.outcome(), ROUTE_OUTCOME_DENY)
    var e = RouteDecision.deny()
    assert_false(e.is_governed())
    assert_false(e.is_public())
    assert_equal(e.outcome(), ROUTE_OUTCOME_DENY)
    # A list slot filled with the default denies too.
    var slots = List[RouteDecision](length=2, fill=RouteDecision())
    assert_false(slots[1].is_governed() or slots[1].is_public())


def test_requirement_on_deny_raises() raises:
    assert_equal(
        _requirement_error(RouteDecision()),
        "RouteDecision.requirement: the decision is not governed (outcome 0)",
    )


def test_requirement_on_public_raises() raises:
    var d = RouteDecision.public()
    assert_true(d.is_public())
    assert_false(d.is_governed())
    assert_equal(d.outcome(), ROUTE_OUTCOME_PUBLIC)
    assert_equal(
        _requirement_error(d),
        "RouteDecision.requirement: the decision is not governed (outcome 2)",
    )


def test_governed_carries_its_requirement() raises:
    var d = RouteDecision.governed(
        AuthzAction.write(), AuthzResource(kind=String("repo"), id=String("r1"))
    )
    assert_true(d.is_governed())
    assert_false(d.is_public())
    assert_equal(d.outcome(), ROUTE_OUTCOME_GOVERNED)
    assert_equal(_requirement_error(d), String(""))
    var r = d.requirement()
    assert_equal(r.action.name, "write")
    assert_equal(r.resource.kind, "repo")
    assert_equal(r.resource.id, "r1")
    var d2 = RouteDecision.governed(
        ResourceRequirement(
            AuthzAction.read(), AuthzResource(kind=String("doc"), id=String(""))
        )
    )
    var r2 = d2.requirement()
    assert_equal(r2.action.name, "read")
    assert_equal(r2.resource.kind, "doc")
    assert_equal(r2.resource.id, "")


def main() raises:
    test_zero_value_is_deny()
    test_requirement_on_deny_raises()
    test_requirement_on_public_raises()
    test_governed_carries_its_requirement()
    print("PASS komira_resource_gate test_route_decision")
