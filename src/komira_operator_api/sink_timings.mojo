# =============================================================================
# SinkPhaseTimings — per-phase atomic counters for the MorselSink lifecycle
# =============================================================================
#
# RFC Option C v2 §10 (an internal doc) requires per-phase timing
# on the flagship benchmark of every wave. Wave 1 gate (E-1 / E-2) calls for
# `consume_ns` / `combine_local_ns` / `combine_partition_ns` / `finalize_ns`
# to be sampled independently so that a 10% wall-clock ratio cannot mask a
# 20% phase-level regression offset by a phase-level speedup elsewhere.
#
# This harness is intentionally minimal:
#   * Four `Atomic[DType.uint64]` counters (one per phase).
#   * `record_*` methods `fetch_add` atomically — safe to call from any
#     worker thread during the dispatch.
#   * `dump()` prints the four counts to stdout; emission is guarded by
#     an `enabled` argument (default off) so production runs pay only the
#     four fetch_add ops (zero stdout noise).
#
# Gap6 safety (CRITICAL — read before refactor)
# --------------------------------------------
# `SinkPhaseTimings` holds inline `Atomic[DType.uint64]` fields and is
# therefore NON-MOVABLE (Mojo refuses to synthesize a move ctor for
# structs with inline Atomics — spike X1c Q6). This means the type MUST
# NEVER be placed inside `Slab[T]`, `List[T]`, or any byte-backed container
# that memcpy-moves elements. For multi-instance state use
# `OwnedPointer[SinkPhaseTimings]`.
#
# Thread-safety note
# ------------------
# The four Atomics use sequential-consistency (`Atomic.fetch_add` default).
# `dump()` does non-atomic `load`s — these are safe to call only after the
# dispatch has drained (per-wave gate is recorded post-finalize), which
# happens-after all workers have called `record_*`.
# =============================================================================

from komira_atomic_alias import AtomicU64
from std.memory import alloc, OwnedPointer, UnsafePointer


struct SinkPhaseTimings(Deinitable):
    """Atomic per-phase counters for a MorselSink dispatch.

    NOT Movable (inline Atomics). Declare this on the owning struct /
    function stack directly; never put it in a Slab / List / byte-backed
    container (gap6 hazard).

    Lifecycle
    ---------
    * Default `__init__` zeros all four counters.
    * `record_*(delta)` is called by workers (consume), by the driver
      (combine_local / finalize), or by `CombinePartitionSegment`
      (combine_partition) during the dispatch window.
    * `dump()` is called AFTER the dispatch drains. Non-atomic reads.

    Wave 3 Part 0 — keepalive shape (CRITICAL — read before refactor)
    -----------------------------------------------------------------
    Wave 2 Part D investigation
    (an internal doc) recommended
    declaring this struct `KeepAlive` to defeat ASAP-destruction
    when `&SinkPhaseTimings` is threaded into a downstream `Segment`
    (`execute_sink`'s combine path).

    EMPIRICAL FINDING (Wave 3 Part 0): widening the trait bound
    from `Deinitable` to `KeepAlive` BREAKS unrelated
    targets — `engine_unified_test_topn_sink` SIGSEGVs inside
    `execute_sink[TopNSink]`, even though `SinkPhaseTimings` is
    not yet referenced from `execute_sink`'s body. The likely
    mechanism is that `KeepAlive` extends
    `Deinitable`, but adopting it on a struct
    perturbs the trait-witness layout and Mojo codegen
    of `execute_sink`'s typed-Pointer trampoline.

    Mitigation: keep this struct `Deinitable` and
    apply the keepalive at every CALL SITE that threads
    `SinkPhaseTimings` into `execute_sink`. Two viable shapes:
      (a) Heap-stash via `OwnedPointer[SinkPhaseTimings]`. The
          `OwnedPointer` allocation has its own lifetime and is
          dropped at function exit; the stack-resident
          `OwnedPointer` is itself Movable + KeepAlive-compatible
          via its destructor running last.
      (b) Method-form keepalive: define `__keep_alive(mut self)`
          and call `_ = timings.load_consume()` (or
          `timings.__keep_alive()`) at the function tail to
          observe `self` after the prior block.

    The Wave 3 production wire-in below uses option (a) — it
    matches the doc comment recommendation
    ("For multi-instance state use `OwnedPointer[SinkPhaseTimings]`")
    and avoids the codegen perturbation observed with `KeepAlive`.
    """

    var _consume_ns: AtomicU64
    var _combine_local_ns: AtomicU64
    var _combine_partition_ns: AtomicU64
    var _finalize_ns: AtomicU64

    def __init__(out self):
        """Zero-initialized counters."""
        self._consume_ns = AtomicU64(UInt64(0))
        self._combine_local_ns = AtomicU64(UInt64(0))
        self._combine_partition_ns = AtomicU64(UInt64(0))
        self._finalize_ns = AtomicU64(UInt64(0))

    def __keep_alive(mut self):
        """Method-form keepalive for opt-in call-site protection.

        Call sites that thread `&SinkPhaseTimings` into a
        downstream `Segment` (e.g. via a `Pointer` field on a
        per-dispatch state struct) MUST invoke this method at the
        function tail to defeat ASAP-destruction. The compiler
        observes the method invocation as a "use" of `self`,
        holding the struct alive across the prior block.
        """
        pass

    def record_consume(mut self, delta: UInt64) -> None:
        """Add `delta` nanoseconds to the consume-phase accumulator."""
        _ = self._consume_ns.fetch_add(delta)

    def record_combine_local(mut self, delta: UInt64) -> None:
        """Add `delta` nanoseconds to the per-worker combine accumulator."""
        _ = self._combine_local_ns.fetch_add(delta)

    def record_combine_partition(mut self, delta: UInt64) -> None:
        """Add `delta` nanoseconds to the partition-combine accumulator."""
        _ = self._combine_partition_ns.fetch_add(delta)

    def record_finalize(mut self, delta: UInt64) -> None:
        """Add `delta` nanoseconds to the finalize-phase accumulator."""
        _ = self._finalize_ns.fetch_add(delta)

    def load_consume(self) -> UInt64:
        """Read the consume-phase counter. Call after the dispatch drains."""
        return self._consume_ns.load()

    def load_combine_local(self) -> UInt64:
        """Read the combine-local counter. Call after the dispatch drains."""
        return self._combine_local_ns.load()

    def load_combine_partition(self) -> UInt64:
        """Read the combine-partition counter. Call after the dispatch."""
        return self._combine_partition_ns.load()

    def load_finalize(self) -> UInt64:
        """Read the finalize counter. Call after the dispatch drains."""
        return self._finalize_ns.load()

    def dump(self, label: String, enabled: Bool = False) raises -> None:
        """Print the four counts if `enabled` (DEFAULT OFF).

        Production runs leave it off and pay only the four atomic loads.
        """
        if not enabled:
            return
        print(
            "[sink-timings ",
            label,
            "] consume_ns=",
            self.load_consume(),
            " combine_local_ns=",
            self.load_combine_local(),
            " combine_partition_ns=",
            self.load_combine_partition(),
            " finalize_ns=",
            self.load_finalize(),
            sep="",
        )


def new_timings_owned() -> OwnedPointer[SinkPhaseTimings]:
    """Heap-allocate a zero-initialized `SinkPhaseTimings`.

    Canonical factory for Wave 4 Step 3 production wire-in. Used by
    `execute_sink` and `execute_collect_morsel_sink` to avoid the
    stack-local keepalive hazard documented in
    `gotchas/sink_phase_timings_keepalive_rootcause.md`. The
    OwnedPointer's destructor runs at caller's function exit,
    defeating ASAP-destruction without trait-bound widening.

    Implementation: `SinkPhaseTimings` is non-Movable (inline Atomics),
    so the default `OwnedPointer[T](value=T)` ctor is illegal. We
    `alloc[SinkPhaseTimings](1)`, initialize each inner Atomic field's
    `.value` sub-slot via `init_pointee_move(UInt64(0))`, then adopt
    the raw pointer into the OwnedPointer. Matches the canonical
    non-Movable-Atomic pattern from `writer_parallel.mojo:227-230` and
    `partitioned_agg_steal_merge.mojo:194-197`.
    """
    # SAFETY: `SinkPhaseTimings` holds Atomics and cannot be moved, so it is
    # built in place: `raw` is a fresh allocation of one element, each of its
    # four fields is written exactly once below before anything reads it, and
    # the `OwnedPointer` returned adopts `raw` and frees it.
    var raw = alloc[SinkPhaseTimings](1)
    # Construct each inner Atomic in-place on the raw slot. Each
    # `Atomic[DType.uint64]` has a `.value: Scalar[DType.uint64]` field;
    # `init_pointee_move` on that sub-field zeroes the Atomic.
    UnsafePointer(to=raw[]._consume_ns).unsafe_bitcast[Scalar[DType.uint64]]().unsafe_write(
        Scalar[DType.uint64](0)
    )
    UnsafePointer(to=raw[]._combine_local_ns).unsafe_bitcast[Scalar[DType.uint64]]().unsafe_write(
        Scalar[DType.uint64](0)
    )
    UnsafePointer(to=raw[]._combine_partition_ns).unsafe_bitcast[Scalar[DType.uint64]]().unsafe_write(
        Scalar[DType.uint64](0)
    )
    UnsafePointer(to=raw[]._finalize_ns).unsafe_bitcast[Scalar[DType.uint64]]().unsafe_write(
        Scalar[DType.uint64](0)
    )
    return OwnedPointer[SinkPhaseTimings](unsafe_from_raw_pointer=raw)
