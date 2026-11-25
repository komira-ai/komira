"""The state behind a context handle."""

from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import (
    STEP_BIND,
    STEP_EXECUTE,
    STEP_LOWER,
    STEP_OPTIMIZE,
    STEP_PARSE,
)

from .credentials import SessionCredentials
from .status import (
    KOMIRA_STEP_BIND,
    KOMIRA_STEP_EXECUTE,
    KOMIRA_STEP_LOWER,
    KOMIRA_STEP_NONE,
    KOMIRA_STEP_OPTIMIZE,
    KOMIRA_STEP_PARSE,
)


def step_number(name: String) -> Int32:
    """The `KOMIRA_STEP_*` number of the `sdk_exec` step `name` (`parse`,
    `bind`, `optimize`, `lower` or `execute`); `KOMIRA_STEP_NONE` for any
    other text."""
    if name == STEP_PARSE:
        return KOMIRA_STEP_PARSE
    if name == STEP_BIND:
        return KOMIRA_STEP_BIND
    if name == STEP_OPTIMIZE:
        return KOMIRA_STEP_OPTIMIZE
    if name == STEP_LOWER:
        return KOMIRA_STEP_LOWER
    if name == STEP_EXECUTE:
        return KOMIRA_STEP_EXECUTE
    return KOMIRA_STEP_NONE


def _is_upper(b: UInt8) -> Bool:
    return b >= 65 and b <= 90


def _is_upper_or_digit(b: UInt8) -> Bool:
    return _is_upper(b) or (b >= 48 and b <= 57)


def _upper_word_prefix(reason: String) -> String:
    """The leading token of `reason` that matches
    `[A-Z][A-Z0-9]*(_[A-Z0-9]+)+` and is followed by `: `; empty when the text
    does not start with one."""
    var bytes = reason.as_bytes()
    var n = len(bytes)
    if n == 0 or not _is_upper(bytes[0]):
        return String()
    var i = 1
    while i < n and _is_upper_or_digit(bytes[i]):
        i += 1
    var groups = 0
    while i + 1 < n and bytes[i] == 95 and _is_upper_or_digit(bytes[i + 1]):
        i += 2
        while i < n and _is_upper_or_digit(bytes[i]):
            i += 1
        groups += 1
    if groups == 0 or i + 1 >= n or bytes[i] != 58 or bytes[i + 1] != 32:
        return String()
    return String(reason[byte=0:i])


def error_code(reason: String) -> String:
    """The named code of an error whose reason is `reason`; empty when it has
    none.

    The three SQL front-end messages map to `SQL_SYNTAX_ERROR` (`SQL syntax
    error: `), `SQL_BIND_ERROR` (`SQL bind error: `) and `SQL_NOT_SUPPORTED`
    (`SQL not supported: `). Any other reason that starts with an upper-case
    word of two or more underscore-joined parts followed by `: `
    (`LOWERING_WINDOW_UNSERVED: ...`) has that word as its code. Anything else
    (`[Processor] ...`, `ERR: x`, a text with no prefix) has no code.
    """
    if reason.startswith("SQL syntax error: "):
        return String("SQL_SYNTAX_ERROR")
    if reason.startswith("SQL bind error: "):
        return String("SQL_BIND_ERROR")
    if reason.startswith("SQL not supported: "):
        return String("SQL_NOT_SUPPORTED")
    return _upper_word_prefix(reason)


struct Session(Movable):
    """What `komira_ctx_new` (and `komira_ctx_new_with_options`) creates: the last error (its text, step and
    code), the engine (`sdk_exec`'s `EngineContext`) the session's tables are registered
    on and its queries will run against, and the credentials defined on it.

    The C surface owns a `Session` through an `OwnedPointer` and lends it to
    each call; it is destroyed by `komira_ctx_free`, which stops the engine's
    workers.
    """

    var _last_error: String
    var _last_error_step: Int32
    var _last_error_code: String
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
        self._last_error_step = KOMIRA_STEP_NONE
        self._last_error_code = String()
        self.engine = EngineContext(options)
        self.credentials = SessionCredentials()

    def set_error(mut self, var message: String, step: Int32 = KOMIRA_STEP_NONE):
        """Replace the last error with `message`, at `step`; its code is
        `error_code(message)`."""
        self._last_error_code = error_code(message)
        self._last_error_step = step
        self._last_error = message^

    def set_refusal(mut self, step: String, var reason: String):
        """Replace the last error with an engine refusal: the text is
        `<step>: <reason>`, the step is `step_number(step)` and the code is
        `error_code(reason)`."""
        self._last_error_code = error_code(reason)
        self._last_error_step = step_number(step)
        self._last_error = step + ": " + reason

    def clear_error(mut self):
        """Forget the last error, its step and its code."""
        self._last_error = String()
        self._last_error_step = KOMIRA_STEP_NONE
        self._last_error_code = String()

    def has_error(self) -> Bool:
        """Whether an error text is held."""
        return self._last_error.byte_length() > 0

    def last_error(self) -> String:
        """A copy of the last error text; empty when there is none."""
        return self._last_error.copy()

    def last_error_step(self) -> Int32:
        """The `KOMIRA_STEP_*` of the last error; `KOMIRA_STEP_NONE` when
        there is none or it has no step."""
        return self._last_error_step

    def last_error_code(self) -> String:
        """A copy of the last error's code; empty when there is none or it
        has no code."""
        return self._last_error_code.copy()


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
