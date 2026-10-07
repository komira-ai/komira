# =============================================================================
# komira_async.runtime.spill_prefetch — IO-lane prefetch-offload.
# =============================================================================
# The compute/IO hyperthread split steers the
# BLOCKING spill-restore READS to a sibling-hyperthread IO worker so they run
# AHEAD of the compute thread's re-aggregation fold. This module is the
# PRODUCER side of that handoff:
#
#   * `SpillPrefetchWork` — the `ErasableWork` payload an IO worker runs. It
#     owns a COPY of the chunk file path (its own String buffer) + a byte
#     length, and its `run()` calls `prefetch_file_into_page_cache` (a leaf
#     page-cache prime). It touches ONLY the source file — NOT the agg `state`,
#     NOT a shared mutable buffer, NOT the fork-join barrier. This is what makes
#     the offload barrier-safe: the IO task is fire-and-forget
#     AHEAD of the consuming fold; the "handoff" to the compute thread is the
#     OS page cache.
#
#   * `SpillPrefetcher` — the POSTER handle. It holds CLONES of the IO-lane
#     senders ONLY (never the compute senders — the firewall: an IO worker is
#     never handed a compute shard). The spill driver constructs it from the
#     dispatcher's IO lane and threads it (as an `Optional`) into the spill
#     finalize so the merge loop can prefetch run i+1 while folding run i. With
#     no IO lane (placement off / non-SMT) the prefetcher is empty -> `is_active()`
#     False -> the producer no-ops.
#
# ── ENCAPSULATION ───────────────────────────────────────────────────────────
# Public API takes / returns `String`, `Int`, `Bool`, `SpillPrefetcher`,
# `SpillPrefetchWork`. ZERO `UnsafePointer` in any public signature. The IO
# senders are held as the encapsulated `Slab[OwnedPointer[MpscSender[...]]]`
# (the safe across destroy-recreate shape the dispatcher uses); the page-cache prime FFI is fully
# confined to `prefetch_file_into_page_cache` (komira_libc/posix_io.mojo).
#
# ── LIFECYCLE ─────────────────────────────────────────────────────────
# `SpillPrefetchWork` is a per-task heap-boxed payload (via `make_erased`), NOT
# a destroy-recreate pool field — so NOT the destroy-recreate shape. Its only heap field
# is a `String` (its OWNED path copy), freed by its `__del__` when the IO worker
# drops the handle after `run()`. `SpillPrefetcher` is a short-lived per-finalize
# value holding Arc-bumped sender clones; it drops at the end of finalize,
# releasing the clones (the runtime's canonical IO senders + the IO workers
# outlive it).
# =============================================================================

from std.memory import OwnedPointer

from komira_async.channel.mpsc import MpscSender, TRY_SEND_OK
from komira_async.runtime.wake_primitives import WorkerWakeHandle
from komira_async.runtime.shared_erasure import (
    ErasableWork,
    ErasedHandle,
    ErasedStepResult,
    STEP_DONE,
    make_erased,
)

from komira_collections.slab import Slab
from komira_libc.posix_io import prefetch_file_into_page_cache


# =============================================================================
# SpillPrefetchWork — the ErasableWork the IO worker runs.
# =============================================================================


struct SpillPrefetchWork(ErasableWork):
    """A fire-and-forget page-cache prefetch of one spill chunk file.

    The IO-lane worker drains this from its MPSC and runs `run()` BLIND, which
    primes the OS page cache for `_path` (up to `_max_bytes`) so the compute
    thread's subsequent `read_chunk` hits warm pages. Self-contained: owns a
    COPY of the path (NOT a borrow of any spill / agg state), references ONLY
    the source file. `step` is the no-op DONE arm (this payload uses only the
    void `run` arm — the offload is fire-and-forget, not a stepped
    handler).
    """

    var _path: String
    var _max_bytes: Int

    def __init__(out self, path: String, max_bytes: Int):
        """Construct from an OWNED copy of the chunk path + its byte length.

        `path` is copied into this payload (its own buffer) so the payload is
        self-contained across the channel crossing to the IO worker — it does
        NOT alias the producer's spill-state path. `max_bytes` bounds the warm
        to the chunk payload (<= 0 means warm to EOF)."""
        self._path = path
        self._max_bytes = max_bytes

    def run(mut self) raises -> None:
        """The void task/queue arm — prime the page cache for `_path`. NEVER
        raises outward in practice (`prefetch_file_into_page_cache` swallows a
        missing / unreadable file as benign — the compute thread's own read
        covers correctness). Runs on the IO-lane worker's sibling-HT pthread."""
        prefetch_file_into_page_cache(self._path, self._max_bytes)

    def step(mut self) raises -> Int:
        """No-op step arm — this payload uses only `run`. Returns STEP_DONE."""
        return STEP_DONE


# =============================================================================
# SpillPrefetcher — the producer-side poster (IO-lane senders ONLY).
# =============================================================================


struct SpillPrefetcher(Movable, Deinitable):
    """Posts `SpillPrefetchWork` to the IO lane (round-robin). Holds CLONES of
    the IO-lane senders ONLY — never the compute senders, so the firewall holds
    (an IO worker is never handed a compute shard).

    EMPTY when there is no IO lane (flag OFF / non-SMT) -> `is_active()` False
    -> the spill producer no-ops -> byte-identical to today. The spill driver
    builds one via `LocalDispatcher.make_spill_prefetcher()` and threads it
    into the spill finalize. Short-lived (one finalize); drops releasing the
    Arc-bumped clones.

    The post path is single-driver-threaded (the spill finalize runs on one
    driver thread), so the `_rr` round-robin cursor needs no atomic.
    """

    var _io_senders: Slab[OwnedPointer[MpscSender[ErasedHandle]]]
    # ★ THE DELIVERY HALF. Parallel to `_io_senders`: index k is IO
    # worker k's wake handle. WITHOUT THIS THE WHOLE LANE IS DEAD, and it WAS —
    # see `prefetch_chunk` for the full failure. `MpscSender.try_send*` does NOT
    # wake the consumer (verified: it is a pure Vyukov push, no eventfd write);
    # the wake is a SEPARATE producer-side call that the compute lane has always
    # made (`local_dispatcher` enqueue loop) and that the IO lane never did.
    var _io_wakes: Slab[WorkerWakeHandle]
    var _rr: Int
    # Diagnostic: number of prefetch posts ACCEPTED by an IO queue (a post that
    # was dropped because every queue was full is NOT counted). Lets the
    # integration tests prove the wired restore-loop call site actually reaches
    # the producer, and lets an EXPLAIN-style probe report IO-lane utilization.
    var _posts: Int
    # Diagnostic: number of times a post was followed by a REAL wake syscall
    # (elision missed, i.e. the IO worker was genuinely parked). A lane whose
    # posts are all elided is a lane whose worker is already awake and busy;
    # a lane whose posts all wake is an idle lane being fed. Both are healthy —
    # `posts > 0 and wakes == 0 and the worker never ran` is the dead-lane
    # signature this counter exists to make visible.
    var _wakes: Int

    def __init__(out self):
        """Construct an EMPTY prefetcher (no IO lane) — `is_active()` False."""
        self._io_senders = Slab[OwnedPointer[MpscSender[ErasedHandle]]]()
        self._io_wakes = Slab[WorkerWakeHandle]()
        self._rr = 0
        self._posts = 0
        self._wakes = 0

    def add_io_sender(
        mut self,
        var sender: MpscSender[ErasedHandle],
        var wake_handle: WorkerWakeHandle,
    ):
        """Append one IO-lane sender clone + its wake handle clone. Called by the
        dispatcher's `make_spill_prefetcher` once per IO worker.

        The two slabs MUST stay index-parallel — `prefetch_chunk` wakes
        `_io_wakes[idx]` for the `_io_senders[idx]` it just pushed to. Appending
        them together in one call is what keeps that true by construction."""
        var owned = OwnedPointer[MpscSender[ErasedHandle]](value=sender^)
        self._io_senders.append(owned^)
        self._io_wakes.append(wake_handle^)

    @always_inline
    def is_active(self) -> Bool:
        """True iff an IO lane is wired (>= 1 IO sender). False -> the spill
        producer runs the read inline (today's behavior)."""
        return self._io_senders.len() > 0

    def io_lane_count(self) -> Int:
        """Number of IO-lane senders this prefetcher can post to. Tests +
        round-robin spread."""
        return self._io_senders.len()

    def wake_handle_count(self) -> Int:
        """Number of WAKE handles held — MUST equal `io_lane_count()`.

        A sender without its wake handle is a post into a queue whose consumer
        parks indefinitely, i.e. a silently dead lane. The parity is asserted by
        `test_spill_prefetcher_carries_a_wake_handle_per_sender` so the drop
        cannot come back."""
        return self._io_wakes.len()

    @always_inline
    def posts(self) -> Int:
        """Number of prefetch posts ACCEPTED by an IO queue so far. Diagnostic:
        the integration test asserts the wired restore loop reached the producer
        (posts == n_runs); an EXPLAIN-style probe can report IO-lane usage. A
        post dropped on a full queue is not counted."""
        return self._posts

    @always_inline
    def wakes(self) -> Int:
        """Number of accepted posts that issued a REAL wake syscall (the elision
        missed, i.e. the target IO worker was genuinely parked).

        Diagnostic for the delivery half: `posts > 0` only proves the work
        reached a QUEUE. On a lane whose workers park indefinitely
        (`PARK_TIMEOUT_US = -1`), reaching the queue without a wake means the
        work is not observed until shutdown's final drain — i.e. never, for
        prefetch purposes. `wakes` is what proves the consumer was actually
        signalled. Elision (`wakes < posts`) is fine and expected once the IO
        worker is awake and looping."""
        return self._wakes

    def prefetch_chunk(mut self, path: String, max_bytes: Int) -> Bool:
        """POST a fire-and-forget `SpillPrefetchWork(path, max_bytes)` to the IO
        lane (round-robin). Returns True iff an IO worker accepted it; False iff
        there is no IO lane OR every IO queue was full (benign — the compute
        thread's own read covers correctness; only the overlap is lost).

        SAFETY / lifetime (why the offload is barrier-safe): the posted work owns a
        COPY of `path` and references ONLY the source file — not the spill /agg
        `state`, not a shared mutable buffer, not the fork-join barrier. The IO
        worker runs it BLIND and drops it; the producer never waits on it. So
        this post is OUTSIDE the barrier accounting and the `state`
        lifetime entirely. Single-driver-threaded -> `_rr` needs no
        atomic.

        ★ THE DELIVERY BUG THIS FIXES. `MpscSender.try_send_back` is a pure
        lock-free Vyukov
        push — it does NOT signal the consumer. The consumer's park is
        `poll_completions(PARK_TIMEOUT_US)` with `PARK_TIMEOUT_US = -1`, i.e.
        INDEFINITE. So without a wake: an IO worker has nothing to do at
        start(), spins out its window, parks forever, and every `prefetch_chunk`
        push sits in its MPSC until `shutdown()`'s final drain ran it at TEARDOWN.
        `posts` counts up and the lane looks wired; the prefetch never
        overlaps anything.

        The compute lane never had this bug because `LocalDispatcher`'s enqueue
        loop has always done `try_send_back` THEN
        `_worker_wake_handles[wid].wake_with_elision()`. This makes the IO lane
        symmetric with it, using that same handle API unchanged.

        ORDER IS LOAD-BEARING: send THEN wake. The reverse loses wakeups (the
        worker can observe an empty queue, set `_sleeping=1`, and park between
        our wake and our push). Drepper-safety for the send-then-wake order lives
        in the worker's own park bracket, which re-checks the queue AFTER setting
        `_sleeping=1` — unchanged by this commit."""
        var n_io = self._io_senders.len()
        if n_io == 0:
            return False
        # Heap-box the self-contained prefetch payload into an ErasedHandle (the
        # IO worker's MPSC element type). The handle OWNS the work (and thus the
        # path copy); its __del__ frees both when the IO worker drops it.
        var work = SpillPrefetchWork(path, max_bytes)
        var handle = make_erased[SpillPrefetchWork](work^)
        # Round-robin across IO workers; `try_send_back` hands the handle back on
        # a FULL/CLOSED queue (ErasedHandle is Movable-only, never dropped mid-
        # sweep) so we can retry the next worker.
        var start = self._rr % n_io
        var cur = handle^
        var i = 0
        while i < n_io:
            var idx = (start + i) % n_io
            var outcome = self._io_senders[idx][].try_send_back(cur^)
            if outcome.status == TRY_SEND_OK:
                self._rr = (idx + 1) % n_io
                self._posts += 1
                # SEND THEN WAKE (order load-bearing — see the docstring). The
                # elision skips the eventfd_write when the IO worker is already
                # awake; when it IS parked the real wake fires, which is the
                # whole point on a lane that is idle by design.
                if idx < self._io_wakes.len():
                    if self._io_wakes[idx].wake_with_elision():
                        self._wakes += 1
                return True
            cur = outcome.take_value()
            i += 1
        # Every IO queue full/closed — drop the prefetch (handle's __del__ frees
        # the path copy). Benign: correctness is on the inline read.
        _ = cur^
        return False
