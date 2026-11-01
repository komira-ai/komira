# =============================================================================
# engine_runtime_build.mojo — THE ONE SPELLING OF "BUILD THE ENGINE'S RUNTIME"
# =============================================================================
#
# ⭐ WHY THIS MODULE EXISTS: **A SECOND SPELLING OF THIS CONSTRUCTION IS A
# SILENT COVERAGE HOLE, AND ONE ALREADY LANDED.**
#
# `EngineContext.__init__` builds its `PerCoreAsyncRuntime[NoopSink]` as
#
#     nw = engine_compute_lane_size(topology.num_workers())   # LANE 4 / LANE 5
#     self._runtime = build_engine_runtime(nw)                # IO-lane arm
#
# and BOTH steps are conditional on the engine's `EnginePlacement`:
# `engine_compute_lane_size` clamps `nw` to `len(engine_compute_cpus(placement))`
# whenever `placement.io_lane` or the NUMA
# restriction is on, and `build_engine_runtime` takes the DEFERRED-START arm
# (compute lane + a pinned IO lane) instead of the RAII single-lane ctor.
#
# ⛔ SO `PerCoreAsyncRuntime[NoopSink](num_workers=N, ...)` WRITTEN OUT BY HAND
# IS NOT THAT CONSTRUCTION. It is the flag-OFF arm, unconditionally — it can
# never grow an IO lane and it never applies either clamp. Measured on this
# tree 2026-09-03: the 30 engine-tier tests re-homed then
# spell it by hand, so under `placement.io_lane` (or NUMA-local) they
# now run on a runtime the engine would not have built. For the four
# `*_parallel_build_reachable` subjects — whose whole assertion is that a
# 4-worker build IS reachable — dropping the clamp means asserting reachability
# at a worker count the engine itself would have shortened.
#
# ⇒ These four functions live HERE, in the engine tier, so an engine-tier test
# and `EngineContext` call THE SAME function rather than agreeing by review.
# `komira_sdk_exec/engine_context.mojo` imports them back under its old private
# names; nothing about its behaviour changes.
#
# ⚠ THE BODIES BELOW ARE VERBATIM from `engine_context.mojo` (moved
# 2026-09-03) — only the four names lost their leading
# underscore, because a name a sibling package must import is not private.
# Their docstrings carry the measured rationale for each clamp; do not
# summarise them here, a second copy is how one of them goes stale.
#
# ⛔ THIS MODULE MAY NEVER IMPORT `komira_sdk*`. It is imported BY the SDK; an
# edge back would close a cycle and is what put these functions in the wrong
# package to begin with.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)

from komira_host.cpu_topology import engine_compute_cpus, engine_io_cpus
from komira_host.engine_placement import EnginePlacement
from .hardware_topology import HardwareTopology


# =============================================================================
# NoopSink factory for PerCoreAsyncRuntime[NoopSink] construction.
#
# Module-level (mirrors `session_context._noop_sink_factory`) because the
# PerCoreAsyncRuntime ctor takes a plain fn-ptr factory; a closure capturing
# `self` would not satisfy the substrate's worker-spawn contract.
# =============================================================================
def engine_noop_sink_factory() -> NoopSink:
    """NoopSink factory passed to `PerCoreAsyncRuntime[NoopSink]` ctor."""
    return NoopSink(_placeholder=UInt8(0))


# =============================================================================
# Part B (compute/IO hyperthread split) — runtime construction with
# the optional IO lane.
# =============================================================================
def engine_io_lane_size(placement: EnginePlacement = EnginePlacement()) -> Int:
    """The number of IO-lane workers the engine will attach: 0 unless
    `placement.io_lane` is on AND the host has sibling hyperthreads
    (`engine_io_cpus(placement)` non-empty). Returns 0 on the default path and on any
    non-SMT / HT-disabled / cpuset host — so the per-core log/tracer sizing
    below is `nw` (byte-for-byte the pre-Part-B value) whenever the IO lane is
    not actually created.

    This MUST agree with `build_engine_runtime`'s IO-lane decision so the
    per-core log ring + tracer slabs are sized to the FULL pthread count
    (compute + IO). An IO worker's global slab id is `nw + k`, and it binds
    that id into its per-core log TLS at thread start; if the log engine were
    sized only to `nw` rings a bare `log.*` on an IO worker would index out of
    bounds. Sizing to `nw + io_size` keeps every worker's ring in range.

    LANE 4: with the flag ON, `engine_io_cpus()` is the PLACED lane
    (`derive_io_placement`), not the raw sibling list — so on a no-HT host this
    can now be 1 (a DEDICATED stolen core, or a DRIVER_CORESIDENT thread) where
    it used to be 0. On the HT shape (this 14700K) the placement is the SIBLING
    arm and the value is identical to before.
    """
    if placement.io_lane:
        var n_io = len(engine_io_cpus(placement))
        if n_io > 0:
            return n_io
    return 0


def engine_compute_lane_size(
    nw: Int, placement: EnginePlacement = EnginePlacement()
) -> Int:
    """The number of COMPUTE pthreads to launch — `nw` clamped to the compute
    lane the placement policy actually derived.

    WHY THIS CLAMP EXISTS (the disagreement hole it closes). `nw` comes from
    `HardwareTopology.num_workers()`, but the pin site places compute worker `k`
    on `engine_compute_cpus()[k]`. LANE 4's `IO_PLACEMENT_DEDICATED` arm SHORTENS
    the compute lane by one (it hands the highest core to the IO lane), so
    without this clamp the pool would launch `nw` pthreads against `nw - 1`
    compute CPUs: worker `nw-1` would find a short lane list, run UNPINNED, and
    be free to land on the very core the IO lane was just given. Clamping here
    makes "pthread count == len(engine_compute_cpus())" true by construction.

    This is the same class of bug as the topology-resolution incident
    (two helpers disagreeing about the machine), so it is closed structurally
    rather than by convention.

    NO-OP ON EVERY PATH THAT EXISTS TODAY: with the IO-lane flag OFF the
    placement policy does not run and this returns `nw` unchanged. With the flag
    ON on an SMT host the SIBLING arm leaves the compute lane untouched, so it
    still returns `nw`. Only the no-HT DEDICATED arm shortens it.

    LANE 5 IS THE SECOND SHORTENER, and the hole it would otherwise
    open is larger than LANE 4's. `nw` here comes from
    `HardwareTopology.detect().num_workers()`, which on Linux is the HOST
    physical-core count — it knows nothing about NUMA. The NUMA restriction cuts
    `engine_compute_cpus()` to ONE socket's cores (44 -> 22 on the benchmark host), and
    every materialize dispatch sizes its fan-out from `engine_worker_count()`,
    which reads the restricted lane. Without this clamp the pool would spawn 44
    pthreads for a 22-shard fan-out: 22 workers permanently parked, and — worse
    — 22 threads whose confinement is real but whose existence the sizing side
    has already denied. Clamping here keeps
    "pthread count == len(engine_compute_cpus())" true by construction for BOTH
    lanes.
    """
    if not placement.io_lane and not placement.numa_local:
        return nw
    var n_compute = len(engine_compute_cpus(placement))
    if n_compute > 0 and n_compute < nw:
        return n_compute
    return nw


def build_engine_runtime(
    nw: Int,
    log_tls_key: UInt64 = UInt64(0),
    placement: EnginePlacement = EnginePlacement(),
) raises -> PerCoreAsyncRuntime[NoopSink]:
    """Build the engine's `PerCoreAsyncRuntime` with `nw` compute workers and,
    when `placement.io_lane` is on AND the host has sibling hyperthreads,
    a smaller IO lane pinned (under `placement.pin_workers`) to
    `engine_io_cpus(placement)`.

    DEFAULT PATH (flag OFF, the common case): builds EXACTLY the pre-Part-B
    runtime via the RAII ctor (`num_workers=nw` -> attach_workers + start).
    Byte-for-byte the single-lane shape; no IO lane, no extra pthreads.

    IO-LANE PATH (`placement.io_lane` + non-empty `engine_io_cpus(placement)`):
    uses the deferred-start mode so the IO lane can be attached BETWEEN
    attach_workers and start:
        attach_workers(nw)            # compute lane
        attach_io_workers(n_io)       # IO lane on the sibling HTs
        start()                       # launch both lanes' pthreads
    `n_io = len(engine_io_cpus())` (≤ nw; 8 P-core siblings on this 14700K).

    GRACEFUL DEGRADATION (the maintainer SMT-awareness refinement): on a non-SMT /
    HT-disabled / cpuset-restricted host `engine_io_cpus()` is EMPTY, so even
    with the flag ON `n_io == 0` and we fall through to the RAII (single-lane)
    ctor — identical to today's behavior, no IO lane created.
    """
    if placement.io_lane:
        var io_cpus = engine_io_cpus(placement)
        var n_io = len(io_cpus)
        if n_io > 0:
            # Deferred-start: attach compute, then IO lane, then start.
            var rt = PerCoreAsyncRuntime[NoopSink](
                placement=PLACEMENT_FIXED, log_tls_key=log_tls_key
            )
            rt.attach_workers(nw, engine_noop_sink_factory, BACKEND_MOCK)
            rt.attach_io_workers(n_io, engine_noop_sink_factory, BACKEND_MOCK)
            rt.start()
            return rt^
    # Default / non-SMT / flag-off path — the RAII single-lane ctor (unchanged).
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=nw,
        sink_factory=engine_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
        log_tls_key=log_tls_key,
    )


def build_engine_runtime_for_topology(
    topology: HardwareTopology,
    log_tls_key: UInt64 = UInt64(0),
    placement: EnginePlacement = EnginePlacement(),
) raises -> PerCoreAsyncRuntime[NoopSink]:
    """`topology` -> the runtime `EngineContext(topology)` would have built.

    ⭐ THE ENTRY POINT FOR AN ENGINE-TIER TEST, AND THE REASON IT IS A FUNCTION
    RATHER THAN A COMMENT SAYING "call these two in this order". It is the
    EXACT sequence `EngineContext.__init__` performs
    (`engine_context.mojo`'s two ctors, both arms) — the topology's worker
    count, the LANE 4 / LANE 5 clamp, then the IO-lane-aware build:

        nw = engine_compute_lane_size(topology.num_workers())
        return build_engine_runtime(nw)

    ⚠ IT DOES NOT REPRODUCE THE VALIDATION `EngineContext.__init__` performs
    FIRST — negative core counts and a zero-worker topology raise there, and a
    caller that wants those diagnostics must still go through `EngineContext`.
    This is the RUNTIME half only, which is all an engine-tier fixture needs.
    """
    return build_engine_runtime(
        engine_compute_lane_size(topology.num_workers(), placement),
        log_tls_key,
        placement,
    )

