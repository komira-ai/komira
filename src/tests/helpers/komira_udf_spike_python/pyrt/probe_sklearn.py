"""Imports sklearn at the top: opening an instance of probe_sklearn:probe imports it
in the context's interpreter, so the status tells whether sklearn loads there."""

import sklearn  # noqa: F401


def probe(x: int) -> int:
    return x
