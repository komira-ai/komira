"""`Session`: one engine context of libkomira and the tables registered on it,
and `Result`, the answer of one `Session.sql` call.

A session registers Parquet, CSV and newline-delimited JSON files as tables,
and the rows of a frame or of an object with the Arrow C stream interface
(`register`, which copies them into a table the library holds), runs SQL
over them (`komira_sql_stream`:
the library turns the text into a logical plan; this package builds no SQL)
and is closed. A `Result` holds the query's Arrow C stream, already handed to
pyarrow, and is read once, by `to_arrow`, `to_reader`, `to_pandas`,
`to_polars` or `__arrow_c_stream__`. The stream needs neither the session nor
its context, so a result still reads after its session is closed or collected
(docs/design/python_package.md, decision 3).

A session may be used from any thread. It holds a lock around each call into
the library, so its context never runs two calls at once (the C ABI's rule,
src/so/README.md): a call waits for the one running on the same session to
return. Reading a `Result` takes no lock of the session, since its stream
needs neither the session nor its context; a result has a lock of its own,
held while a notebook display reads its first rows, which a terminal that
finds the stream taken waits for.

On a library of ABI 1.6 or later, `sql` runs its statement under a run handle
(`_run.run_sql`): a Ctrl-C while it runs cancels the run, and a `progress`
callback is given the run's plan segments. On an older library it runs the
statement with `komira_sql_stream`, which cannot be interrupted.
"""

from __future__ import annotations

import contextlib
import importlib
import os
import threading
import weakref
from collections.abc import Callable, Iterator
from types import ModuleType, TracebackType
from typing import TYPE_CHECKING

from . import _arrow, _display, _native, _run
from ._credentials import _BuiltIn, _Credential
from ._errors import KomiraError, UnsupportedOperation
from ._sources import _FileSource

if TYPE_CHECKING:
    import pandas
    import polars
    import pyarrow


class Session:
    """One engine context (`komira_ctx_new`) and its registered tables.

    `Session()` loads libkomira on first use and raises `LibraryLoadError`
    when it cannot. `threads` is the engine's worker count and `memory_limit`
    the bytes the operators of one query may hold in total, each a positive
    `int` or `None` for the engine's own value. A query that needs more
    memory than `memory_limit` raises `MemoryLimitError` from `sql`, unless
    the engine can run it in less (a GROUP BY that spills). A `bool` or other
    non-`int` raises `TypeError`, and a value below 1 or above 2**63 - 1
    `ValueError`, before the library is called; naming either option needs
    libkomira ABI 1.4. The options are fixed for the life of the session.

    A session is a context manager: `with komira.Session() as
    s:` closes it on exit. `close()` frees the context and may be called again;
    any other call on a closed session raises `KomiraError`. A session that is
    never closed is freed when it is garbage collected.

    A session may be used from several threads. Its calls run one at a time:
    a call made while another runs on the same session waits for that one to
    return, and `close()` waits too, so the context is never freed under a
    running call. Two sessions run their calls at once. A call made on the
    thread whose call is running, which only a signal handler, a finalizer or
    a `progress` callback can do, raises `KomiraError` instead of waiting for
    itself.
    """

    def __init__(self, *, threads: int | None = None, memory_limit: int | None = None) -> None:
        workers = _option("threads", threads)
        budget = _option("memory_limit", memory_limit)
        native = _native.load()
        if workers == 0 and budget == 0:
            ctx = native.ctx_new()
        else:
            ctx = native.ctx_new_with_options(workers, budget)
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
        `BindError` (step "bind") with the engine's message. A relative `path` is resolved
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

    def register(self, name: str, obj: object) -> None:
        """Registers the rows of `obj`, a frame or Arrow data in memory, as
        the table `name`, as DuckDB's `register(view_name, python_object)`
        does: `sql` then reads `obj`'s rows under `name`.

        `obj` is a komira frame (`komira.DataFrame` or a `komira.pl.LazyFrame`,
        whose plan is run now, on the frame's own session), or any object with
        the Arrow PyCapsule stream interface (`__arrow_c_stream__`): a
        `pyarrow.Table`, `RecordBatch` or `RecordBatchReader`, a `Result`, and
        a pandas or polars DataFrame of a release that has the interface.

        The rows are copied into the session now and every later query reads
        the copy: a change made to `obj` afterwards is not seen (register it
        again to see it), and a query on the name never reads `obj` again. So
        a `pyarrow.RecordBatchReader` is read to its end here, once, and its
        table answers every query, where DuckDB scans a registered reader once,
        at the first query. A `pyarrow.RecordBatchReader` once given to
        `register`, whether or not that registration succeeded, raises
        `KomiraError` when it is given again, since it may have no rows left;
        another producer of a one-shot stream is not recognised. A `Result` is read by this
        call as by any of its terminals.

        Registering a name again replaces its table, of any kind (a file
        registered with `register_csv` too) and in any case, as DuckDB's
        `register` replaces a view of the name; a `Result` already returned
        keeps the answer it has. A refused registration leaves the table of
        the name as it was.

        The rows reach the engine through pyarrow (`_arrow.engine_reader`):
        a large or view string column registers as `string` and a large or
        view binary column as `binary`, with the same values, as DuckDB reads
        each family as one type; a sliced batch is copied whole. A column
        whose type the engine does not hold is refused by name and registers
        nothing: a list, struct or map column, or a union, is an
        `UnsupportedOperation` with the code `TABLE_TYPE_UNSUPPORTED` naming
        the column, and a type outside the engine's import (the null type,
        large and fixed-size lists, run-end encoding) a `BindError` naming the
        type's Arrow format, as is a stream that fails while it is read. A frame the engine refuses to run
        raises its error from this call. A `name` that is not a non-empty `str`,
        or that holds a NUL byte or a lone surrogate, and an `obj` with neither
        form, raise `TypeError` or `ValueError` before anything is read; an
        `__arrow_c_stream__` that returns no stream capsule raises `TypeError`
        once it has been called. Needs libkomira ABI 1.9; an older one raises
        `KomiraError` and reads nothing.

        The session's lock is held while the library reads the stream, so the
        producer's own code (a Python generator behind a reader, a pandas
        export) runs under it: another thread's call on the session waits for
        the read, and the producer calling this session raises `KomiraError`.
        """
        _check_name(name)
        _native._c_string("name", name)
        run = getattr(type(obj), "_komira_rows", None)
        if run is None and not hasattr(type(obj), "__arrow_c_stream__"):
            raise TypeError(
                "register takes a komira frame or an object with the Arrow PyCapsule stream interface "
                "(__arrow_c_stream__), such as a pyarrow.Table or RecordBatchReader, not {}".format(type(obj).__name__)
            )
        with self._held():
            self._live()
            # Refuse an older library before anything is read.
            self._native._fn("komira_register_arrow_stream")
        # The frame runs on its own session, which may be this one, so before
        # this session's lock is taken again.
        source = run(obj) if run is not None else obj
        _claim_stream(source)
        capsule = _arrow.engine_reader(source).__arrow_c_stream__()
        address = _arrow.stream_address(capsule)
        with self._held():
            # The library releases the stream on every path; the capsule then
            # finds it released and releases nothing.
            self._native.register_arrow_stream(self._live(), name, address)

    def sql(self, query: str, *, progress: Callable[[int, int], object] | None = None) -> Result:
        """Runs the one SQL statement `query` over the session's tables and
        returns its answer as a `Result`, unread.

        The statement is parsed, bound, optimized and lowered, and the
        answer's schema read, before this returns, so a syntax error, an
        unknown table or column, or a construct the engine refuses raises
        here, with the engine's `<step>: <reason>` message, `status` -3, and
        the refusal's `code` and `step`: a syntax error is a `ParseError`, a
        name that does not resolve a `BindError`, and a construct refused by
        name an `UnsupportedOperation`; a query that needs more memory than the
        session's `memory_limit` allows is a `MemoryLimitError` (step
        "execute"); another refusal is a `KomiraError` (a
        stream whose schema cannot be read raises one with no `status`). pyarrow is imported the first time the engine accepts a
        query, when the answer's schema is read. A `query` that is not a
        `str` is a `TypeError`, and one holding a NUL byte or a lone surrogate
        a `ValueError`, both raised before the library is called.

        Ctrl-C while the query runs cancels it: the engine stops at its next
        check (before each segment of the plan, and at each morsel boundary
        inside one), `sql` raises `KeyboardInterrupt`, nothing the query
        computed is kept, and the session answers the next call. A second
        Ctrl-C while the query stops is not raised; the first one is.

        `progress`, when given, is called on the thread that called `sql`, as
        `progress(done, total)`, with the plan segments the query finished
        and the segments its plan has, each time that reading changes while
        the query runs, and once more when it answered with done equal to
        total, if that reading was not yet given. Readings only grow. A plan
        is counted once it is checked, so a query refused before that, and a
        query whose plan has no segment, never calls it. An exception the
        callback raises cancels the query and is raised from `sql`. Calling
        the session from the callback raises `KomiraError`. A `progress` that
        is not callable is a `TypeError`, raised before the library is called.

        The query runs on a helper thread while the calling thread waits for
        it, so that Python can run a signal's handler on the calling thread.
        On a library older than ABI 1.6, which has no run handle, the query
        runs on the calling thread and cannot be interrupted: Ctrl-C raises
        `KeyboardInterrupt` once it returned, the answer is released, and a
        `progress` raises `KomiraError`.
        """
        if not isinstance(query, str):
            raise TypeError("query must be a str, not {}".format(type(query).__name__))
        if progress is not None and not callable(progress):
            raise TypeError("progress must be callable, not {}".format(type(progress).__name__))
        with self._held():
            ctx = self._live()
            if progress is not None or self._native.has("komira_sql_stream_run"):
                stream = _run.run_sql(self._native, ctx, query, progress)
            else:
                stream = self._native.sql_stream(ctx, query)
        try:
            return Result(_arrow.import_stream(stream))
        except _arrow.stream_errors() as e:
            raise KomiraError(str(e)) from e

    def _plan_stream(self, plan: bytes) -> Result:
        """Runs the serialized plan `plan` (`komira_plan_stream`: no SQL front
        end) and returns its answer as a `Result`, unread. This is the
        terminal of a DataFrame (komira/_frame.py); a refusal raises the
        engine's error, as `sql` does."""
        with self._held():
            stream = self._native.plan_stream(self._live(), plan)
        try:
            return Result(_arrow.import_stream(stream))
        except _arrow.stream_errors() as e:
            raise KomiraError(str(e)) from e

    def _plan_write(self, plan: bytes) -> int:
        """Runs the serialized plan `plan`, an envelope with a write target,
        through the plan door as `_plan_stream` does and returns the number of
        rows it wrote: the plan door answers one row, the column "Count". This
        is the terminal of a DataFrame write (komira/_write.py); a refusal
        raises the engine's error, as `sql` does."""
        table = self._plan_stream(plan).to_arrow()
        if table.schema.names != ["Count"] or table.num_rows != 1:
            raise KomiraError(
                "the plan door answered a write with {} rows of the columns ({}), not one row of Count".format(
                    table.num_rows, ", ".join(table.schema.names)
                )
            )
        return table.column(0)[0].as_py()

    def _plan_render(self, plan: bytes) -> str:
        """The engine's text of the serialized plan `plan` (`komira_plan_render`)."""
        with self._held():
            return self._native.plan_render(self._live(), plan)

    def _parquet_schema(self, path: str) -> bytes:
        """The `WireSchema` bytes of the local Parquet file at the absolute
        `path`, read from its footer now (`komira_parquet_schema`)."""
        with self._held():
            return self._native.parquet_schema(self._live(), path)

    def _parquet_source(self, path: str, hive_partitioning: int) -> bytes:
        """The `WireParquetSource` bytes of the local Parquet files the
        absolute `path` names (one file, a glob or a directory), resolved now
        (`komira_parquet_source`, ABI 1.11), with the Hive partition columns
        of the `KOMIRA_HIVE_*` mode `hive_partitioning`."""
        with self._held():
            return self._native.parquet_source(self._live(), path, hive_partitioning)

    def _csv_binding(self, path: str, *, delimiter: str, header: bool) -> bytes:
        """The `WireScanBinding` bytes of the local CSV file at the absolute
        `path` (`komira_csv_binding`), its columns inferred now."""
        with self._held():
            return self._native.csv_binding(
                self._live(), path, delimiter=delimiter, has_header=header, all_varchar=False
            )

    def _json_binding(self, path: str) -> bytes:
        """The `WireScanBinding` bytes of the local newline-delimited JSON
        file at the absolute `path` (`komira_json_binding`)."""
        with self._held():
            return self._native.json_binding(self._live(), path)

    def add_sql_binding(self, name: str, source: _FileSource) -> None:
        """Binds the SQL name `name` to `source`, a `komira.files` source, so
        that `sql` reads it as a table; binding a name again replaces its
        table, of any kind, as `register_parquet` does.

        The source's credential is sealed on the session first, as the
        session's value of its name: every table bound with that name reads
        with the latest value (docs/design/credentials_and_writes.md,
        decision 2). Then the source is bound through
        `komira_add_sql_binding`, which reads the footers now: a local file,
        or the objects of an `s3://` or Azure location (a glob is listed
        now), through the store with the sealed value. Queries read the
        objects through the same store. No secret is in what the library is
        given to bind, and the package writes none to a log or a message.

        Each refusal raises the library's named error, `status` -3 and step
        "bind", and binds nothing; the name keeps the table it had. A
        credential the library refuses is a `CredentialsError`, as is a
        remote source with `AMBIENT` (`CREDENTIALS_NOT_FOUND`: the library does
        not resolve the process's identity yet) or a credential of another
        store (`CREDENTIAL_KIND_MISMATCH`); a location no store of the library
        reads, `gs://` among them, is an `UnsupportedOperation`
        (`STORAGE_URL_REFUSED`); a store that refuses the read, a missing
        object or an S3 location with no `region` a `StorageError`; any other
        refusal (`BIND_SOURCE_UNSUPPORTED`, `BIND_SCOPE_NOT_A_TABLE`,
        `BIND_STORE_CONFLICT`, a missing local file) a `BindError`. A
        refused binding still leaves its credential sealed as the session's
        value of its name. A `name` that is not a non-empty `str`, or that
        holds a NUL byte or a lone surrogate, and a `source` that is not a
        `komira.files` source, raise `TypeError` or `ValueError` before the
        library is called. Needs libkomira ABI 1.10; an older one raises
        `KomiraError` and seals nothing.
        """
        _check_name(name)
        _native._c_string("name", name)
        if not isinstance(source, _FileSource):
            raise TypeError("source must be a komira.files source, not {}".format(type(source).__name__))
        wire = source._wire()
        with self._held():
            ctx = self._live()
            # Refuse an older library before anything is sealed.
            self._native._fn("komira_add_sql_binding")
            self._seal(ctx, source._credential)
            self._native.add_sql_binding(ctx, name, wire)

    def _seal_credential(self, credential: _Credential | _BuiltIn) -> None:
        """Makes `credential` the session's value of its name, replacing any
        earlier one (src/so/README.md, Credentials): `komira_credential_add`,
        then `komira_credential_set` for each of its fields in turn, then
        `komira_credential_seal` with the session scope. `AMBIENT` and
        `ANONYMOUS` need no definition, so nothing is called for them.

        `add_sql_binding` takes this step, under the same hold of the lock,
        for the credential of the source it binds. A credential the library
        refuses raises `CredentialsError` with the library's message, and
        the library discards the definition, so the session's value of the
        name is unchanged; any other failed call raises `KomiraError`.
        Anything other than a credential is a `TypeError`, raised before the
        library is called.
        """
        if not isinstance(credential, (_Credential, _BuiltIn)):
            raise TypeError("credential must be a komira credential, not {}".format(type(credential).__name__))
        with self._held():
            self._seal(self._live(), credential)

    def _seal(self, ctx: int, credential: _Credential | _BuiltIn) -> None:
        """`_seal_credential`'s calls, on the live context `ctx`, with the
        session's lock held by the caller."""
        if isinstance(credential, _BuiltIn):
            return
        kind, name, fields = credential._definition()
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
        itself: a signal handler, a finalizer or a `progress` callback that
        runs inside a call and calls the session again gets a `KomiraError`. Another thread's
        `_owner` is never this thread's id, so only that thread is refused.
        A handler that runs in the few bytecodes between taking the lock and
        setting `_owner`, or between clearing it and letting go of the lock,
        is not seen and waits; Python code cannot close that window.
        """
        me = threading.get_ident()
        if self._owner == me:
            raise KomiraError(
                "a call on this session was made while another call on it is running on the same thread "
                "(from a signal handler, a finalizer or a progress callback): make it after that call returns"
            )
        with self._lock:
            try:
                self._owner = me
                yield
            finally:
                self._owner = None


def _option(what: str, value: object) -> int:
    """An engine option argument: a positive `int` of at most 2**63 - 1, or
    None for the engine's own value, which the C call takes as 0."""
    if value is None:
        return 0
    if not isinstance(value, int) or isinstance(value, bool):
        raise TypeError("{} must be an int or None, not {}".format(what, type(value).__name__))
    if value < 1 or value > 2**63 - 1:
        raise ValueError("{} must be between 1 and 2**63 - 1, not {}".format(what, value))
    return value


# The process's default session: the one a reader called without `session=`
# uses, made by the first such call (docs/design/python_package.md, decision 5).
_default_lock = threading.Lock()
_default: Session | None = None


def default_session() -> Session:
    """The process's default session, made now when no call made it yet."""
    global _default
    with _default_lock:
        if _default is None:
            _default = Session()
        return _default


# The pyarrow.RecordBatchReader objects `Session.register` has been given, on
# any session: one of them exported again would be a stream of the batches
# left, none once it was read, so registering it again is refused instead of
# answering fewer rows.
_read_readers: weakref.WeakSet[object] = weakref.WeakSet()
_read_readers_lock = threading.Lock()


def _claim_stream(source: object) -> None:
    """Records `source` when it is a `pyarrow.RecordBatchReader`, and refuses
    one `Session.register` was given before, whether that registration was
    refused or not. Only pyarrow's reader is known to be read once; another
    producer of a one-shot stream is not recognised here."""
    import pyarrow

    if not isinstance(source, pyarrow.RecordBatchReader):
        return
    with _read_readers_lock:
        if source in _read_readers:
            raise KomiraError(
                "this pyarrow.RecordBatchReader was given to register before, which reads a reader once: query "
                "the name it was registered as, or register a pyarrow.Table (reader.read_all()) to register the "
                "same rows under more than one name"
            )
        _read_readers.add(source)


def _check_name(name: object) -> None:
    """Refuses a table name that is not a non-empty `str`."""
    if not isinstance(name, str):
        raise TypeError("name must be a str, not {}".format(type(name).__name__))
    if not name:
        raise ValueError("name is empty")


# The Hive partitioning modes `Session._parquet_source` takes (the
# KOMIRA_HIVE_* constants of komira_parquet_source).
_HIVE_AUTO = _native.KOMIRA_HIVE_AUTO
_HIVE_ON = _native.KOMIRA_HIVE_ON
_HIVE_OFF = _native.KOMIRA_HIVE_OFF

# The characters that make a path a glob for the engine (`has_glob`,
# src/fs/glob.mojo): `*`, `?`, `[` and `{`.
_GLOB_CHARACTERS = frozenset("*?[{")


def _names_many_files(path: str) -> bool:
    """Whether the absolute `path` is a glob or a directory, which the engine
    resolves into the files it names (`komira_parquet_source`), rather than
    one file. A file that exists takes the one-file route, as it did before
    `komira_parquet_source`, even when its name holds a glob character
    (`part[1].parquet`)."""
    if os.path.isfile(path):
        return False
    return not _GLOB_CHARACTERS.isdisjoint(path) or os.path.isdir(path)


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

    In a notebook, a result shows its first rows (`_repr_html_`) and stays
    unread: a terminal called after that still reads the whole answer.
    """

    def __init__(self, reader: pyarrow.RecordBatchReader) -> None:
        # The reader, until a terminal takes it. `list.pop` takes it in one
        # step, so of two threads reading one result, one gets it and the
        # other the error, and neither waits for the other. `_repr_html_`
        # takes it and puts back the reader that replays it while it holds
        # `_lock`; a terminal that finds no reader takes `_lock` before it
        # looks again, so a terminal called while a display reads waits for
        # the display and then reads. The lock is reentrant, so a signal
        # handler that reads the result during a display on its own thread
        # gets the error rather than waiting for itself.
        self._reader: list[pyarrow.RecordBatchReader] = [reader]
        self._lock = threading.RLock()

    def _repr_html_(self) -> str | None:
        """IPython's HTML display of the answer: its first rows, at most ten,
        under the column names and types, and a line with the row and column
        counts or saying there are more rows (komira/_display.py). The rows
        are read from the stream and kept, so the result stays unread and a
        terminal still reads all of it, once.

        Once the result has been read, this returns None, and IPython shows
        the plain `repr`. A failure while the rows are read raises
        `KomiraError` with the engine's message, and a terminal called after
        it raises the same failure. A Ctrl-C while they are read leaves the
        result read."""
        with self._lock:
            if not self._reader:
                return None
            reader = self._reader.pop()
            batches, more, error = _read_head(reader)
            self._reader.append(_replay(reader, batches, error))
        if error is not None:
            raise KomiraError(str(error)) from error
        return _display.result_html(reader.schema, batches, more)

    def __arrow_c_stream__(self, requested_schema: object | None = None) -> object:
        """The Arrow PyCapsule interface: a PyCapsule named
        "arrow_array_stream" that owns the stream, so that
        `pyarrow.RecordBatchReader.from_stream`, `pyarrow.table`, polars and
        DuckDB read it with no copy. The capsule is pyarrow's: it takes the
        stream whether or not it is consumed, and one never consumed releases
        it when collected.

        A `requested_schema` other than None raises `UnsupportedOperation`
        (a `KomiraError`) and leaves the result
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
            pass
        # No reader: the result was read, or a display holds the reader under
        # `_lock` and puts back the one that replays it before it lets go.
        with self._lock:
            try:
                return self._reader.pop()
            except IndexError:
                raise KomiraError("the result was already read: run the query again to read it again") from None


def _read_head(
    reader: pyarrow.RecordBatchReader,
) -> tuple[list[pyarrow.RecordBatch], bool, BaseException | None]:
    """Reads batches from `reader` until they hold more than
    `_display.MAX_ROWS` rows or the stream ends: the batches read, whether the
    stream had more than that many rows, and the error the stream raised (one
    of `_arrow.stream_errors()`), None when it raised none. Any other
    exception, a Ctrl-C's `KeyboardInterrupt` among them, propagates."""
    batches: list[pyarrow.RecordBatch] = []
    rows = 0
    try:
        while rows <= _display.MAX_ROWS:
            batch = reader.read_next_batch()
            batches.append(batch)
            rows += batch.num_rows
    except StopIteration:
        return batches, False, None
    except _arrow.stream_errors() as e:
        return batches, False, e
    return batches, True, None


def _replay(
    reader: pyarrow.RecordBatchReader, batches: list[pyarrow.RecordBatch], error: BaseException | None
) -> pyarrow.RecordBatchReader:
    """A reader of `reader`'s schema that yields `batches`, the batches
    `_read_head` read from it, and then raises `error` when it is not None,
    or else yields the rest of `reader`."""
    import pyarrow as pa

    def batches_then_rest() -> Iterator[pyarrow.RecordBatch]:
        yield from batches
        if error is not None:
            raise error
        yield from reader

    return pa.RecordBatchReader.from_batches(reader.schema, batches_then_rest())


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
