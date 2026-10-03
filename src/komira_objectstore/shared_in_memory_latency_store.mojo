# =============================================================================
# komira_objectstore/shared_in_memory_latency_store.mojo
#   A LATENCY-INJECTING in-memory `ConditionalWriteStore` (test substrate).
# =============================================================================
#
# The WALL-CLOCK regression guard for the PARALLEL cold-read fan-out (index
# files MUST be read in parallel).
#
# WHY THIS EXISTS. An object-store op COUNT does NOT capture parallelism: N
# concurrent GETs are still N GET ops, so the in-memory op counters
# (`n_get` / `n_get_range`) are blind to whether the N GETs ran serially
# (`N × RTT` wall) or concurrently (`~1 × RTT` wall). The only way to PROVE the
# fan-out is concurrent is to inject a fixed per-GET round-trip latency and
# measure WALL-CLOCK: a serial loop costs `N × RTT`, a parallel fan-out costs
# `~1 × RTT`. This store does exactly that — it SLEEPS `rtt_seconds` on every
# `get` / `get_range` (the body-fetch verbs the cold path fans out), delegating
# every other verb (and the actual map storage + op counters) to an inner
# `SharedInMemoryConditionalStore`.
#
# `clone()` shares the inner Arc-backed map + carries the same `rtt_seconds`, so
# every handle a `parallelize` worker fans out to injects the same RTT — the
# concurrency overlap is what collapses `N × RTT` to `~1 × RTT`. The sleep
# (`usleep` — see `_sleep_rtt` for why NOT stdlib `time.sleep`) yields
# the calling thread, so K worker threads sleeping concurrently overlap their
# RTTs (the model of K in-flight object-store GETs).
#
# Encapsulation discipline:
#   * ZERO UnsafePointer in any public signature.
#   * ZERO wildcard origins / `unsafe_from_address`.
#   * Shared state behind the inner store's `ArcPointer` (it owns the map +
#     the spinlock); this wrapper holds only a POD `rtt_seconds` + the inner
#     store by value.
# =============================================================================

from std.ffi import external_call

from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


struct SharedInMemoryLatencyStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """A clone-shared in-memory `ConditionalWriteStore` that injects a fixed
    per-GET round-trip latency (`rtt_seconds`) on `get` / `get_range`.

    Delegates the map storage + op counters to an inner
    `SharedInMemoryConditionalStore` (Arc-shared across clones). Every body-fetch
    verb sleeps `rtt_seconds` BEFORE delegating, so a SERIAL N-GET loop costs
    `N × rtt_seconds` wall and a PARALLEL fan-out costs `~1 × rtt_seconds` wall.
    This is the wall-clock seam the cold-read fan-out regression guard measures.
    """

    var _inner: SharedInMemoryConditionalStore
    var _rtt_seconds: Float64

    def __init__(out self, rtt_seconds: Float64 = 0.0):
        self._inner = SharedInMemoryConditionalStore()
        self._rtt_seconds = rtt_seconds

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        rtt_seconds: Float64,
    ):
        self._inner = inner^
        self._rtt_seconds = rtt_seconds

    def clone(self) -> Self:
        """Share the inner Arc-backed map + carry the same per-GET RTT. This is
        what makes every `parallelize` worker's handle inject the same latency,
        so the concurrent overlap collapses `N × RTT` to `~1 × RTT`."""
        return Self(inner=self._inner.clone(), rtt_seconds=self._rtt_seconds)

    def with_rtt(self, rtt_seconds: Float64) -> Self:
        """A fresh handle over the SAME inner Arc-backed map but with a DIFFERENT
        per-GET RTT. Lets a test build the cold fixture with `rtt_seconds = 0`
        (fast setup), then drive the TIMED cold read with a large RTT over the
        same data — isolating the read's wall-clock from the fixture build."""
        return Self(inner=self._inner.clone(), rtt_seconds=rtt_seconds)

    @always_inline
    def inner_ref(ref self) -> ref [self._inner] SharedInMemoryConditionalStore:
        """Borrow the inner store (test inspection — op counts / direct reads)."""
        return self._inner

    @always_inline
    def _sleep_rtt(self):
        """Inject the fixed per-GET round-trip latency. The sleep yields the
        calling thread, so K worker threads sleeping concurrently OVERLAP their
        RTTs (the model of K in-flight object-store GETs).

        Uses `usleep` (microsecond, a DISTINCT symbol) rather than stdlib
        `time.sleep` -> `nanosleep`: an AOT binary that also links
        `komira_async` (whose reactor declares its OWN
        `external_call["nanosleep", ...]`) fails to legalize with "existing
        function with conflicting signature". Same fix as
        `cas_manifest._jittered_sleep_us` and `komira_log_index._sleep_us`.
        This store EXISTS to be measured against a fork-join pool, so linking it
        alongside the runtime is the normal case, not an exotic one — see
        `test_index_shard_slice1.test_s1b_parallel_cross_shard_wall_clock`.
        Microsecond resolution is far finer than the ~100 ms RTTs it models."""
        if self._rtt_seconds > 0.0:
            _ = external_call["usleep", Int32](
                UInt32(self._rtt_seconds * 1.0e6)
            )

    # ---- ObjectStore base surface (no latency — metadata, delegate) ----

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    # ---- ConditionalWriteStore surface ----

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        # LATENCY-INJECT: a ranged body fetch is a real object-store round-trip.
        self._sleep_rtt()
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        # LATENCY-INJECT: a whole-object body fetch is a real round-trip — this
        # is the verb the cold split GET + catalog chunk GET fan out.
        self._sleep_rtt()
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)
