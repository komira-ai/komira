# =============================================================================
# refusal_tokens: the shared table of plan refusal tokens
# =============================================================================
#
# The table's rows are pinned literally: the raisers' constants live in
# packages this one may not import (komira_scan_source, komira_plan_ir,
# komira_optimizer), so each string below is the value of the raiser's
# constant, copied. Each test names the defect it catches.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_plan_tokens import (
    RefusalClass,
    RefusalToken,
    plan_refusal_tokens,
    token_class,
    message_class,
)


def _expected() -> List[RefusalToken]:
    """The table as the raisers spell it, in table order."""
    var t = List[RefusalToken]()
    # komira_scan_source.scan_resolver
    t.append(RefusalToken("SCAN_BINDING_EPOCH_MISMATCH", RefusalClass.SCAN_BINDING))
    t.append(RefusalToken("SCAN_BINDING_HANDLE_NOT_BOUND", RefusalClass.SCAN_BINDING))
    # komira_optimizer.optimizer_result, OPTIMIZE_REFUSAL_UNRESOLVED_DEPS
    t.append(RefusalToken("OPTIMIZER_UNRESOLVED_SCALAR_DEPS", RefusalClass.UNRESOLVED_DEPS))
    # komira_plan_ir.physical_plan
    t.append(RefusalToken("PHYSICAL_PLAN_IR_VERSION_MISMATCH", RefusalClass.PRODUCER_BUG))
    t.append(RefusalToken("PHYSICAL_PLAN_IR_VERSION_UNCHECKABLE", RefusalClass.PRODUCER_BUG))
    # komira_plan_ir.physical_plan_purity_gate
    t.append(RefusalToken("PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN", RefusalClass.PRODUCER_BUG))
    t.append(RefusalToken("PHYSICAL_PLAN_PURITY_UNMODELLED_EXPR_TAG", RefusalClass.PRODUCER_BUG))
    t.append(RefusalToken("PHYSICAL_PLAN_PURITY_UNCHECKABLE", RefusalClass.PRODUCER_BUG))
    return t^


def test_table_is_the_pinned_rows_in_order() raises:
    """Catches a dropped, added, renamed or reordered token and a token mapped
    to the wrong class."""
    var got = plan_refusal_tokens()
    var want = _expected()
    assert_equal(len(got), len(want), "row count")
    for i in range(len(want)):
        assert_equal(String(got[i].token), String(want[i].token), "token at row " + String(i))
        assert_equal(
            got[i].refusal_class.name(),
            want[i].refusal_class.name(),
            "class of " + String(want[i].token),
        )


def test_no_token_appears_twice() raises:
    """Catches a duplicated row, which would give one token two classes or
    two rows to keep in step."""
    var t = plan_refusal_tokens()
    for i in range(len(t)):
        for j in range(i + 1, len(t)):
            assert_true(
                String(t[i].token) != String(t[j].token),
                "duplicate token " + String(t[i].token),
            )


def test_every_token_has_exactly_one_known_class() raises:
    """Catches a row whose class is not one of the four, and an exact lookup
    that answers with another row's class."""
    var t = plan_refusal_tokens()
    for i in range(len(t)):
        assert_true(t[i].refusal_class.is_known(), String(t[i].token))
        var cls = token_class(t[i].token)
        assert_true(Bool(cls), String(t[i].token))
        assert_equal(cls.value().name(), t[i].refusal_class.name(), String(t[i].token))


def test_no_token_contains_another() raises:
    """Catches a token that is a substring of another: a message holding the
    longer one would also match the shorter, and its class would depend on
    table order."""
    var t = plan_refusal_tokens()
    for i in range(len(t)):
        for j in range(len(t)):
            if i == j:
                continue
            assert_true(
                String(t[i].token).find(String(t[j].token)) < 0,
                String(t[j].token) + " is inside " + String(t[i].token),
            )


def test_pass_refusal_names_no_token_and_the_others_do() raises:
    """Catches a token given the catch-all class (a no-op row) and a class
    left with no token."""
    var t = plan_refusal_tokens()
    var counts = List[Int](length=4, fill=0)
    for i in range(len(t)):
        counts[t[i].refusal_class.code] += 1
    assert_equal(counts[RefusalClass.PASS_REFUSAL.code], 0)
    assert_equal(counts[RefusalClass.PRODUCER_BUG.code], 5)
    assert_equal(counts[RefusalClass.SCAN_BINDING.code], 2)
    assert_equal(counts[RefusalClass.UNRESOLVED_DEPS.code], 1)


def test_token_class_is_exact() raises:
    """Catches an exact lookup that matches a substring, a prefix or a
    different case."""
    assert_false(Bool(token_class("x SCAN_BINDING_EPOCH_MISMATCH")))
    assert_false(Bool(token_class("SCAN_BINDING_EPOCH")))
    assert_false(Bool(token_class("scan_binding_epoch_mismatch")))
    assert_false(Bool(token_class("")))
    var cls = token_class(String("OPTIMIZER_UNRESOLVED_SCALAR_DEPS"))
    assert_true(Bool(cls))
    assert_true(cls.value() == RefusalClass.UNRESOLVED_DEPS)


def test_message_class_finds_a_token_anywhere() raises:
    """Catches a search that misses a token at the start (a `> 0` for
    `>= 0`), in the middle or at the end of a message."""
    var at_start = message_class("PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN: node 3")
    assert_true(Bool(at_start), "a token at offset 0")
    assert_true(at_start.value() == RefusalClass.PRODUCER_BUG)
    var middle = message_class(String("bind: SCAN_BINDING_HANDLE_NOT_BOUND (slot 4)"))
    assert_true(middle.value() == RefusalClass.SCAN_BINDING)
    var at_end = message_class("round cap hit: OPTIMIZER_UNRESOLVED_SCALAR_DEPS")
    assert_true(at_end.value() == RefusalClass.UNRESOLVED_DEPS)


def test_message_class_of_unnamed_text_is_none() raises:
    """Catches a search that answers a class for a message holding no token,
    or for a token spelled in another case."""
    assert_false(Bool(message_class("pass x refused")))
    assert_false(Bool(message_class("")))
    assert_false(Bool(message_class("scan_binding_epoch_mismatch")))


def test_message_class_of_two_tokens_is_the_earlier_row() raises:
    """Catches a search that answers with the later row: the optimizer's
    classification of a message holding a scan-binding token and a
    physical-plan token depends on it."""
    var both = message_class(
        "PHYSICAL_PLAN_PURITY_UNCHECKABLE after SCAN_BINDING_EPOCH_MISMATCH"
    )
    assert_true(both.value() == RefusalClass.SCAN_BINDING)


def test_class_names_and_known_range() raises:
    """Catches a wrong name and an off-by-one at either end of the known
    range."""
    assert_equal(RefusalClass.PASS_REFUSAL.name(), String("PASS_REFUSAL"))
    assert_equal(RefusalClass.PRODUCER_BUG.name(), String("PRODUCER_BUG"))
    assert_equal(RefusalClass.SCAN_BINDING.name(), String("SCAN_BINDING"))
    assert_equal(RefusalClass.UNRESOLVED_DEPS.name(), String("UNRESOLVED_DEPS"))
    assert_equal(RefusalClass(7).name(), String("UNKNOWN(7)"))
    assert_true(RefusalClass(0).is_known())
    assert_true(RefusalClass(3).is_known())
    assert_false(RefusalClass(-1).is_known())
    assert_false(RefusalClass(4).is_known())


def test_class_equality() raises:
    """Catches an `__eq__` or `__ne__` that ignores the code."""
    assert_true(RefusalClass.SCAN_BINDING == RefusalClass(2))
    assert_false(RefusalClass.SCAN_BINDING == RefusalClass.PRODUCER_BUG)
    assert_true(RefusalClass.SCAN_BINDING != RefusalClass.PRODUCER_BUG)
    assert_false(RefusalClass.PASS_REFUSAL != RefusalClass(0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
