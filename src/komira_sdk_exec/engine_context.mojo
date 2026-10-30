# =============================================================================
# engine_context -- the state a query runs against
# =============================================================================
#
# A small state struct; what it can do lives in free functions in sibling
# modules (`engine_catalog`, `engine_lower`, `engine_execute`, `engine_sql`),
# so a feature that arrives later is a module and not another method here.
#
# The context owns:
#   * the SQL catalog and the names and paths registered into it;
#   * `footers`, the one footer reader the binder and lowering both read;
#   * the host profile (workers, memory budget) that lowering takes and the
#     driver's worker count comes from;
#   * the worker runtime the driver forks onto.
#
# THE FOOTER CACHE IS PINNED TO A QUERY. `komira_parquet_footers.FooterCache`
# keeps one footer per path for its life and has no cap, so a context that
# lived long would hold every file it ever touched. `begin_query` replaces it
# with an empty one; `run_sql` calls it first. Within one query the binder and
# lowering read one version of each file (the cache never re-reads a held
# footer); the next query reads each file it names again, so a file replaced
# between queries is read as the new file, or refused when its schema no longer
# matches the table registered for it. The cache therefore holds at most the
# files of one query. This pins the binder's and lowering's footers only: the
# scan reads the file's footer again through its own metadata cache
# (`engine_execute`), so the window between lowering and the scan stays open
# (komira#2024).
#
# The context holds no process-global state; two contexts share nothing.

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_engine_runtime.engine_runtime_build import build_engine_runtime
from komira_engine_runtime.host_detect import detect_host_profile
from komira_host_profile.host_profile import HostProfile
from komira_parquet_footers.parquet_footers import ParquetFooters
from komira_sql.sql_catalog import SqlCatalog

from .engine_options import EngineOptions

comptime ENGINE_BUILD = "komira-sdk-exec"
"""The engine build the context's host profile names."""

comptime ENGINE_OPTIONS_INVALID = "ENGINE_OPTIONS_INVALID"
"""Refusal: an option holds a value the engine cannot run with."""


struct RegisteredTable(Copyable, Movable):
    """A Parquet table registered on a context: its name and its file."""

    var name: String
    var path: String

    def __init__(out self, name: String, path: String):
        self.name = name
        self.path = path


struct EngineContext(Movable):
    """The catalog, footer reader, host profile and workers of one engine."""

    var catalog: SqlCatalog
    var tables: List[RegisteredTable]
    var footers: ParquetFooters
    var host_profile: HostProfile
    var runtime: PerCoreAsyncRuntime[NoopSink]

    def __init__(out self, options: EngineOptions = EngineOptions()) raises:
        """Probe the host once, apply `options` over it and start the workers.

        Raises:
            Error starting with `ENGINE_OPTIONS_INVALID` when `worker_count` or
            `memory_budget_bytes` is present and below 1. There is no upper
            bound. The options are read here only: they reach the host
            profile, and the profile is what the context keeps.
        """
        var threads = 0
        var budget = 0
        if options.worker_count:
            threads = options.worker_count.value()
            if threads < 1:
                raise Error(
                    String(ENGINE_OPTIONS_INVALID)
                    + ": worker_count must be at least 1, got "
                    + String(threads)
                )
        if options.memory_budget_bytes:
            budget = options.memory_budget_bytes.value()
            if budget < 1:
                raise Error(
                    String(ENGINE_OPTIONS_INVALID)
                    + ": memory_budget_bytes must be at least 1, got "
                    + String(budget)
                )
        var profile = detect_host_profile(String(ENGINE_BUILD), threads, budget)
        self.runtime = build_engine_runtime(profile.thread_count)
        self.host_profile = profile^
        self.catalog = SqlCatalog()
        self.tables = List[RegisteredTable]()
        self.footers = ParquetFooters()

    def begin_query(mut self):
        """Start a query: drop every footer the previous one cached."""
        self.footers = ParquetFooters()
