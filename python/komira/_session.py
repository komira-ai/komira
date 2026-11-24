"""`Session`: one engine context of libkomira and the tables registered on it.

Release 1 has no query call: a session registers Parquet files and is closed.
`Session.sql` arrives with the library's run call.
"""

from __future__ import annotations

import os
import weakref
from types import TracebackType

from . import _native
from ._credentials import _BuiltIn, _Credential
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
        """Registers the local Parquet file at `path` as the table `name`.

        The file's footer is read now; a missing or unreadable file raises
        `KomiraError` with the engine's message. A relative `path` is resolved
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
