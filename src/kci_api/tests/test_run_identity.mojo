# =============================================================================
# src/kci_contract/tests/test_run_identity.mojo
#   --run-id / --attempt / --context: each limit at its edge, each refusal by
#   its message.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from kci_contract import (
    ContextEntry,
    RunIdentity,
    parse_attempt,
    parse_context_arg,
    require_run_id,
)


def _run_id(s: String) -> String:
    try:
        require_run_id(s)
    except e:
        return String(e)
    return String("<ok>")


def _attempt(s: String) -> String:
    try:
        return String(parse_attempt(s))
    except e:
        return String(e)


def _ctx(s: String) -> String:
    try:
        var c = parse_context_arg(s)
        return c.key + String("|") + c.value
    except e:
        return String(e)


def _repeat(c: String, n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += c
    return s^


def test_run_id_grammar() raises:
    assert_equal(_run_id(String("gh-123_a")), String("<ok>"))
    assert_equal(_run_id(_repeat(String("a"), 63)), String("<ok>"))
    assert_equal(_run_id(_repeat(String("a"), 64)), String("--run-id is 64 bytes; at most 63"))
    assert_equal(_run_id(String("")), String("--run-id is EMPTY"))
    assert_true(_run_id(String("Gh-1")).find(String("outside [a-z0-9_-]")) >= 0)
    assert_true(_run_id(String("a.b")).find(String("outside [a-z0-9_-]")) >= 0)


def test_attempt_grammar() raises:
    assert_equal(_attempt(String("1")), String("1"))
    assert_equal(_attempt(String("12")), String("12"))
    assert_equal(_attempt(String("")), String("--attempt is EMPTY"))
    assert_equal(_attempt(String("0")), String("--attempt '0' is not a positive decimal integer"))
    assert_equal(_attempt(String("01")), String("--attempt '01' is not a positive decimal integer"))
    assert_equal(_attempt(String("-1")), String("--attempt '-1' is not a positive decimal integer"))
    assert_equal(_attempt(String("+1")), String("--attempt '+1' is not a positive decimal integer"))
    assert_equal(_attempt(String("1234567890")), String("--attempt '1234567890' is too large"))
    var refused = False
    try:
        _ = RunIdentity(String("r"), 0)
    except e:
        refused = String(e) == String("--attempt 0 is not positive")
    assert_true(refused)


def test_context_grammar() raises:
    assert_equal(_ctx(String("event=push")), String("event|push"))
    assert_equal(_ctx(String("ref=a=b")), String("ref|a=b"))
    assert_equal(_ctx(String("k=")), String("k|"))
    assert_equal(_ctx(String("noeq")), String("--context 'noeq' is not key=value"))
    assert_true(_ctx(String("=v")).find(String("is not 1 to 32 bytes")) >= 0)
    assert_true(_ctx(String("Key=v")).find(String("is not [a-z][a-z0-9_]*")) >= 0)
    assert_true(_ctx(String("1k=v")).find(String("is not [a-z][a-z0-9_]*")) >= 0)
    assert_equal(_ctx(_repeat(String("k"), 32) + String("=v")).find(String("|v")), 32)
    assert_true(_ctx(_repeat(String("k"), 33) + String("=v")).find(String("is not 1 to 32 bytes")) >= 0)
    assert_equal(_ctx(String("k=") + _repeat(String("v"), 256)).find(String("k|")), 0)
    assert_equal(_ctx(String("k=") + _repeat(String("v"), 257)), String("--context k: the value is 257 bytes; at most 256"))
    assert_true(_ctx(String("k=a\tb")).find(String("outside printable ASCII (byte 1)")) >= 0)
    assert_true(_ctx(String("k=a\nb")).find(String("outside printable ASCII")) >= 0)


def test_context_unique_and_bounded() raises:
    var r = RunIdentity(String("gh-1"), 2)
    r.add_context(ContextEntry(String("a"), String("1")))
    var refused = False
    try:
        r.add_context(ContextEntry(String("a"), String("2")))
    except e:
        refused = String(e) == String("--context a is given twice")
    assert_true(refused)
    for i in range(31):
        r.add_context(ContextEntry(String("k") + String(i), String("v")))
    assert_equal(len(r.context), 32)
    refused = False
    try:
        r.add_context(ContextEntry(String("z"), String("v")))
    except e:
        refused = String(e) == String("--context is given more than 32 times")
    assert_true(refused)
    # an entry built by hand is still checked
    refused = False
    try:
        var s = RunIdentity(String("gh-1"), 1)
        s.add_context(ContextEntry(String("Bad"), String("v")))
    except e:
        refused = True
    assert_true(refused)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
