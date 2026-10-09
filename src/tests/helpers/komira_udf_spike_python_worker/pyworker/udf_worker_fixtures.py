"""User functions only the worker runtime's tests load: what a worker
process is (its pid, its parent), how it can fail (an abort mid-batch, a
call deaf to cancel), and two arguments read at their own offsets. Plain
functions; their type hints are their only declaration."""

import os
import signal
import time


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


def pair(x: int | None, y: int | None) -> int | None:
    """x * 1000 + y, or null when either is null."""
    if x is None or y is None:
        return None
    return x * 1000 + y


def sleep_deaf(seconds: int) -> int:
    """Sleeps `seconds` without reading the cancel flag or the clock, with
    SIGUSR1 (the pipe transport's cancel) blocked: a call only a kill ends
    early."""
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGUSR1})
    time.sleep(seconds)
    return seconds
