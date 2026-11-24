"""The errors the package raises on purpose (docs/design/python_package.md, decision 9).

Every one is a `KomiraError`, so `except komira.KomiraError` catches komira's
errors and nothing else. A wrong argument raises Python's own `TypeError` or
`ValueError` instead, before the library is called.
"""

from __future__ import annotations

from collections.abc import Mapping


class KomiraError(Exception):
    """An error from libkomira or from the package's own state.

    `status` is the status code of the C call that failed (a negative number,
    `-3` when the engine refused), or `None` when no call returned one: the
    library could not be loaded, or a call broke the two-call protocol.
    `str(error)` is the engine's message unchanged when the library gave one.

    `code` is the named code of the refusal (`SQL_SYNTAX_ERROR`,
    `LOWERING_WINDOW_UNSERVED`, ...) and `step` the step of the query that
    refused: one of "parse", "bind", "optimize", "lower" or "execute". Each is
    `None` when the library gave none: the refusal has none, the library is
    older than ABI 1.5, or no library call failed. `code` is never the empty
    string.
    """

    status: int | None
    code: str | None
    step: str | None

    def __init__(
        self, message: str, *, status: int | None = None, code: str | None = None, step: str | None = None
    ) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.step = step


class LibraryLoadError(KomiraError):
    """libkomira, or a library it needs, could not be loaded (the message names
    the file: a file missing from the package names the missing file); or a
    Mojo runtime of another build is already in the process; or its ABI major
    version is not the one this package was written for; or it lacks a
    function this package calls."""


class UnsupportedCpuError(LibraryLoadError):
    """The CPU lacks an instruction set extension libkomira was compiled to
    use, so the library is not opened: on Linux x86_64 a single library is
    built for x86-64-v3, and a directory of CPU-level variants needs at least
    the features of its lowest one. The message names the missing flags."""


class ParseError(KomiraError):
    """The SQL text is not valid SQL: the engine refused it at the parse step
    (`SQL_SYNTAX_ERROR`), or any refusal of that step that names no other
    code."""


class BindError(KomiraError):
    """A name in the statement or a registration does not resolve, or a
    registration or bind call failed: the engine refused at the bind step
    (`SQL_BIND_ERROR`, `BIND_*`), or any refusal of that step that names no
    other code."""


class UnsupportedOperation(KomiraError):
    """komira refused a construct by name: the message names it, says why, and
    gives a spelling that works if there is one."""


class CredentialsError(KomiraError):
    """libkomira refused a credential: the message is its named refusal,
    `CREDENTIALS_INVALID: <operation> ...`, which names the credential and the
    setting and never a value (docs/design/credentials_and_writes.md, decision
    11)."""


class StorageError(KomiraError):
    """Storage answered a read or a write with a failure: the object or region
    is not there, access is denied, the request was throttled, the transport
    failed, the object changed while it was read, or the answer was malformed."""


# The class of each named code the engine refuses with
# (docs/design/credentials_and_writes.md, section 11).
_CODE_CLASSES: dict[str, type[KomiraError]] = {
    **dict.fromkeys(["SQL_SYNTAX_ERROR"], ParseError),
    **dict.fromkeys(
        ["SQL_BIND_ERROR", "BIND_NAME_UNBOUND", "BIND_NOT_A_CATALOG", "BIND_SCOPE_NOT_A_TABLE", "BIND_VIEW_NOT_A_QUERY"],
        BindError,
    ),
    **dict.fromkeys(
        [
            "SQL_NOT_SUPPORTED",
            "STATEMENT_NOT_A_QUERY",
            "OPTIMIZE_UNRESOLVED_SCALAR",
            "LOWERING_SINK_UNSERVED",
            "LOWERING_JOIN_UNSERVED",
            "LOWERING_WINDOW_UNSERVED",
            "LOWERING_UDF_UNSERVED",
            "SQL_STATEMENT_UNSUPPORTED",
            "COPY_OPTION_UNSUPPORTED",
            "COPY_FORMAT_NOT_INFERRED",
            "STORAGE_URL_REFUSED",
            "STORAGE_RANGE_NOT_SUPPORTED",
            "STORAGE_WRITE_UNSUPPORTED",
            "PLAN_URL_QUERY_REFUSED",
        ],
        UnsupportedOperation,
    ),
    **dict.fromkeys(
        [
            "CREDENTIAL_UNBOUND",
            "CREDENTIAL_NAME_CONFLICT",
            "CREDENTIAL_KIND_MISMATCH",
            "CREDENTIALS_NOT_FOUND",
            "CREDENTIALS_INVALID",
        ],
        CredentialsError,
    ),
    **dict.fromkeys(
        [
            "STORAGE_REGION_UNKNOWN",
            "STORAGE_NOT_FOUND",
            "STORAGE_ACCESS_DENIED",
            "STORAGE_THROTTLED",
            "STORAGE_TRANSPORT",
            "STORAGE_MALFORMED",
            "STORAGE_OBJECT_CHANGED",
            "STORAGE_IO",
        ],
        StorageError,
    ),
}

# The class of a refusal that names no code, by the step that refused.
_STEP_CLASSES: Mapping[str, type[KomiraError]] = {"parse": ParseError, "bind": BindError}

# The status of an engine refusal (KOMIRA_ERR_ENGINE); the table applies to it
# alone.
_ENGINE_REFUSAL = -3


def error_class(
    status: int, code: str | None, step: str | None, default: type[KomiraError] = KomiraError
) -> type[KomiraError]:
    """The class of the error of a call that returned `status`, with the
    library's `code` and `step` (None for none). Only an engine refusal (-3)
    is classified: by its code when the table names it, else by its step
    (parse, bind), else `default`, the subclass the call's own refusals have.
    Any other status is a plain KomiraError."""
    if status != _ENGINE_REFUSAL:
        return KomiraError
    if code is not None and code in _CODE_CLASSES:
        return _CODE_CLASSES[code]
    if step is not None and step in _STEP_CLASSES:
        return _STEP_CLASSES[step]
    return default
