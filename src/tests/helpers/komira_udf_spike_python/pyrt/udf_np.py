"""The numpy batch functions of the tests and benches (a module of their own,
so that a function above that does not need numpy does not import it)."""

import numpy as np
import numpy.typing as npt


def fahrenheit_np(c: np.ndarray) -> np.ndarray:
    """The per-batch benchmark function."""
    return c * 1.8 + 32.0


def as_float(x: np.ndarray) -> np.ndarray:
    """int64 in, float64 out: a safe cast to a declared float64 result."""
    return x.astype(np.float64) / 2


KEPT = []


def keep_view(x: np.ndarray) -> np.ndarray:
    """Keeps its input, a view of the engine's buffer, past the call."""
    KEPT.append(x)
    return x * 2.0


def drop_views(x: np.ndarray) -> np.ndarray:
    """Lets go of every input keep_view kept."""
    KEPT.clear()
    return x * 1.0


def typed_np(x: npt.NDArray[np.float64]) -> npt.NDArray[np.float64]:
    """A subscripted numpy hint: its dtype is read from the source."""
    return x * 2.0


def np_raise(x: np.ndarray) -> np.ndarray:
    raise ValueError("np_raise: the whole batch")


def np_list(x: np.ndarray) -> np.ndarray:
    """Returns a Python list, which the adapter converts."""
    return [float(v) * 2.0 for v in x]


def np_2d(x: np.ndarray) -> np.ndarray:
    return x.reshape(-1, 1)


def np_int_out(x: np.ndarray) -> np.ndarray:
    """int64 in, int64 out: a safe cast to a declared float64 result."""
    return x * 2


def np_float_out(x: np.ndarray) -> np.ndarray:
    """float64 out for a declared int64 result: an unsafe cast."""
    return x * 0.5


def np_reversed(x: np.ndarray) -> np.ndarray:
    """A view with a negative stride: not contiguous."""
    return x[::-1]


def np_filled(x: np.ndarray) -> np.ndarray:
    """A masked input in, a plain array out: no row of the result is null."""
    return x.filled(0.0) + 1.0


def np_writes(x: np.ndarray) -> np.ndarray:
    """Writes into its argument, the engine's buffer: refused, read-only."""
    x[0] = 99.0
    return x


def buffer_type_refs(x: np.ndarray) -> np.ndarray:
    """The reference count of the runtime's buffer exporter type, found
    from the argument's base chain: each exporter holds one while it lives,
    so the count is the same on every call once each call's go."""
    import sys

    b = x
    for _ in range(8):
        if type(b).__name__ == "ArrowBuffer":
            return np.full(len(x), float(sys.getrefcount(type(b))))
        b = b.obj if isinstance(b, memoryview) else b.base
    raise RuntimeError("no ArrowBuffer under the argument")


def np_ragged(x: np.ndarray) -> np.ndarray:
    """A ragged list: no array numpy can make of it."""
    return [[1.0], [1.0, 2.0]]


class _BadArray:
    def __array__(self, dtype=None, copy=None):
        raise RuntimeError("_BadArray: no array")


def np_bad_array(x: np.ndarray) -> np.ndarray:
    """A result whose conversion to an array raises RuntimeError."""
    return _BadArray()
