"""Imports pyarrow at the top: opening an instance of probe_pyarrow:probe imports it
in the context's interpreter, so the status tells whether pyarrow loads there."""

import pyarrow  # noqa: F401


def probe(x: int) -> int:
    return x
