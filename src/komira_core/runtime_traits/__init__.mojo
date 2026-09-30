# =============================================================================
# komira_core.runtime_traits — pure runtime / dispatch interfaces
# =============================================================================
#
# These traits live below the engine so non-engine consumers (for example the
# Parquet reader and the SDK) can refer to them without depending on an engine
# package.
#
# Modules:
#   * worker_pool_traits — KeepAlive (state-level keepalive) + Segment
#                          (lightweight per-segment dispatch)
#   * parallel_dispatch  — ParallelDispatch (abstract fork-join dispatch
#                          surface) + NoDispatch (serial-fallback conformer).
#                          Lets core code (for example the Arrow IPC entries)
#                          dispatch without naming the concrete
#                          `LocalDispatcher`, which lives in komira_async.
#   * shared_chunk_work  — SharedChunkWork (per-chunk work unit for the
#                          shared-payload fork-join).
#   * fork_join_shared   — the dispatcher-generic shared-payload fork-join
#                          DRIVER (`fork_join_shared[..., D: ParallelDispatch]`),
#                          so core kernels such as
#                          `helpers/compiler_helpers.gather_batch` — stage 4 of
#                          every ORDER BY — dispatch onto the engine's own
#                          runtime instead of stdlib `parallelize[]`.
#
# `worker_pool_traits` / `parallel_dispatch` / `shared_chunk_work` are
# interfaces only. Concrete dispatchers (LocalDispatcher) live in their owning
# packages; `fork_join_shared` is the one generic driver they are substituted
# into.
# =============================================================================

from .worker_pool_traits import KeepAlive, Segment
from .parallel_dispatch import ParallelDispatch, NoDispatch
from .shared_chunk_work import SharedChunkWork
from .fork_join_shared import fork_join_shared, fork_join_pool_depth
