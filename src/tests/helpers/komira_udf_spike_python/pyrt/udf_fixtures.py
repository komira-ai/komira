"""User functions the tests and benches load through the komira-test/python
runtime: plain functions whose type hints are their only declaration.

The conformance cases of komira_udf_spike_abi name their fixtures by bare
name (`double`); the tests here load them as `udf_fixtures:<name>`. Each
fixture does what the case's echo fixture does, in Python.
"""

import time


# ---- the shared cases' fixtures ---------------------------------------------


def double(x: int | None) -> int | None:
    return None if x is None else 2 * x


def double_strict(x: int) -> int:
    if x is None:
        raise ValueError("double_strict got a null")
    return 2 * x


def add_strict(a: int, b: int) -> int:
    if a is None or b is None:
        raise ValueError("add_strict got a null")
    return a + b


def fahrenheit(c: list[float]) -> list[float]:
    return [None if v is None else v * 1.8 + 32.0 for v in c]


def identity(x: list[int]) -> list[int]:
    return x


def short_by_one(x: list[int]) -> list[int]:
    return x[:-1]


def long_by_one(x: list[int]) -> list[int]:
    return x + [0]


def null_out(x: int) -> int:
    return None


def raise_on_row_3(x: int) -> int:
    """Raises on row 3 of the batch it is called over, as echo's fixture
    does: a position, not a value (under PROPAGATE the batch is the
    compacted one). A per-row function is not told its row, so this one
    reads the adapter's row index from the calling frame (`_rows`'s `i`)."""
    import sys

    if sys._getframe(1).f_locals["i"] == 3:
        raise ValueError("raise_on_row_3: row 3")
    return x


def const7() -> int:
    return 7


def null_on_zero(x: int | None) -> int | None:
    return None if x is None or x == 0 else 2 * x


def add_mixed(a: int | None, b: int | None) -> int | None:
    """int64 + int32 in the corpus (`int` reads either width); also two int64
    columns at different offsets in this runtime's own tests."""
    return None if a is None or b is None else a + b


def narrow(x: list[int]) -> list[int]:
    """int64 in, the same values out as an int32 column."""
    return x


def raise_no_row(x: list[int]) -> list[int]:
    raise ValueError("raise_no_row: the whole batch")


def slow_loop(x: int) -> int:
    time.sleep(0.1)
    return x


# ---- this runtime's own cases ------------------------------------------------


def fahrenheit_rows(c: float) -> float:
    """The per-row benchmark function."""
    return c * 1.8 + 32.0


def no_hints(x):
    return x


def returns_float_hint(x: int) -> float:
    """Hinted float: a declared int64 result does not match."""
    return 1.0


def float_into_int(x: int) -> int:
    """Hinted int but returns a float: an unsafe cast the runtime refuses."""
    return 0.5


def unresolved_hint(x: int) -> "Optional[float]":  # noqa: F821
    """The source reads as an optional float, but this module never imports
    Optional: the hint does not resolve when the module is imported."""
    return 1.0


def raise_type_error(x: int) -> int:
    raise TypeError("raise_type_error: always")


COUNT = 0


def call_counter(x: int) -> int:
    """How many rows this module has seen in this interpreter: a module
    global, so each interpreter counts its own."""
    global COUNT
    COUNT += 1
    return COUNT


def reads_clock(x: list[int]) -> list[int]:
    """Calls the host clock its adapter was handed, from inside the batch
    function: the host of a cancel_during_call case sets the cancel flag
    there, so the flag goes up while a MAP_BATCHES_COLUMN function runs, as
    a host cancelling from another thread would."""
    import sys

    f = sys._getframe(1)
    while f is not None and "now" not in f.f_locals:
        f = f.f_back
    f.f_locals["now"]()
    return x


def spin(ms: int) -> int:
    """Spins on this thread's CPU for `ms` milliseconds of CPU time."""
    end = time.thread_time_ns() + ms * 1_000_000
    while time.thread_time_ns() < end:
        pass
    return ms
