"""User functions only the worker runtime's tests load: what a worker
process is (its pid, its parent), how it can fail (an abort mid-batch, a
call deaf to cancel), and two arguments read at their own offsets. Plain
functions; their type hints are their only declaration."""

import os
import time


def worker_pid(x: int) -> int:
    """The process serving the call."""
    return os.getpid()


def worker_ppid(x: int) -> int:
    """That process's parent: the zygote for a forked worker, the engine
    for one it started itself."""
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
    """Sleeps `seconds` without reading the cancel flag or the clock: a call
    only a kill ends early."""
    time.sleep(seconds)
    return seconds


def eight(a: int, b: int, c: int, d: int, e: int, f: int, g: int, h: int) -> int:
    """The most arguments a UDF takes here."""
    return a + b + c + d + e + f + g + h


def exit_3(x: int) -> int:
    """Ends the worker process with exit status 3."""
    os._exit(3)


def blas_threads(x: int) -> int:
    """OPENBLAS_NUM_THREADS as the worker sees it, 0 when unset."""
    return int(os.environ.get("OPENBLAS_NUM_THREADS", "0"))


def shares_memory(x: int) -> int:
    """How many shared regions (memfds named komira-udf-worker, counted by
    inode) the worker maps: 1, or 0 with no region. A forked worker
    has dropped the zygote's region at its own HELLO."""
    inodes = set()
    with open("/proc/self/maps") as f:
        for line in f:
            if "komira-udf-worker" in line:
                inodes.add(line.split()[4])
    return len(inodes)


def sleep_ms(ms: int) -> int:
    """Sleeps `ms` milliseconds."""
    time.sleep(ms / 1000)
    return ms


def slow_on_1(x: int) -> int:
    """Sleeps 2 s where its argument is 1, else returns at once: a batch
    whose deadline passes during row 1 only (tests/test_runtime_table.mojo,
    the deadline cases)."""
    if x == 1:
        time.sleep(2)
    return x


def uses_pyarrow(x: int) -> int:
    """1 when the worker imported pyarrow (its IPC codec), else 0."""
    import sys

    return 1 if "pyarrow" in sys.modules else 0
