# =============================================================================
# optimizer_result: the non-raising return channel
# =============================================================================
#
# `OptimizeResult` carries a plan iff its status is OPTIMIZE_OK, and
# `_classify` maps a caught error's text to one of three failure classes by
# the shared token table of komira_plan_tokens, whose strings are checked here
# against the constants the raising modules export. Each test names the defect
# it catches.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_ir.logical_plan import LogicalPlan, SOURCE_PARQUET, PLAN_SCAN
from komira_scan_source.scan_resolver import (
    SCAN_BINDING_EPOCH_MISMATCH,
    SCAN_BINDING_HANDLE_NOT_BOUND,
)
from komira_plan_tokens import RefusalClass, plan_refusal_tokens, token_class
from komira_optimizer.optimizer_result import (
    OptimizeResult,
    OPTIMIZE_OK,
    OPTIMIZE_ERR_SCAN_BINDING,
    OPTIMIZE_ERR_UNRESOLVED_DEPS,
    OPTIMIZE_ERR_PASS_REFUSED,
    OPTIMIZE_REFUSAL_UNRESOLVED_DEPS,
    _classify,
)


def _plan() -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    return LogicalPlan.scan(String("r.parquet"), SOURCE_PARQUET, sb.build())


def _wrapped(token: StaticString) -> String:
    """The token embedded in a longer message, as a raiser writes it."""
    return String("pass x refused: ") + String(token) + String(" (detail)")


def test_status_codes_are_zero_and_distinct_negatives() raises:
    """Catches a renumbering that makes two failure classes share a code or
    makes a failure non-negative."""
    assert_equal(OPTIMIZE_OK, Int32(0))
    assert_true(OPTIMIZE_ERR_SCAN_BINDING < 0)
    assert_true(OPTIMIZE_ERR_UNRESOLVED_DEPS < 0)
    assert_true(OPTIMIZE_ERR_PASS_REFUSED < 0)
    assert_true(OPTIMIZE_ERR_SCAN_BINDING != OPTIMIZE_ERR_UNRESOLVED_DEPS)
    assert_true(OPTIMIZE_ERR_UNRESOLVED_DEPS != OPTIMIZE_ERR_PASS_REFUSED)
    assert_true(OPTIMIZE_ERR_SCAN_BINDING != OPTIMIZE_ERR_PASS_REFUSED)


def test_classify_scan_binding_tokens() raises:
    """Catches a missing or mis-mapped scan-binding arm (a caller-fixable
    refusal reported as a generic pass refusal)."""
    assert_equal(_classify(_wrapped(SCAN_BINDING_EPOCH_MISMATCH)), OPTIMIZE_ERR_SCAN_BINDING)
    assert_equal(_classify(_wrapped(SCAN_BINDING_HANDLE_NOT_BOUND)), OPTIMIZE_ERR_SCAN_BINDING)


def test_classify_unresolved_deps_token() raises:
    """Catches a missing round-cap arm."""
    assert_equal(
        _classify(_wrapped(OPTIMIZE_REFUSAL_UNRESOLVED_DEPS)),
        OPTIMIZE_ERR_UNRESOLVED_DEPS,
    )


def test_classify_unknown_text_is_still_a_failure() raises:
    """Catches a fall-through that degrades an unrecognised message to OK."""
    assert_equal(_classify(String("some pass said no")), OPTIMIZE_ERR_PASS_REFUSED)
    assert_equal(_classify(String("")), OPTIMIZE_ERR_PASS_REFUSED)


def _status_for(cls: RefusalClass) raises -> Int32:
    """The status each shared-table class must classify to."""
    if cls == RefusalClass.SCAN_BINDING:
        return OPTIMIZE_ERR_SCAN_BINDING
    if cls == RefusalClass.UNRESOLVED_DEPS:
        return OPTIMIZE_ERR_UNRESOLVED_DEPS
    if cls == RefusalClass.PRODUCER_BUG:
        return OPTIMIZE_ERR_PASS_REFUSED
    raise Error(String("no status pinned for class ") + cls.name())


def test_classify_every_table_token_by_its_class() raises:
    """Catches a `_classify` that reads its own arms instead of the table (a
    token added to the table is not classified), maps a class to the wrong
    status, or gives a physical-plan door token a status of its own."""
    var t = plan_refusal_tokens()
    assert_true(len(t) > 0)
    for i in range(len(t)):
        assert_equal(
            _classify(_wrapped(t[i].token)),
            _status_for(t[i].refusal_class),
            String(t[i].token),
        )
        assert_equal(
            _classify(String(t[i].token)),
            _status_for(t[i].refusal_class),
            String(t[i].token) + " at offset 0",
        )


def _table_class_name(token: StaticString) -> String:
    """The class the shared table gives `token`, or "NONE" if it names no
    row."""
    var cls = token_class(token)
    if not cls:
        return String("NONE")
    return cls.value().name()


def test_table_strings_equal_the_raisers_constants() raises:
    """Catches a table row that drifts from the constant its raiser uses: the
    raiser's refusal would no longer be classified."""
    assert_equal(_table_class_name(SCAN_BINDING_EPOCH_MISMATCH), String("SCAN_BINDING"))
    assert_equal(_table_class_name(SCAN_BINDING_HANDLE_NOT_BOUND), String("SCAN_BINDING"))
    assert_equal(_table_class_name(OPTIMIZE_REFUSAL_UNRESOLVED_DEPS), String("UNRESOLVED_DEPS"))


def test_classify_two_tokens_answers_as_the_former_arms_did() raises:
    """Catches a table order that changes the answer for a message holding a
    scan-binding or round-cap token and a physical-plan door token: the
    former arms ignored the door token."""
    assert_equal(
        _classify(String("PHYSICAL_PLAN_PURITY_UNCHECKABLE; ") + _wrapped(SCAN_BINDING_HANDLE_NOT_BOUND)),
        OPTIMIZE_ERR_SCAN_BINDING,
    )
    assert_equal(
        _classify(String("PHYSICAL_PLAN_IR_VERSION_MISMATCH; ") + _wrapped(OPTIMIZE_REFUSAL_UNRESOLVED_DEPS)),
        OPTIMIZE_ERR_UNRESOLVED_DEPS,
    )


def test_ok_carries_the_plan_once() raises:
    """Catches an `ok` that does not set OPTIMIZE_OK, a `take_plan` that
    leaves the plan in place, and a second `take_plan` that aborts instead of
    returning None."""
    var r = OptimizeResult.ok(_plan())
    assert_true(r.is_ok())
    assert_equal(r.status(), OPTIMIZE_OK)
    assert_equal(r.message(), String(""))
    assert_true(r.has_plan())
    var p = r.take_plan()
    assert_true(Bool(p), "first take yields the plan")
    assert_equal(Int(p.value().tag), Int(PLAN_SCAN))
    assert_false(r.has_plan(), "the plan moved out")
    assert_true(r.is_ok(), "the status is a record and does not change")
    assert_false(Bool(r.take_plan()), "a second take is None, not an abort")


def test_err_never_reports_ok() raises:
    """Catches an `err` that trusts a non-negative status: a success with no
    plan is the state the invariant forbids."""
    var forced = OptimizeResult.err(OPTIMIZE_OK, String("m"))
    assert_equal(forced.status(), OPTIMIZE_ERR_PASS_REFUSED)
    assert_false(forced.is_ok())
    var positive = OptimizeResult.err(Int32(5), String("m"))
    assert_equal(positive.status(), OPTIMIZE_ERR_PASS_REFUSED)
    var kept = OptimizeResult.err(OPTIMIZE_ERR_UNRESOLVED_DEPS, String("why"))
    assert_equal(kept.status(), OPTIMIZE_ERR_UNRESOLVED_DEPS, "a negative status is kept")
    assert_equal(kept.message(), String("why"))
    assert_false(kept.has_plan())
    assert_false(Bool(kept.take_plan()), "a failure yields no plan")


def test_from_error_classifies_and_keeps_the_text() raises:
    """Catches a `from_error` that skips classification or rewrites the
    raiser's message."""
    var msg = _wrapped(SCAN_BINDING_EPOCH_MISMATCH)
    var r = OptimizeResult.from_error(msg.copy())
    assert_equal(r.status(), OPTIMIZE_ERR_SCAN_BINDING)
    assert_equal(r.message(), msg)
    assert_false(r.is_ok())


def test_unwrap_or_raise_returns_the_plan_or_the_original_error() raises:
    """Catches an adapter that raises on success, or raises a different text
    on failure."""
    var good = OptimizeResult.ok(_plan())
    var p = good.unwrap_or_raise()
    assert_equal(Int(p.tag), Int(PLAN_SCAN))

    var bad = OptimizeResult.err(OPTIMIZE_ERR_PASS_REFUSED, String("pass q refused"))
    var raised = False
    try:
        _ = bad.unwrap_or_raise()
    except e:
        raised = True
        assert_equal(String(e), String("pass q refused"))
    assert_true(raised, "a failure must raise")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
