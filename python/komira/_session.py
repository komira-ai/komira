"""`Session`: one engine context of libkomira and the tables registered on it,
and `Result`, the answer of one `Session.sql` call.

A session registers Parquet files, runs SQL over them (`komira_sql_stream`:
the library turns the text into a logical plan; this package builds no SQL)
and is closed. A `Result` holds the query's Arrow C stream, already handed to
pyarrow, and is read once, by `to_arrow`, `to_reader` or `__arrow_c_stream__`. The stream needs neither
the session nor its context, so a result still reads after its session is
closed or collected (docs/design/python_package.md, decision 3).
"""

from __future__ import annotations

import os
import weakref
from types import TracebackType
from typing import TYPE_CHECKING

from . import _arrow, _native
from ._credentials import _BuiltIn, _Credential
from ._errors import KomiraError, UnsupportedOperation

if TYPE_CHECKING:
    import pyarrow


class Session:
    """One engine context (`komira_ctx_new`) and its registered tables.

    `Session()` loads libkomira on first use and raises `LibraryLoadError`
    when it cannot. A session is a context manager: `with komira.Session() as
    s:` closes it on exit. `close()` frees the context and may be called again;
    any other call on a closed session raises `KomiraError`. A session that is
    never closed is freed when it is garbage collected.
    """

    def __init__(self) -> None:
        native = _native.load()
        ctx = native.ctx_new()
        self._native = native
        self._ctx: int | None = ctx
        self._free = weakref.finalize(self, native.ctx_free, ctx)
        # At interpreter exit the operating system reclaims the context with
        # the library, which is never unloaded; calling into it then is not
        # needed.
        self._free.atexit = False

    @property
    def closed(self) -> bool:
        """Whether `close()` was called."""
        return self._ctx is None

    def register_parquet(self, name: str, path: str | os.PathLike[str]) -> None:
        """Registers the local Parquet file at `path` as the table `name`.

        The file's footer is read now; a missing or unreadable file raises
        `KomiraError` with the engine's message. A relative `path` is resolved
        against the working directory and `~` is expanded. Registering a name
        again replaces it; a `Result` already returned keeps the answer it has.
        """
        if not isinstance(name, str):
            raise TypeError("name must be a str, not {}".format(type(name).__name__))
        if not name:
            raise ValueError("name is empty")
        if isinstance(path, os.PathLike):
            path = os.fspath(path)
        if not isinstance(path, str):
            raise TypeError("path must be a str or os.PathLike[str], not {}".format(type(path).__name__))
        ctx = self._live()
        self._native.register_parquet(ctx, name, os.path.abspath(os.path.expanduser(path)))

    def sql(self, query: str) -> Result:
        """Runs the one SQL statement `query` over the session's tables and
        returns its answer as a `Result`, unread.

        The statement is parsed, bound, optimized and lowered, and the
        answer's schema read, before this returns, so a syntax error, an
        unknown table or column, or a construct the engine refuses raises
        `KomiraError` here, with the engine's `<step>: <reason>` message and
        `status` -3 (a stream whose schema cannot be read raises it with no
        `status`). pyarrow is imported on the first call. A `query` that is not a
        `str` is a `TypeError`, and one holding a NUL byte or a lone surrogate
        a `ValueError`, both raised before the library is called.
        """
        if not isinstance(query, str):
            raise TypeError("query must be a str, not {}".format(type(query).__name__))
        ctx = self._live()
        stream = self._native.sql_stream(ctx, query)
        try:
            return Result(_arrow.import_stream(stream))
        except _arrow.stream_errors() as e:
            raise KomiraError(str(e)) from e

    def _seal_credential(self, credential: _Credential | _BuiltIn) -> None:
        """Makes `credential` the session's value of its name, replacing any
        earlier one (src/so/README.md, Credentials): `komira_credential_add`,
        then `komira_credential_set` for each of its fields in turn, then
        `komira_credential_seal` with the session scope. `AMBIENT` and
        `ANONYMOUS` need no definition, so nothing is called for them.

        This is the step `add_sql_binding` takes for each credential a source
        names, before it binds the source; it is private until that call
        lands. A credential the library refuses raises `CredentialsError` with
        the library's message, and the library discards the definition, so
        the session's value of the name is unchanged; any other failed call
        raises `KomiraError`. Anything other than a credential is a
        `TypeError`, raised before the library is called.
        """
        if isinstance(credential, _BuiltIn):
            self._live()
            return
        if not isinstance(credential, _Credential):
            raise TypeError("credential must be a komira credential, not {}".format(type(credential).__name__))
        ctx = self._live()
        kind, name, fields = credential._definition()
        cred_id = self._native.credential_add(ctx, kind, name)
        for field, value in fields:
            self._native.credential_set(ctx, cred_id, field, value.encode("utf-8"))
        self._native.credential_seal(ctx, cred_id)

    def close(self) -> None:
        """Frees the context. A second call does nothing."""
        self._ctx = None
        self._free()

    def __enter__(self) -> Session:
        self._live()
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        self.close()

    def _live(self) -> int:
        if self._ctx is None:
            raise KomiraError("the session is closed")
        return self._ctx



class Result:
    """The answer of one `Session.sql` call, read once.

    It holds the query's Arrow C stream inside a `pyarrow.RecordBatchReader`
    whose schema is already read. The first of `to_arrow()`, `to_reader()` and
    `__arrow_c_stream__()` takes the stream; any of them called again raises
    `KomiraError`, since keeping a copy would make a large answer's memory
    depend on which was called first. Run the query again to read it again. A
    result that is never read releases its stream when it is collected.
    Reading does not need the session: a result still reads after its session
    is closed.
    """

    def __init__(self, reader: pyarrow.RecordBatchReader) -> None:
        # None once a terminal took it.
        self._reader: pyarrow.RecordBatchReader | None = reader

    def __arrow_c_stream__(self, requested_schema: object | None = None) -> object:
        """The Arrow PyCapsule interface: a PyCapsule named
        "arrow_array_stream" that owns the stream, so that
        `pyarrow.RecordBatchReader.from_stream`, `pyarrow.table`, polars and
        DuckDB read it with no copy. The capsule is pyarrow's: it takes the
        stream whether or not it is consumed, and one never consumed releases
        it when collected.

        A `requested_schema` other than None raises `UnsupportedOperation`
        (a `KomiraError`; the class is not public yet) and leaves the result
        unread: komira does not cast an answer.
        """
        if requested_schema is not None:
            raise UnsupportedOperation(
                "komira does not cast a result to a requested schema: read it with requested_schema=None "
                "and cast the Arrow data"
            )
        return self._take().__arrow_c_stream__()

    def to_reader(self) -> pyarrow.RecordBatchReader:
        """The answer as a `pyarrow.RecordBatchReader`, which reads its
        batches as they are asked for. A failure while a batch is read raises
        pyarrow's error from the reader."""
        return self._take()

    def to_arrow(self) -> pyarrow.Table:
        """The whole answer as a `pyarrow.Table`. A failure while a batch is
        read raises `KomiraError` with the engine's message."""
        reader = self._take()
        try:
            return reader.read_all()
        except _arrow.stream_errors() as e:
            raise KomiraError(str(e)) from e
        finally:
            reader.close()

    def _take(self) -> pyarrow.RecordBatchReader:
        reader = self._reader
        if reader is None:
            raise KomiraError("the result was already read: run the query again to read it again")
        self._reader = None
        return reader
