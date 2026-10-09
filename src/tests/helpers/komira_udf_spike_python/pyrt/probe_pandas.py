"""Imports pandas at the top: opening an instance of probe_pandas:probe imports it
in the context's interpreter, so the status tells whether pandas loads there."""

import pandas  # noqa: F401


def probe(x: int) -> int:
    return x
