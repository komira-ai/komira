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
    if x == 3:
        raise ValueError("raise_on_row_3: row 3")
    return x


def const7() -> int:
    return 7


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


def spin(ms: int) -> int:
    """Spins on this thread's CPU for `ms` milliseconds of CPU time."""
    end = time.thread_time_ns() + ms * 1_000_000
    while time.thread_time_ns() < end:
        pass
    return ms
