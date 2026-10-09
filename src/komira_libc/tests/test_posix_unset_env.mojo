# =============================================================================
# test_posix_unset_env.mojo — `_unset_env`, the one `unsetenv(3)` declaration
# =============================================================================
#
# `_unset_env(name)` removes `name` from this process's environment, so a
# reader that took a secret out of a variable can make sure a child spawned
# afterwards does not inherit it.
#
#   * removed means UNSET, not emptied: `_read_env_into` answers -1 after the
#     call (a `_unset_env` that did nothing, or that set the variable to ""
#     instead, fails here);
#   * only the named variable goes: a CONTROL variable set beside it keeps its
#     value;
#   * removing a variable that is not set succeeds (no refusal for the
#     common "already gone" case);
#   * a name libc refuses (empty, or holding `=`) raises naming the call,
#     rather than returning as if the variable were gone (a `_unset_env` that
#     dropped unsetenv's return code fails here).
#
# Variables are set with the standard library's `setenv`.
# =============================================================================

from std.os import setenv
from std.testing import assert_equal, assert_true

from komira_libc.posix import _read_env, _read_env_into, _unset_env


comptime _TARGET = "KOMIRA_TEST_POSIX_UNSET_TARGET"
comptime _CONTROL = "KOMIRA_TEST_POSIX_UNSET_CONTROL"


def _len_of(name: String) raises -> Int:
    """-1 when `name` is unset, else its value's length."""
    var buf = Array[UInt8, 64](fill=UInt8(0))
    return _read_env_into(name, buf)


def test_unset_removes_only_the_named_variable() raises:
    assert_true(setenv(String(_TARGET), String("secret-value")), "setenv target")
    assert_true(setenv(String(_CONTROL), String("stays")), "setenv control")
    assert_equal(_len_of(String(_TARGET)), 12, "precondition: the target is set")

    _unset_env(String(_TARGET))
    assert_equal(
        _len_of(String(_TARGET)), -1, "the variable is UNSET, not emptied"
    )
    assert_equal(
        _read_env(_CONTROL), String("stays"), "CONTROL: the other variable stays"
    )
    print("  test_unset_removes_only_the_named_variable: PASS")


def test_unsetting_an_unset_variable_succeeds() raises:
    _unset_env(String("KOMIRA_TEST_POSIX_UNSET_NEVER_SET"))
    assert_equal(_len_of(String("KOMIRA_TEST_POSIX_UNSET_NEVER_SET")), -1)
    print("  test_unsetting_an_unset_variable_succeeds: PASS")


def _refusal(name: String) -> String:
    try:
        _unset_env(name)
    except e:
        return String(e)
    return String("")


def test_a_name_libc_refuses_raises() raises:
    var r = _refusal(String(""))
    assert_true(r.find(String("cannot remove")) >= 0, "empty name: " + r)
    r = _refusal(String("A=B"))
    assert_true(r.find(String("cannot remove A=B")) >= 0, "a name with '=': " + r)
    print("  test_a_name_libc_refuses_raises: PASS")


def main() raises:
    test_unset_removes_only_the_named_variable()
    test_unsetting_an_unset_variable_succeeds()
    test_a_name_libc_refuses_raises()
    print("PASS test_posix_unset_env")
