"""The numpy batch functions of the tests and benches (a module of their own,
so that a function above that does not need numpy does not import it)."""

import numpy as np


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
