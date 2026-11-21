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
    """libkomira, or a library it needs, could not be loaded (the message names
    the file: a file missing from the package names the missing file); or a
    Mojo runtime of another build is already in the process; or, for the
    external flavour of the wheel, the Mojo runtime it loads from Modular's
    package is not installed or is another build (the message names the
    libraries and the `pip install` line that provides the right ones); or
    its ABI major version is not the one this package was written for; or it
    lacks a function this package calls."""


class UnsupportedCpuError(LibraryLoadError):
    """The CPU lacks an instruction set extension libkomira was compiled to
    use, so the library is not opened: on Linux x86_64 it is built for
    x86-64-v3. The message names the missing flags."""


class UnsupportedOperation(KomiraError):
    """komira refused a construct by name: the message names it, says why, and
    gives a spelling that works if there is one."""
