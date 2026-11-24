"""`Session`: one engine context of libkomira and the tables registered on it,
and `Result`, the answer of one `Session.sql` call.

A session registers Parquet, CSV and newline-delimited JSON files as tables,
runs SQL over them (`komira_sql_stream`:
the library turns the text into a logical plan; this package builds no SQL)
and is closed. A `Result` holds the query's Arrow C stream, already handed to
pyarrow, and is read once, by `to_arrow`, `to_reader`, `to_pandas`,
`to_polars` or `__arrow_c_stream__`. The stream needs neither the session nor
its context, so a result still reads after its session is closed or collected
(docs/design/python_package.md, decision 3).

A session may be used from any thread. It holds a lock around each call into
the library, so its context never runs two calls at once (the C ABI's rule,
src/so/README.md): a call waits for the one running on the same session to
return. Reading a `Result` takes no lock, since its stream needs neither the
session nor its context.
"""

from __future__ import annotations

import contextlib
import importlib
import os
import threading
import weakref
from collections.abc import Iterator
from types import ModuleType, TracebackType
from typing import TYPE_CHECKING

from . import _arrow, _native
from ._credentials import _BuiltIn, _Credential
from ._errors import KomiraError, UnsupportedOperation

if TYPE_CHECKING:
    import pandas
    import polars
    import pyarrow


class Session:
    """One engine context (`komira_ctx_new`) and its registered tables.

    `Session()` loads libkomira on first use and raises `LibraryLoadError`
    when it cannot. A session is a context manager: `with komira.Session() as
    s:` closes it on exit. `close()` frees the context and may be called again;
    any other call on a closed session raises `KomiraError`. A session that is
    never closed is freed when it is garbage collected.

    A session may be used from several threads. Its calls run one at a time:
    a call made while another runs on the same session waits for that one to
    return, and `close()` waits too, so the context is never freed under a
    running call. Two sessions run their calls at once. A call made on the
    thread whose call is running, which only a signal handler or a finalizer
    can do, raises `KomiraError` instead of waiting for itself.
    """

    def __init__(self) -> None:
        native = _native.load()
        ctx = native.ctx_new()
        self._native = native
        self._ctx: int | None = ctx
        # Held around every call into the library; `_owner` is the thread
        # holding it, None when no thread does.
        self._lock = threading.Lock()
        self._owner: int | None = None
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
        _check_name(name)
        path = _local_path(path)
        with self._held():
            self._native.register_parquet(self._live(), name, path)

    def register_csv(
        self,
        name: str,
        path: str | os.PathLike[str],
        *,
        delimiter: str = ",",
        header: bool = True,
        all_varchar: bool = False,
    ) -> None:
        """Registers the local CSV file at `path` as the table `name`, the
        table SQL's `read_csv` makes of the same file with the same options.

        The engine infers the column names and types now, from the start of
        the file, and every later query reads the file with them. `delimiter`
        is the one ASCII character between fields; `header` says whether the
        first line holds the column names; `all_varchar=True` makes every
        column a string. A query on a table registered with `header=False`
        raises `KomiraError` naming `header=false`, as `read_csv(...,
        header=false)` does: the engine does not yet name the columns of a
        file without a header.

        A missing, empty or unreadable file, or a `name` the session already
        has a table under (of any kind, in any case), raises `KomiraError`
        with the engine's message, status -3, and registers nothing. A
        relative `path` is resolved against the working directory now and `~`
        is expanded. An argument of the wrong type is a `TypeError`, and an
        empty `name` or a `delimiter` that is not one ASCII character a
        `ValueError`, both raised before the library is called. Needs
        libkomira ABI 1.5.
        """
        _check_name(name)
        path = _local_path(path)
        with self._held():
            self._native.register_csv(
                self._live(), name, path, delimiter=delimiter, header=header, all_varchar=all_varchar
            )

    def register_json(self, name: str, path: str | os.PathLike[str]) -> None:
        """Registers the local newline-delimited JSON file at `path` (one
        object per line) as the table `name`, the table SQL's `read_json`
        makes of the same file.

        The engine infers the column names and types now, from the leading
        records, and every later query reads the file with them; a key a
        record lacks is NULL. Failures, paths and argument checks are those
        of `register_csv`. Needs libkomira ABI 1.5.
        """
        _check_name(name)
        path = _local_path(path)
        with self._held():
            self._native.register_json(self._live(), name, path)

    def sql(self, query: str) -> Result:
        """Runs the one SQL statement `query` over the session's tables and
        returns its answer as a `Result`, unread.

        The statement is parsed, bound, optimized and lowered, and the
        answer's schema read, before this returns, so a syntax error, an
        unknown table or column, or a construct the engine refuses raises
        `KomiraError` here, with the engine's `<step>: <reason>` message and
        `status` -3 (a stream whose schema cannot be read raises it with no
        `status`). pyarrow is imported the first time the engine accepts a
        query, when the answer's schema is read. A `query` that is not a
        `str` is a `TypeError`, and one holding a NUL byte or a lone surrogate
        a `ValueError`, both raised before the library is called.

        A query cannot be interrupted while it runs: the engine computes the
        answer before the call returns, and Python runs a signal's handler
        only once the call has returned. So Ctrl-C during `sql` raises
        `KeyboardInterrupt` then, the answer is released, and the session
        answers the next call.
        """
        if not isinstance(query, str):
            raise TypeError("query must be a str, not {}".format(type(query).__name__))
        with self._held():
            stream = self._native.sql_stream(self._live(), query)
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
        kind, name, fields = credential._definition()
        with self._held():
            ctx = self._live()
            cred_id = self._native.credential_add(ctx, kind, name)
            for field, value in fields:
                self._native.credential_set(ctx, cred_id, field, value.encode("utf-8"))
            self._native.credential_seal(ctx, cred_id)

    def close(self) -> None:
        """Frees the context, after the call running on another thread, if
        any, returns. A second call does nothing."""
        with self._held():
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

    @contextlib.contextmanager
    def _held(self) -> Iterator[None]:
        """Holds the session's lock for one call into the library, its last
        error read included, so that another thread's call cannot run on the
        context between a failed call and the read of its message.

        The thread already holding it is refused rather than left waiting for
        itself: a signal handler or a finalizer that runs inside a call and
        calls the session again gets a `KomiraError`. Another thread's
        `_owner` is never this thread's id, so only that thread is refused.
        A handler that runs in the few bytecodes between taking the lock and
        setting `_owner`, or between clearing it and letting go of the lock,
        is not seen and waits; Python code cannot close that window.
        """
        me = threading.get_ident()
        if self._owner == me:
            raise KomiraError(
                "a call on this session was made while another call on it is running on the same thread "
                "(from a signal handler or a finalizer): make it after that call returns"
            )
        with self._lock:
            try:
                self._owner = me
                yield
            finally:
                self._owner = None


def _check_name(name: object) -> None:
    """Refuses a table name that is not a non-empty `str`."""
    if not isinstance(name, str):
        raise TypeError("name must be a str, not {}".format(type(name).__name__))
    if not name:
        raise ValueError("name is empty")


def _local_path(path: object) -> str:
    """`path`, a `str` or `os.PathLike[str]`, with `~` expanded and made
    absolute against the working directory, so the engine, which reads the
    file again at each query, finds it after the working directory changes."""
    if isinstance(path, os.PathLike):
        path = os.fspath(path)
    if not isinstance(path, str):
        raise TypeError("path must be a str or os.PathLike[str], not {}".format(type(path).__name__))
    return os.path.abspath(os.path.expanduser(path))


class Result:
    """The answer of one `Session.sql` call, read once.

    It holds the query's Arrow C stream inside a `pyarrow.RecordBatchReader`
    whose schema is already read. The first of `to_arrow()`, `to_reader()`,
    `to_pandas()`, `to_polars()` and `__arrow_c_stream__()` takes the stream;
    any of them called again raises `KomiraError`, since keeping a copy would
    make a large answer's memory depend on which was called first. Run the
    query again to read it again. A result that is never read releases its
    stream when it is collected.
    Reading does not need the session: a result still reads after its session
    is closed, and while another call runs on it. Of two threads that read one
    result at once, one reads it and the other gets the `KomiraError`.
    """

    def __init__(self, reader: pyarrow.RecordBatchReader) -> None:
        # The reader, until a terminal takes it. `list.pop` takes it in one
        # step, so of two threads reading one result, one gets it and the
        # other the error.
        self._reader: list[pyarrow.RecordBatchReader] = [reader]

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
        return self._read_all()

    def to_pandas(self) -> pandas.DataFrame:
        """The whole answer as a `pandas.DataFrame`, converted from the Arrow
        table `to_arrow()` returns by pyarrow's `Table.to_pandas()` with its
        default dtype mapping; the table and the frame are both held while it
        converts. pandas is optional: when it cannot be imported this raises
        `ImportError` naming the distribution to install, and the result
        stays unread. A failure while a batch is read raises `KomiraError`
        with the engine's message; a failure of the conversion raises
        pyarrow's own error. Either way the result has been read."""
        # pyarrow's conversion imports pandas itself; importing it first is
        # what leaves the result unread when it is missing.
        _import_optional("pandas", "to_pandas")
        return self._read_all().to_pandas()

    def to_polars(self) -> polars.DataFrame:
        """The whole answer as a `polars.DataFrame`, converted from the Arrow
        table `to_arrow()` returns by `polars.from_arrow`. polars is optional:
        when it cannot be imported this raises `ImportError` naming the
        distribution to install, and the result stays unread. A failure while
        a batch is read raises `KomiraError` with the engine's message; a
        failure of the conversion raises polars' own error. Either way the
        result has been read."""
        polars = _import_optional("polars", "to_polars")
        return polars.from_arrow(self._read_all())

    def _read_all(self) -> pyarrow.Table:
        reader = self._take()
        try:
            return reader.read_all()
        except _arrow.stream_errors() as e:
            raise KomiraError(str(e)) from e
        finally:
            reader.close()

    def _take(self) -> pyarrow.RecordBatchReader:
        try:
            return self._reader.pop()
        except IndexError:
            raise KomiraError("the result was already read: run the query again to read it again") from None


def _import_optional(name: str, terminal: str) -> ModuleType:
    """The module `name`, imported for the terminal `terminal`. When it
    cannot be imported, an `ImportError` that says which distribution to
    install, chained to the import's own error."""
    try:
        return importlib.import_module(name)
    except ImportError as e:
        raise ImportError(
            "Result.{}() needs {}, which could not be imported: install it with `pip install {}`".format(
                terminal, name, name
            ),
            name=name,
        ) from e
