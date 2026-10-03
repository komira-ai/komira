# `Verdict` on its own: the worst kind wins and LEAK ranks above CANNOT_TELL,
# `merge` keeps every residue key and reason, the exit code is the kind, and
# `require_clean` raises with the whole verdict unless CLEAN.

from std.testing import assert_equal, assert_false, assert_true

from komira_test_verdict import (
    VERDICT_CANNOT_TELL,
    VERDICT_CLEAN,
    VERDICT_LEAK,
    Verdict,
    verdict_kind_name,
)


def test_verdict_merge_keeps_the_worst() raises:
    var a = Verdict()
    assert_equal(a.kind, VERDICT_CLEAN)
    var t = Verdict()
    t.add_cannot_tell("x")
    a.merge(t)
    assert_equal(a.kind, VERDICT_CANNOT_TELL)
    var l = Verdict()
    l.add_residue("k")
    a.merge(l)
    assert_equal(a.kind, VERDICT_LEAK)
    a.merge(t)
    assert_equal(a.kind, VERDICT_LEAK)
    assert_equal(len(a.reasons), 2)
    assert_equal(len(a.residue), 1)
    assert_equal(a.exit_code(), 6)


def test_leak_outranks_cannot_tell_in_either_order() raises:
    var a = Verdict()
    a.add_leak("delete failed: k")
    a.add_cannot_tell("list_keys: HTTP 503")
    assert_equal(a.kind, VERDICT_LEAK)
    var b = Verdict()
    b.add_cannot_tell("list_keys: HTTP 503")
    b.add_leak("delete failed: k")
    assert_equal(b.kind, VERDICT_LEAK)
    # Every reason is kept, whatever the final kind.
    assert_equal(len(a.reasons), 2)
    assert_equal(len(b.reasons), 2)


def test_exit_codes_and_names() raises:
    var c = Verdict()
    assert_true(c.is_clean())
    assert_equal(c.exit_code(), 0)
    assert_equal(String(c), "CLEAN")
    var t = Verdict()
    t.add_cannot_tell("why")
    assert_equal(t.exit_code(), 3)
    assert_equal(String(t), "CANNOT_TELL reasons=[why]")
    var l = Verdict()
    l.add_residue("a")
    l.add_residue("b")
    l.add_leak("r1")
    l.add_leak("r2")
    assert_equal(l.exit_code(), 6)
    assert_equal(String(l), "LEAK residue=[a, b] reasons=[r1; r2]")
    assert_equal(verdict_kind_name(9), "UNKNOWN(9)")


def test_require_clean() raises:
    Verdict().require_clean()
    var l = Verdict()
    l.add_residue("k")
    var raised = False
    try:
        l.require_clean()
    except e:
        raised = True
        assert_equal(String(e), "komira_test_verdict: teardown verdict LEAK residue=[k]")
    assert_true(raised, "require_clean passed a LEAK")
    var t = Verdict()
    t.add_cannot_tell("x")
    raised = False
    try:
        t.require_clean()
    except:
        raised = True
    assert_true(raised, "require_clean passed a CANNOT_TELL")
    assert_false(t.is_clean())


def main() raises:
    test_verdict_merge_keeps_the_worst()
    test_leak_outranks_cannot_tell_in_either_order()
    test_exit_codes_and_names()
    test_require_clean()
    print("test_verdict: OK")
