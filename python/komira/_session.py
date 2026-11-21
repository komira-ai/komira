"""`Session`: one engine context of libkomira and the tables registered on it.

Release 1 has no query call: a session registers Parquet files and is closed.
`Session.sql` arrives with the library's run call.
"""

from __future__ import annotations

import os
import weakref
from types import TracebackType

from . import _native
from ._errors import KomiraError


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
        """Registers the Parquet files at `path` as the table `name`.

        `path` is a file, a glob (`*`, `?`, `[...]`, `{a,b}`, one `**`) or a
        directory (every `.parquet` file under it). The files are listed once,
        at registration, and every footer is read now; Hive `key=value`
        directories become columns after the data columns. No match, differing
        schemas or an unreadable file raises `KomiraError` with the engine's
        message. A relative `path` is resolved
        against the working directory and `~` is expanded. Registering a name
        again replaces it. Nothing can query the table yet in this release.
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
