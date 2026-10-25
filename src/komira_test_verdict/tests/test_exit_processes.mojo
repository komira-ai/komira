# `exit_skip` and `exit_cannot_tell` end the process with 77 and 3, never 0. They cannot be
# called in the test's own process, so each is called in a forked child that is waited for:
# the parent reads the child's exit status. A function that returned instead of exiting would
# let the child fall through to the `_exit(0)` below, which is the one status a skip or a
# cannot-tell must never have.

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_true

from komira_test_verdict import (
    CANNOT_TELL_EXIT_CODE,
    SKIP_EXIT_CODE,
    exit_cannot_tell,
    exit_skip,
)


def _exit_status_of_child(skip: Bool) raises -> Int:
    """Forks; the child calls `exit_skip` (or `exit_cannot_tell`) and, if that returned, ends with 0.
    Returns the child's exit status, or -1 when it did not exit normally.

    SAFETY: fork and _exit are POSIX symbols; waitpid writes the status word through a pointer to a
    local Int32 that outlives the call."""
    var pid = external_call["fork", Int32]()
    if pid < Int32(0):
        raise Error("fork failed")
    if pid == Int32(0):
        if skip:
            exit_skip("no endpoint configured")
        else:
            exit_cannot_tell("half-configured")
        external_call["_exit", NoneType](Int32(0))
    var status = Int32(0)
    var rc = external_call["waitpid", Int32](pid, UnsafePointer(to=status), Int32(0))
    if rc < Int32(0):
        raise Error("waitpid failed")
    var s = Int(status)
    if (s & 0x7F) != 0:
        return -1
    return (s >> 8) & 0xFF


def test_exit_skip_ends_the_process_with_77() raises:
    var code = _exit_status_of_child(True)
    assert_equal(code, SKIP_EXIT_CODE)
    assert_true(code != 0, "a skip ended with exit 0")


def test_exit_cannot_tell_ends_the_process_with_3() raises:
    var code = _exit_status_of_child(False)
    assert_equal(code, CANNOT_TELL_EXIT_CODE)
    assert_true(code != 0, "a cannot-tell ended with exit 0")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
