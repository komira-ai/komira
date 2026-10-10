"""linger: the library of a test that leaves a child running (test 43)."""

from std.ffi import external_call


def one() -> Int:
    return 1


def fork_child_sleeping(seconds: UInt32) -> Int32:
    """Forks a child that sleeps `seconds` and then exits 0, outliving its
    parent, which does not wait for it. Returns the child's pid in the parent
    (-1 when fork fails); never returns in the child."""
    # SAFETY: fork, sleep and _exit are libc's; the child calls nothing
    # else, and _exit runs no handler of the parent's.
    var pid = external_call["fork", Int32]()
    if pid == 0:
        _ = external_call["sleep", UInt32](seconds)
        external_call["_exit", NoneType](Int32(0))
    return pid
