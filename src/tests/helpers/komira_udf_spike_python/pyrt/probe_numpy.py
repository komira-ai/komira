"""Imports numpy at the top: opening an instance of probe_numpy:probe imports it
in the context's interpreter, so the status tells whether numpy loads there."""

import numpy  # noqa: F401


def probe(x: int) -> int:
    return x
