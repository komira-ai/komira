"""The state behind a context handle."""

from sdk_exec.engine_context import EngineContext

from .credentials import SessionCredentials


struct Session(Movable):
    """What `komira_ctx_new` creates: the text of the last error, the
    engine (`sdk_exec`'s `EngineContext`) the session's tables are registered
    on and its queries will run against, and the credentials defined on it.

    The C surface owns a `Session` through an `OwnedPointer` and lends it to
    each call; it is destroyed by `komira_ctx_free`, which stops the engine's
    workers.
    """

    var _last_error: String
    var engine: EngineContext
    """The session's engine: its catalog holds the tables registered on this
    session (`register_parquet`), looked up by name without regard to case,
    and its workers are started when the session is created."""
    var credentials: SessionCredentials
    """The credentials defined on this session (`komira_credential_add`,
    `_set`, `_seal`), by name; their values are wiped when the session is
    dropped."""

    def __init__(out self) raises:
        """A session with no error, no table and no credential, over an engine
        with the host profile's own worker count and memory budget.

        Raises:
            Error with the engine's message when the engine does not start
            (the host probe or the worker start fails).
        """
        self._last_error = String()
        self.engine = EngineContext()
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
