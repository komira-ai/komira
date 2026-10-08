# =============================================================================
# test_gate.mojo -- the gate that holds a target to its known gaps.
# =============================================================================
#
# A report with one passing check ("p") and one failing ("f", error "boom:
# X"), gated five ways. Only "f listed with a fragment of its error" passes;
# an unlisted failure, a stale entry, an entry whose fragment the error lacks
# and an entry naming no check each fail the gate, naming the violation; a gap
# with an empty fragment (which every error contains) cannot be built.
# =============================================================================

from std.testing import assert_true

from komira_db_conformance import ConformanceReport, KnownGap


def _report() -> ConformanceReport:
    var r = ConformanceReport(String("fake-target"))
    r.ok(String("p"))
    r.fail(String("f"), String("boom: X"))
    return r^


def _gap(name: StaticString, frag: StaticString) raises -> KnownGap:
    return KnownGap(String(name), String(frag), String("test"))


def _gate_error(gaps: List[KnownGap]) raises -> String:
    """The gate's error text, or "" when it passes."""
    try:
        _report().gate(gaps)
    except e:
        return String(e)
    return String("")


def main() raises:
    var listed = List[KnownGap]()
    listed.append(_gap("f", "boom"))
    assert_true(_gate_error(listed) == String(""), "a failure listed with its fragment passes")

    var e1 = _gate_error(List[KnownGap]())
    assert_true(e1.find(String("FAILED f: boom: X")) >= 0, String("an unlisted failure fails: ") + e1)

    var stale = List[KnownGap]()
    stale.append(_gap("f", "boom"))
    stale.append(_gap("p", "anything"))
    var e2 = _gate_error(stale)
    assert_true(e2.find(String("STALE known gap (the check passes): p")) >= 0, String("a stale entry fails: ") + e2)

    var other = List[KnownGap]()
    other.append(_gap("f", "different"))
    var e3 = _gate_error(other)
    assert_true(e3.find(String("known gap f failed differently")) >= 0, String("a different failure fails: ") + e3)

    var typo = List[KnownGap]()
    typo.append(_gap("f", "boom"))
    typo.append(_gap("no_such_check", "x"))
    var e4 = _gate_error(typo)
    assert_true(e4.find(String("known gap names no check: no_such_check")) >= 0, String("a misspelt entry fails: ") + e4)
    var empty_refused = False
    try:
        _ = _gap("f", "")
    except e:
        empty_refused = String(e).find(String("empty must_contain")) >= 0
    assert_true(empty_refused, "a gap with an empty fragment is refused")
    print("PASS komira_db_conformance gate")
