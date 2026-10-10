# =============================================================================
# refusal_tokens: the shared table of plan refusal tokens
# =============================================================================
#
# The table's rows are pinned literally: the constants live in packages this
# one may not import (komira_scan_source, komira_plan_ir, komira_optimizer),
# so each string below is the value of the declared constant, copied. Nothing
# in the tree raises OPTIMIZER_UNRESOLVED_SCALAR_DEPS yet. Each test names the defect it catches.
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
    """The table as the declaring packages spell it, in table order."""
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


def _name(cls: Optional[RefusalClass]) -> String:
    """The class's name, or "NONE" for no class: a lookup that misses fails
    an assertion instead of aborting on `.value()`."""
    if not cls:
        return String("NONE")
    return cls.value().name()


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
        assert_equal(_name(token_class(t[i].token)), t[i].refusal_class.name(), String(t[i].token))


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


def _with_byte(tok: String, k: Int, b: String) -> String:
    """`tok` with its byte at offset `k` replaced by `b`."""
    var n = tok.byte_length()
    return String(tok[byte=0:k]) + b + String(tok[byte = k + 1 : n])


def _parts_and_one_byte_changes(tok: String) -> List[String]:
    """Near misses of `tok`, each holding no whole token, in this order: `tok`
    with its last byte dropped, with its first byte dropped, wholly
    lowercased, with its first letter lowercased, with its last letter
    lowercased (every token starts and ends with a capital letter), then
    `tok` with the byte at offset k replaced by `#` (no token holds one) for
    every k from 0 to its length - 1. All but the first three keep the
    length, so a compare that checks the length and then skips any one
    offset still meets a differing byte."""
    var n = tok.byte_length()
    var v = List[String]()
    v.append(String(tok[byte = 0 : n - 1]))
    v.append(String(tok[byte = 1:n]))
    v.append(tok.lower())
    v.append(_with_byte(tok, 0, String(tok[byte=0:1]).lower()))
    v.append(_with_byte(tok, n - 1, String(tok[byte = n - 1 : n]).lower()))
    for k in range(n):
        v.append(_with_byte(tok, k, String("#")))
    return v^


def test_near_misses_are_not_tokens() raises:
    """Guards the vectors below: each differs from its row, all but the first
    three keep the row's length, vector 5 + k is the row with only its byte
    at offset k replaced by `#` (checked against slices of the row, not
    against the helper that built it), and none contains a token, so a NONE
    expected for it is the right answer."""
    var t = plan_refusal_tokens()
    for i in range(len(t)):
        var tok = String(t[i].token)
        var n = tok.byte_length()
        var v = _parts_and_one_byte_changes(tok)
        assert_equal(len(v), 5 + n, "variants of " + tok)
        for k in range(n):
            var w = v[5 + k]
            var at = "offset " + String(k) + " of " + tok + ": " + w
            assert_equal(w.byte_length(), n, "length at " + at)
            assert_equal(String(w[byte = k : k + 1]), String("#"), "no # at " + at)
            assert_equal(String(w[byte=0:k]), String(tok[byte=0:k]), "prefix at " + at)
            assert_equal(String(w[byte = k + 1 : n]), String(tok[byte = k + 1 : n]), "suffix at " + at)
        for k in range(len(v)):
            assert_true(v[k] != tok, "variant " + String(k) + " of " + tok)
            if k >= 3:
                assert_equal(v[k].byte_length(), tok.byte_length(), "length of " + v[k])
            for j in range(len(t)):
                assert_true(v[k].find(String(t[j].token)) < 0, String(t[j].token) + " is inside " + v[k])


def test_token_class_is_exact() raises:
    """Catches an exact lookup that matches a substring, a prefix, a suffix,
    a longer input or a different case, and one that compares only part of a
    row: for every row, the row with its first or last byte dropped, a byte
    appended or prepended, one byte replaced at any one offset, one letter
    or every letter lowercased gets no class."""
    assert_false(Bool(token_class("x SCAN_BINDING_EPOCH_MISMATCH")))
    assert_false(Bool(token_class("SCAN_BINDING_EPOCH")))
    assert_false(Bool(token_class("scan_binding_epoch_mismatch")))
    assert_false(Bool(token_class("")))
    assert_equal(_name(token_class(String("OPTIMIZER_UNRESOLVED_SCALAR_DEPS"))), String("UNRESOLVED_DEPS"))
    var t = plan_refusal_tokens()
    for i in range(len(t)):
        var tok = String(t[i].token)
        assert_equal(_name(token_class(tok + String(" "))), String("NONE"), "longer than " + tok)
        assert_equal(_name(token_class(String(" ") + tok)), String("NONE"), "prepended to " + tok)
        var v = _parts_and_one_byte_changes(tok)
        for k in range(len(v)):
            assert_equal(_name(token_class(v[k])), String("NONE"), "variant of " + tok + ": " + v[k])


def test_message_class_finds_a_token_anywhere() raises:
    """Catches a search that misses a token at the start (a `> 0` for
    `>= 0`), in the middle or at the end of a message."""
    assert_equal(
        _name(message_class("PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN: node 3")),
        String("PRODUCER_BUG"),
        "a token at offset 0",
    )
    assert_equal(
        _name(message_class(String("bind: SCAN_BINDING_HANDLE_NOT_BOUND (slot 4)"))),
        String("SCAN_BINDING"),
    )
    assert_equal(
        _name(message_class("round cap hit: OPTIMIZER_UNRESOLVED_SCALAR_DEPS")),
        String("UNRESOLVED_DEPS"),
    )


def test_message_class_finds_every_row() raises:
    """Catches a search that skips a row (a loop bound of `len(table) - 1`
    misses the last door token), alone or inside a longer message. No token
    contains another, so each message names one row."""
    var t = plan_refusal_tokens()
    for i in range(len(t)):
        var tok = String(t[i].token)
        var want = t[i].refusal_class.name()
        assert_equal(_name(message_class(tok)), want, "alone: " + tok)
        assert_equal(
            _name(message_class(String("refused: ") + tok + String(" (node 2)"))),
            want,
            "inside a message: " + tok,
        )


def test_message_class_of_unnamed_text_is_none() raises:
    """Catches a search that answers a class for a message holding no token,
    or for a token spelled in another case."""
    assert_false(Bool(message_class("pass x refused")))
    assert_false(Bool(message_class("")))
    assert_false(Bool(message_class("scan_binding_epoch_mismatch")))


def test_message_class_of_a_part_of_a_token_is_none() raises:
    """Catches a search by token family: one that matches a prefix of a token
    of any length (a fixed 20-byte prefix gives `PHYSICAL_PLAN_IR_VERSION_OK`
    a class) or a suffix, one that compares a window with any one offset
    skipped, and one that ignores case. For every row, the row with its
    first or last byte dropped, one byte replaced at any one offset, one
    letter or every letter lowercased gets no class, alone or inside a
    longer message."""
    var t = plan_refusal_tokens()
    for i in range(len(t)):
        var parts = _parts_and_one_byte_changes(String(t[i].token))
        for k in range(len(parts)):
            assert_equal(_name(message_class(parts[k])), String("NONE"), "alone: " + parts[k])
            assert_equal(
                _name(message_class(String("refused: ") + parts[k] + String(" (node 2)"))),
                String("NONE"),
                "inside a message: " + parts[k],
            )


def test_message_class_of_two_tokens_is_the_earlier_row() raises:
    """Catches a search that answers with the later row: the optimizer's
    classification of a message holding a scan-binding token and a
    physical-plan token depends on it."""
    assert_equal(
        _name(message_class("PHYSICAL_PLAN_PURITY_UNCHECKABLE after SCAN_BINDING_EPOCH_MISMATCH")),
        String("SCAN_BINDING"),
    )


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
    assert_true(RefusalClass.PRODUCER_BUG != RefusalClass.SCAN_BINDING)
    assert_false(RefusalClass.PASS_REFUSAL != RefusalClass(0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
