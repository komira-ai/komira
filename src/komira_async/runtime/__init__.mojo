# =============================================================================
# komira_async.runtime — PerCoreAsyncRuntime[S] + Worker[S]
# =============================================================================
# (PerCoreAsyncRuntime) + (Worker main
# loop) + (field set).
#
# thesis: N pinned per-core workers, each a complete async universe.
# No worker migration, no work-stealing, no AIMD K-control. Each worker
# owns its own reactor, task queue, timer wheel, connection set,
# cancellation tree. Cross-worker is rare, explicit, via SPSC channels.
#
# PARALLEL-FORK-JOIN: the shared fork-join layer over
# LocalDispatcher.run_with_state. Owns the State/Task/3-entry split + the
# destroy-recreate/gap7 safety contract ONCE so run_with_state consumers collapse to a
# single ChunkWork impl. See parallel_fork_join.mojo for the full contract.
# =============================================================================

from komira_async.runtime.chunk_work import ChunkWork
from komira_async.runtime.parallel_fork_join import (
    parallel_fork_join,
    parallel_fork_join_serial,
)
from komira_async.runtime.steal_work import StealWork
from komira_async.runtime.parallel_steal import (
    parallel_steal,
    parallel_steal_serial,
)
from komira_async.runtime.multiphase_work import MultiPhaseWork
from komira_async.runtime.parallel_multiphase import (
    parallel_multiphase,
    parallel_multiphase_serial,
)
