# The one way to start the DuckDB arm: verify the file against the pin table,
# then start that file. Checking and starting are one call, so a binary that
# was not verified is not started by this path.

from .clock import BenchClock
from .pins import DEFAULT_DUCKDB_VERSION, check_duckdb_file
from .session import DuckDbSession
from .transport import ProcessTransport


def open_pinned(
    path: String,
    version: String = String(DEFAULT_DUCKDB_VERSION),
    max_silence_ms: Int = 0,
) raises -> DuckDbSession[ProcessTransport]:
    """Check the file at `path` against the pin for `version` and start it on
    the system clock. Raises, without starting anything, when the file cannot
    be read or is not the pinned binary (the message says which). The file is
    read once and then started by its path: replacing it between the two steps
    is not detected. `max_silence_ms` is the session's wait limit."""
    var check = check_duckdb_file(path, version)
    if not check.is_pinned():
        raise Error(check.describe())
    return DuckDbSession[ProcessTransport](
        ProcessTransport(path, List[String]()), BenchClock.system(), max_silence_ms
    )
