"""The state behind a context handle."""

from sql.sql_catalog import SqlCatalog

from .credentials import SessionCredentials


struct Session(Movable):
    """What `komira_ctx_new` creates: the text of the last error, the
    catalog of tables registered by name, and the credentials defined on it.

    The C surface owns a `Session` through an `OwnedPointer` and lends it to
    each call; it is destroyed by `komira_ctx_free`. A later change adds the
    engine's state here without changing the handle's type for the caller.
    """

    var _last_error: String
    var catalog: SqlCatalog
    """The tables registered on this session (`register_parquet`), looked up
    by name without regard to case."""
    var credentials: SessionCredentials
    """The credentials defined on this session (`komira_credential_add`,
    `_set`, `_seal`), by name; their values are wiped when the session is
    dropped."""

    def __init__(out self):
        """A session with no error, no table and no credential."""
        self._last_error = String()
        self.catalog = SqlCatalog()
        self.credentials = SessionCredentials()

    def set_error(mut self, var message: String):
        """Replace the last error with `message`."""
        self._last_error = message^

    def clear_error(mut self):
        """Forget the last error."""
        self._last_error = String()

    def has_error(self) -> Bool:
        """Whether an error text is held."""
        return self._last_error.byte_length() > 0

    def last_error(self) -> String:
        """A copy of the last error text; empty when there is none."""
        return self._last_error.copy()
