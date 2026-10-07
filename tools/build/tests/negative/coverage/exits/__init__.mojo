"""exits: the library of the tests of a coverage run's exit status (test 43)."""

from std.ffi import external_call


def one() -> Int:
    return 1


def fork_child_exiting(code: Int32, delay_us: UInt32) -> Int32:
    """Forks a child that sleeps `delay_us` and then exits with `code`,
    outliving its parent when the parent does not wait for it. Returns the
    child's pid in the parent (-1 when fork fails); never returns in the
    child."""
    # SAFETY: fork, usleep and _exit are libc's; the child calls nothing
    # else, and _exit runs no handler of the parent's.
    var pid = external_call["fork", Int32]()
    if pid == 0:
        _ = external_call["usleep", Int32](delay_us)
        external_call["_exit", NoneType](code)
    return pid
