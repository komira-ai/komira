"""numpy functions only the worker runtime's tests load."""

import numpy as np

KEEP = 30
KEPT = []
CALLS = [0]


def keep_then_drop(x: np.ndarray) -> np.ndarray:
    """Keeps a view of its input (the engine-to-worker slot it lives in) on
    each of its first KEEP calls, lets go of all of them on the next, and
    returns 2x."""
    CALLS[0] += 1
    if CALLS[0] <= KEEP:
        KEPT.append(x)
    else:
        KEPT.clear()
    return x * 2.0
