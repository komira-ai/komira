"""Imports cloudpickle at the top: opening an instance of probe_cloudpickle:probe imports it
in the context's interpreter, so the status tells whether cloudpickle loads there."""

import cloudpickle  # noqa: F401


def probe(x: int) -> int:
    return x
