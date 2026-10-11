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


def near(x: list[float]) -> list[float]:
    """Each value 5e-10 of itself away (0 stays exactly 0)."""
    return [None if v is None else v * (1.0 + 5e-10) for v in x]


def sum12(c0: int | None, c1: int | None, c2: int | None, c3: int | None, c4: int | None, c5: int | None, c6: int | None, c7: int | None, c8: int | None, c9: int | None, c10: int | None, c11: int | None) -> int | None:
    """The sum of 12 arguments; null if any is."""
    xs = (c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11)
    return None if None in xs else sum(xs)


def sum64(c0: int | None, c1: int | None, c2: int | None, c3: int | None, c4: int | None, c5: int | None, c6: int | None, c7: int | None, c8: int | None, c9: int | None, c10: int | None, c11: int | None, c12: int | None, c13: int | None, c14: int | None, c15: int | None, c16: int | None, c17: int | None, c18: int | None, c19: int | None, c20: int | None, c21: int | None, c22: int | None, c23: int | None, c24: int | None, c25: int | None, c26: int | None, c27: int | None, c28: int | None, c29: int | None, c30: int | None, c31: int | None, c32: int | None, c33: int | None, c34: int | None, c35: int | None, c36: int | None, c37: int | None, c38: int | None, c39: int | None, c40: int | None, c41: int | None, c42: int | None, c43: int | None, c44: int | None, c45: int | None, c46: int | None, c47: int | None, c48: int | None, c49: int | None, c50: int | None, c51: int | None, c52: int | None, c53: int | None, c54: int | None, c55: int | None, c56: int | None, c57: int | None, c58: int | None, c59: int | None, c60: int | None, c61: int | None, c62: int | None, c63: int | None) -> int | None:
    """The sum of 64 arguments; null if any is."""
    xs = (c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15, c16, c17, c18, c19, c20, c21, c22, c23, c24, c25, c26, c27, c28, c29, c30, c31, c32, c33, c34, c35, c36, c37, c38, c39, c40, c41, c42, c43, c44, c45, c46, c47, c48, c49, c50, c51, c52, c53, c54, c55, c56, c57, c58, c59, c60, c61, c62, c63)
    return None if None in xs else sum(xs)


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


def huge_float(x: float) -> float:
    """An int no float64 holds: refused as a value, not a runtime failure."""
    return 10**400


def not_a_list(x: list[int]) -> list[int]:
    return 7


def none_on_zero_list(x: list[int]) -> list[int]:
    return [None if v is None or v == 0 else v for v in x]


def nested_list(x: list[list[int]]) -> list[int]:
    """A column of lists: no Arrow type this runtime maps."""
    return x


def var_args(*x: int) -> int:
    return 0


def var_kwargs(**x: int) -> int:
    return 0


def keyword_only(x: int, *, y: int) -> int:
    return x


class _BadInt:
    """An int-like value whose conversion raises something other than the
    TypeError, ValueError or OverflowError the adapter maps to a bad value."""

    def __index__(self):
        raise RuntimeError("_BadInt: no int")


def bad_index(x: int) -> int:
    return _BadInt()


def allocated_blocks(x: int) -> int:
    """The interpreter's allocated memory blocks when this row runs: what
    the previous calls left behind shows here."""
    import sys

    return sys.getallocatedblocks()


def allocated_blocks_list(x: list[int]) -> list[int]:
    """The same for a column; the last row is null, so the result has a
    validity bitmap too."""
    import sys

    n = sys.getallocatedblocks()
    return [n] * (len(x) - 1) + [None]


def spin(ms: int) -> int:
    """Spins on this thread's CPU for `ms` milliseconds of CPU time."""
    end = time.thread_time_ns() + ms * 1_000_000
    while time.thread_time_ns() < end:
        pass
    return ms
