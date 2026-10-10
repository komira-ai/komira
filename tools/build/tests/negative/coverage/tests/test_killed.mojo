# Killed by SIGKILL (test 43). Its coverage run must be red with the status
# a shell gives a process killed by signal 9, exit 137, as the release gate
# reports it (kcov v42 as released returns the signal number, 9).
from exits import one
from std.ffi import external_call
from std.testing import assert_equal


def main() raises:
    assert_equal(one(), 1, "the library value, read back")
    # SAFETY: raise is libc's; SIGKILL (9) ends the process here.
    _ = external_call["raise", Int32](Int32(9))
    raise Error("test_killed: still running after SIGKILL")
