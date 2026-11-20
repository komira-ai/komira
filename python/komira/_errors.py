"""The errors the package raises on purpose (docs/design/python_package.md, decision 9).

Every one is a `KomiraError`, so `except komira.KomiraError` catches komira's
errors and nothing else. A wrong argument raises Python's own `TypeError` or
`ValueError` instead, before the library is called.
"""

from __future__ import annotations


class KomiraError(Exception):
    """An error from libkomira or from the package's own state.

    `status` is the status code of the C call that failed (a negative number,
    `-3` when the engine refused), or `None` when no call returned one: the
    library could not be loaded, or a call broke the two-call protocol.
    `str(error)` is the engine's message unchanged when the library gave one.
    """

    status: int | None

    def __init__(self, message: str, *, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


class LibraryLoadError(KomiraError):
    """libkomira, or a library it needs, could not be loaded; or its ABI major
    version is not the one this package was written for; or it lacks a
    function this package calls."""
