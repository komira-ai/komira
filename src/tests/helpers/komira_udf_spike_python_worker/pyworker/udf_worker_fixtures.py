"""User functions only the worker runtime's tests load: what a worker
process is (its pid, its parent) and how it can fail (an abort mid-batch).
Plain functions; their type hints are their only declaration."""

import os


def worker_pid(x: int) -> int:
    """The process serving the call."""
    return os.getpid()


def worker_ppid(x: int) -> int:
    """That process's parent: the engine for a spawned worker, the zygote
    for a forked one."""
    return os.getppid()


def abort_on_3(x: int) -> int:
    """Ends the worker process with SIGABRT on the row whose value is 3."""
    if x == 3:
        os.abort()
    return x
