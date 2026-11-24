"""The state behind a context handle."""

from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions

from .credentials import SessionCredentials


struct Session(Movable):
    """What `komira_ctx_new` (and `komira_ctx_new_with_options`) creates: the text of the last error, the
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

    def __init__(out self, options: EngineOptions = EngineOptions()) raises:
        """A session with no error, no table and no credential, over an engine
        started with `options` (by default the host profile's own worker
        count and memory budget, which is what `komira_ctx_new` uses).

        Raises:
            Error with the engine's message when the engine does not start:
            `options` is refused (`ENGINE_OPTIONS_INVALID`), or the host probe
            or the worker start fails.
        """
        self._last_error = String()
        self.engine = EngineContext(options)
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


def session_options(
    worker_count: Int64, memory_budget_bytes: Int64
) -> EngineOptions:
    """The engine options of `komira_ctx_new_with_options(worker_count,
    memory_budget_bytes)`.

    In the C call an option is a plain `int64_t`, so absence has a value: 0
    is absent, and the engine then uses the host profile's own worker count
    or memory budget (what `komira_ctx_new` uses). Any other value is passed
    on as given, so the engine refuses a negative one
    (`ENGINE_OPTIONS_INVALID`) and accepts any positive one: there is no
    upper bound.
    """
    var options = EngineOptions()
    if worker_count != 0:
        options.worker_count = Int(worker_count)
    if memory_budget_bytes != 0:
        options.memory_budget_bytes = Int(memory_budget_bytes)
    return options^


def try_new_session(
    options: EngineOptions = EngineOptions(),
) -> Optional[Session]:
    """A new `Session` over an engine started with `options`, or None when
    the engine does not start; nothing raises.

    This is what `komira_ctx_new` and `komira_ctx_new_with_options` do
    before they hand the session out: a None becomes the NULL handle. The engine's message is dropped, because
    there is no context to hold it.
    """
    try:
        return Session(options)
    except:
        return None
