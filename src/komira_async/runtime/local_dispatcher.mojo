# =============================================================================
# komira_async.runtime.local_dispatcher — LocalDispatcher[S]
# =============================================================================
# The fork-join dispatcher behind PerCoreAsyncRuntime's `dispatcher()`
# accessor.
#
# It fork-joins through the per-worker MPSC enqueue + worker_main
# drain shape (rather than a stdlib `parallelize`). The dispatcher
# publishes one
# `_TaskEntry` per worker shard onto each worker's MPSC queue; the
# worker's `Worker.run_one_iteration` drain step reconstructs the
# per-shard descriptor via the entry's `task_raw` byte pointer and
# dispatches `seg.execute` per-tid; on shard completion the trampoline
# fetch_subs `_in_flight` and (on last) bumps the wake-word + futex
# wakes the driver. Driver waits on the wake-word until `_in_flight ==
# 0`. CAS / dual-keepalive / first-error-wins / wrapper-destructure
# discipline preserved.
#
# Why MPSC (vs the spec's nominal SPSC):
#   The same per-worker queue is shared between the LocalDispatcher and
#   the LocalSpawner producers; SPSC would corrupt the queue under
#   concurrent producer access. MPSC's Vyukov ring offers comparable
#   lock-free throughput on the hot path. See
#   `komira_async/runtime/worker.mojo` header for the full rationale.
#
# Why STORED FIELDS (sender list + per-call descriptor slab):
#   * `_worker_senders` mirrors PerCoreAsyncRuntime's worker count via
#     `_register_worker_handle` (called from `attach_worker[s]`). The
#     dispatcher holds ONE clone per worker; each clone is independent
#     producer state for the dispatcher's enqueue path.
#   * `_in_flight`, `_wake_word`, `_in_dispatch` stay heap-stable via
#     OwnedPointer[Atomic[..]] — the canonical heap-stable
#     atomic shape.
#   * Per-call shard descriptors (`_DispatchShard[State, T]`) are
#     allocated freshly inside `run_with_state` (one alloc[] per shard)
#     and freed after the barrier.
#
# Pointer discipline:
#   - ZERO `UnsafePointer` in any public method signature.
#   - ZERO new `unsafe_from_address=Int(...)` sites.
#
# The per-dispatch shard descriptor
# `_DispatchShard` formerly carried SIX `UnsafePointer[_, MutExternalOrigin]`
# wildcard FIELDS (state_ptr, seg_ptr, in_flight_ptr, wake_word_ptr,
# error_slot_ptr, cancel_token_ptr). Those are now RETIRED onto the
# `StateBoundWork` concrete-origin pattern (shared_erasure.mojo,
# validated by tests/test_shared_erasure_real_shapes.mojo
# against THESE exact shapes): the six borrows bundle into ONE caller-owned
# `_DispatchCtx[State, T]` frame, and each shard holds ONE
# `Pointer[_DispatchCtx, origin]` concrete-origin field + lo/hi/wid. The
# concrete `origin` makes the fork-join barrier lifetime COMPILER-ENFORCED:
# every shard's borrow is tied to the SAME `ctx` origin, so the wake-word
# barrier must complete (and `ctx` cannot drop) before the borrow ends. This
# is STRICTLY safer than the six wildcard fields (which erased every origin to
# the same widened `MutExternalOrigin`, defeating ASAP-destruction tracking).
#
# The ONLY remaining wildcard origin on this path is `_TaskEntry.task_raw`
# (the unavoidable byte-ptr type-erasure handle crossing the per-worker MPSC
# channel — the blessed FFI carve-out, NOT a `_DispatchShard` field). The
# per-(State, T, origin) trampoline reinterprets that byte ptr back to the
# concrete `_DispatchShard[State, T, origin]`; `origin` is part of the
# monomorphized trampoline type, so the borrow's origin survives the channel
# crossing (identical to how `ErasedHandle` recovers `StateBoundWork`'s origin).
# =============================================================================

from std.memory import OwnedPointer, UnsafePointer, alloc
from komira_atomic_alias import AtomicI32, AtomicI64, AtomicU8
from std.sys import num_physical_cores, size_of
from std.ffi import external_call
from std.io import FileDescriptor
from std.time import perf_counter_ns

from komira_async.cancellation.token import CancellationToken
from komira_async.channel.mpsc import (
    MpscSender,
    TRY_SEND_OK,
    TRY_SEND_FULL,
    TRY_SEND_CLOSED,
)
from komira_async.runtime.shared_erasure import (
    ErasableWork,
    ErasedHandle,
    STEP_DONE,
    make_erased,
)
from komira_async.runtime.spill_prefetch import SpillPrefetcher
from komira_async.runtime.sched_trace import (
    sched_trace_enabled,
    sched_trace_add_segment,
    sched_trace_add_segment_occ,
    sched_trace_worker_busy_total,
    sched_trace_add_dispatch,
    sched_trace_get_site,
)
from komira_async.morsel.morsel_pool import MorselPool
from komira_async.ops.waker_sink import WakerSink
from komira_async.runtime.for_each_morsel import (
    MorselBody,
    _ForEachPooledSegment,
    _ForEachState,
    _ForEachStaticSegment,
    _next_pow2_ge,
)
from komira_async.runtime.nested_borrow_bundle import NestedBorrowBundle
from komira_async.runtime.wake_primitives import (
    WorkerWakeHandle,
    cpu_pause,
    wait_on_address,
    wake_one_by_address,
)
from komira_core.collections.slab import Slab
from komira_core.runtime_traits.worker_pool_traits import KeepAlive, Segment
from komira_core.runtime_traits.parallel_dispatch import ParallelDispatch

# -----------------------------------------------------------------------------
# ⚠ THE BARRIER-STALL DUMP GOES TO **STDERR**, NEVER STDOUT.
#
# The barrier-stall dump can be linked into a binary whose contract is that
# **stdout is the RESULT STREAM and nothing else** — an Arrow IPC stream or a
# TSV render, read by a caller in another process. A bare `print` here writes
# to fd 1, so the ONE diagnostic this hang class has was being interleaved into
# the answer.
#
# Concretely: a few hundred bytes
# of `[BARRIER-STALL]` text ahead of an Arrow IPC stream make a reader take
# the ASCII `[BAR` as the stream's length prefix —
#     ArrowInvalid: Expected to read 1380008539 metadata bytes, but only read 776
# (`[BAR` is `5b 42 41 52`, read LITTLE-ENDIAN as 0x5241425B == 1380008539 —
# the number in the message.) The answer was INTACT at offset 0x1e4; only the
# channel was corrupt.
#
# ⚠ ROUTED, NOT DELETED. A watchdog that prints nowhere is worse than one that
# prints to the wrong fd: it hides a real stall. The dump is unchanged in
# content; only its destination moved.
#
# The same stderr spelling a binary's own diagnostics use. Not
# `komira_log`'s `StderrSink`: that would add a package dependency from
# `komira_async` to `komira_log` for a five-call diagnostic, and
# `print(file=...)` needs no FFI declaration of its own.
# -----------------------------------------------------------------------------

comptime _STDERR: FileDescriptor = FileDescriptor(2)


# =============================================================================
# _LdErrorSlot — first-error-wins error slot for one dispatch.
# =============================================================================
#
# Heap-stable via OwnedPointer wrap on the Atomic flag (Atomic[uint8] is
# non-Movable on Mojo 0.26.3). The error message is a Movable String.
# Same shape as the stdlib-parallelize version it replaced.


struct _LdErrorSlot(Movable, Deinitable):
    """First-error-wins error slot for one dispatch."""

    var _flag: OwnedPointer[AtomicU8]
    var _message: String

    def __init__(out self):
        var raw = alloc[AtomicU8](1)
        # SAFETY: as for Worker._shutdown_flag / LocalIoBlock._park_word.
        raw[] = AtomicU8(UInt8(0))
        self._flag = OwnedPointer[AtomicU8](
            unsafe_from_raw_pointer=raw,
        )
        self._message = String("")

    def try_set(mut self, message: String) -> Bool:
        """First caller wins the CAS and writes its message. Returns True
        if THIS caller won. Subsequent callers observe flag != 0 and
        bail out without overwriting."""
        var expected = UInt8(0)
        var won = self._flag[].compare_exchange(expected, UInt8(1))
        if won:
            self._message = message
        return won

    def is_set(self) -> Bool:
        return self._flag[].load() != UInt8(0)

    def message(self) -> String:
        return self._message


# =============================================================================
# _DispatchCtx[State, T] — the per-dispatch context the shards borrow INTO.
# =============================================================================
#
# The `StateBoundWork` concrete-origin
# Ctx frame (shared_erasure.mojo; validated against THIS exact shape by
# tests/test_shared_erasure_real_shapes.mojo's
# `_RealDispatchCtx`). Bundles the EXACT SIX borrows the old `_DispatchShard`
# carried as six wildcard pointer fields, under ONE owner so every shard's
# borrow shares ONE concrete `origin`:
#
#   old _DispatchShard wildcard field   ->  _DispatchCtx member (reached by ref)
#   --------------------------------------------------------------------------
#   state_ptr  (State: KeepAlive)       ->  the borrowed `mut state` (by ref)
#   seg_ptr    (T: Segment)             ->  the shared Segment in _seg_buf (by ptr)
#   in_flight_ptr (Atomic[int64])       ->  in_flight (by ptr into the dispatcher)
#   wake_word_ptr (Atomic[int32])       ->  wake_word (by ptr into the dispatcher)
#   error_slot_ptr (_LdErrorSlot)       ->  error_slot (stack-frame, by ptr)
#   cancel_token_ptr (CancellationToken)->  cancel (stack-frame `var`, by ptr)
#
# WHY ONE BORROWED Ctx (the load-bearing design choice): a CONCRETE origin
# parameter cannot carry six INDEPENDENT borrows the way the wildcard erased
# (the wildcard widened every origin to the same `MutExternalOrigin`). The Mojo
# compiler requires every borrow bound to one struct `origin` to share that
# exact origin — so the correct, strictly-safer generalization is to BUNDLE the
# borrowed state into ONE caller-owned `_DispatchCtx` that lives on the
# `run_with_state` stack frame; the shards borrow INTO it. This is precisely
# how a real per-core dispatcher owns ONE per-dispatch frame and the shards
# borrow into it.
#
# `_DispatchCtx` holds the SHARED Segment / borrowed State BY POINTER (not by
# value): `T` and `State` are borrowed for the dispatch window, not owned by the
# ctx. The Segment lives in the dispatcher's `_seg_buf` slab; the State is the
# caller's `mut state`. Both are reached through concrete-origin `Pointer`s
# whose origin is tied to the dispatcher's `self` (the slab owner) and to the
# caller's state respectively. The per-dispatch atomics + error slot + cancel
# token are likewise reached by-pointer — all live AT LEAST as long as the
# `run_with_state` frame, which the wake-word barrier holds until every shard
# returns.
#
# Destroy-recreate note: `_DispatchCtx` is NOT stored in a byte-slab — it lives directly on
# the `run_with_state` stack frame. Its pointer members are POD; nothing here is
# the byte-slab + wildcard + heap-owning-inner-field trap. The `_DispatchShard`
# holds only ONE concrete-origin `Pointer` to this ctx + 3 ints — still POD,
# still safe across destroy-recreate — and since the per-shard home it lives in its OWN heap home, not a
# recycled slab slot.


struct _DispatchCtx[
    State: KeepAlive,
    T: Segment,
    state_origin: Origin[mut=True],
    seg_origin: Origin[mut=True],
    in_flight_origin: Origin[mut=True],
    wake_word_origin: Origin[mut=True],
    slot_origin: Origin[mut=True],
    cancel_origin: Origin[mut=True],
](Movable, Deinitable):
    """The per-dispatch context every shard borrows INTO. Bundles the six
    borrows the old six-wildcard-field `_DispatchShard` carried, under one owner
    so each shard's borrow shares ONE tracked origin (the `StateBoundWork`
    design). Lives on the `run_with_state` stack frame; the wake-word barrier
    holds it alive until every shard's trampoline returns.

    The members are reached BY CONCRETE-ORIGIN POINTER (the State + shared
    Segment are borrowed, not owned; the atomics + error slot are owned by the
    dispatcher / stack frame and likewise borrowed here). NO wildcard origin on
    any field — every `Pointer` carries the concrete origin of the thing it
    borrows, so ASAP-destruction tracking sees the full lifetime chain.
    """

    # Borrowed pointer to the caller's `mut state: State`. Concrete origin.
    var _state: Pointer[Self.State, Self.state_origin]
    # Borrowed pointer to the SHARED Segment value held in the dispatcher's
    # `_seg_buf` slab for the dispatch window. Multiple shards read through this
    # concurrently — Segment.execute must be safe under shared-read access.
    var _seg: Pointer[Self.T, Self.seg_origin]
    # Borrowed pointer to the per-dispatch in-flight counter (heap-stable
    # Atomic[int64] owned by the dispatcher).
    var _in_flight: Pointer[AtomicI64, Self.in_flight_origin]
    # Borrowed pointer to the per-dispatch wake-word (heap-stable Atomic[int32]
    # owned by the dispatcher).
    var _wake_word: Pointer[AtomicI32, Self.wake_word_origin]
    # Borrowed pointer to the per-dispatch error slot (stack-allocated on the
    # dispatcher's `run_with_state` frame; lives for the dispatch window).
    var _error_slot: Pointer[_LdErrorSlot, Self.slot_origin]
    # Borrowed pointer to the caller-supplied CancellationToken (the `var`
    # parameter slot on the `run_with_state` frame).
    var _cancel: Pointer[CancellationToken, Self.cancel_origin]

    def __init__(
        out self,
        ref [Self.state_origin] state: Self.State,
        ref [Self.seg_origin] seg: Self.T,
        ref [Self.in_flight_origin] in_flight: AtomicI64,
        ref [Self.wake_word_origin] wake_word: AtomicI32,
        ref [Self.slot_origin] error_slot: _LdErrorSlot,
        ref [Self.cancel_origin] cancel: CancellationToken,
    ):
        # Pointer(to=ref) ties each pointer's origin to the ref's origin — NO
        # wildcard cast, NO Int laundering.
        self._state = Pointer(to=state)
        self._seg = Pointer(to=seg)
        self._in_flight = Pointer(to=in_flight)
        self._wake_word = Pointer(to=wake_word)
        self._error_slot = Pointer(to=error_slot)
        self._cancel = Pointer(to=cancel)

    @always_inline
    def state_ref(self) -> ref [Self.state_origin] Self.State:
        """Borrow the State through the concrete-origin pointer (ref tied to the
        inner pointer's origin — Repro 5/5b)."""
        return self._state[]

    @always_inline
    def seg_ref(self) -> ref [Self.seg_origin] Self.T:
        """Borrow the SHARED Segment through the concrete-origin pointer. SHARED
        by construction — every shard built over the SAME ctx reaches the SAME
        Segment home."""
        return self._seg[]

    @always_inline
    def in_flight_ref(self) -> ref [Self.in_flight_origin] AtomicI64:
        return self._in_flight[]

    @always_inline
    def wake_word_ref(self) -> ref [Self.wake_word_origin] AtomicI32:
        return self._wake_word[]

    # -------------------------------------------------------------------------
    # BARRIER-ORDERING accessors — hand back the borrowed POINTER by value.
    # -------------------------------------------------------------------------
    #
    # The ordering inversion, the ORDERING INVERSION.
    #
    # `_DispatchShard.run` must perform its LAST ctx dereference STRICTLY BEFORE
    # the `in_flight` decrement that releases the driver's barrier. The moment
    # `fetch_sub` returns `prev == 1` the driver is free to leave the barrier,
    # drop `ctx`, and unwind the `run_with_state` frame — so ANY `self.ctx_ref()`
    # load after that decrement reads a stack frame that may already be popped
    # (a core dump of this fault shows a shard
    # dereferencing a ctx 21,792 bytes BELOW the driver's live `rsp`).
    #
    # These two accessors return the `Pointer` FIELD BY VALUE (a POD 8-byte copy
    # whose origin is still the concrete borrow origin). The shard copies both
    # pointers into locals BEFORE the decrement, so the post-decrement wake
    # sequence touches ONLY the two dispatcher-owned heap atomics (which are
    # `OwnedPointer`-stable for the whole life of the dispatcher and therefore
    # outlive every worker — the runtime joins all workers in its `__del__`
    # before the dispatcher drops) and NEVER the caller's stack frame again.
    #
    # NOT a wildcard cast and NOT an `UnsafePointer`: `Pointer[T, origin]` is the
    # safe reference type and the origin travels with the copy.
    @always_inline
    def in_flight_ptr(
        self,
    ) -> Pointer[AtomicI64, Self.in_flight_origin]:
        return self._in_flight

    @always_inline
    def wake_word_ptr(
        self,
    ) -> Pointer[AtomicI32, Self.wake_word_origin]:
        return self._wake_word

    @always_inline
    def error_slot_ref(self) -> ref [Self.slot_origin] _LdErrorSlot:
        return self._error_slot[]

    @always_inline
    def cancel_ref(self) -> ref [Self.cancel_origin] CancellationToken:
        return self._cancel[]


# =============================================================================
# _ShardMarkTable — the per-dispatch DELIVERED / ENTERED shard bitmasks.
# =============================================================================
#
# THE BUG THIS TYPE EXISTS TO REMOVE.
# These two masks used to share ONE `Atomic[DType.int64]`, split 32/32:
# DELIVERED at `1 << (32 + (wid & 31))`, ENTERED at `1 << (wid & 63)`. Those
# ranges overlap. `wid = 32`'s ENTERED bit IS `wid = 0`'s DELIVERED bit;
# `wid = 63`'s ENTERED mark `fetch_add`s the Int64 SIGN BIT; `wid >= 64` wraps
# onto `wid - 64`. Worker count is NOT capped — `run_with_state` shards across
# `_worker_senders.len()`, which the runtime sizes from `physical_core_count()`
# — so on an 88-core host every dispatch above 32 workers produced a corrupt
# `[BARRIER-STALL]` dump, which is the ONLY diagnostic that exists for the
# barrier hang class. Measured pre-fix at 40 workers: the cell
# settles at `0x000001FD_FFFFFFFF` and 25 of the 40 delivered shards read back
# as never delivered.
#
# THE FIX IS THE ENCODING, NOT A CAP. Refusing to shard above 32 (or 64)
# workers would be a new regression on exactly the hosts bought for
# parallelism. Each mask gets its OWN word array here, so a (mask, wid) pair
# owns a bit that nothing else can reach.
#
# ⚠ WHY `fetch_add` AND NOT `fetch_or`, AND WHY THAT IS STILL TRUE.
# This stdlib's `Atomic` exposes add / sub / xchg / max / min / compare_exchange
# and NO bitwise RMW — re-verified against `std/atomic/atomic.mojo` on the
# pinned Mojo 1.0.0b2. So the mark is `fetch_add` of a distinct
# power of two, which equals `fetch_or` while each bit is added AT MOST ONCE.
# That is not merely a workaround: when the at-most-once property breaks, the
# CARRY makes the mask visibly wrong, and a shard that ran twice is the
# double-decrement bug announcing itself. THE SIGNAL SURVIVES THIS CHANGE
# BECAUSE IT IS NOW UNAMBIGUOUS: with the two masks disjoint and one bit per
# wid, a carry has exactly ONE remaining cause — the same wid marked the same
# mask twice. Under the old layout a carry could equally mean "two different
# wids, two different masks, one bit", so the signal could not be read at all
# above 32 workers. Do not switch these to a CAS loop to "make it clean": the
# carry is load-bearing evidence.
#
# CAPACITY AND WHAT HAPPENS PAST IT. `WORDS = 16` covers wids 0..1023, far
# above any single-host `physical_core_count()`. A wid outside that range is
# NOT folded onto a valid wid's bit (that is the bug being fixed); it is
# counted in `_overflow`, which the stall dump prints. A dropped mark makes the
# masks under-report, and the counter is what says so out loud instead of
# corrupting a neighbour.
struct _ShardMarkTable(Deinitable):
    """Two independent per-dispatch bitmasks over worker ids: DELIVERED (the
    shard reached `run()`) and ENTERED (it passed the generation guard and ran
    its body). Heap-owned by the dispatcher, marked concurrently by every
    worker, read by the barrier's stall dump. POD interior (two `InlineArray`s
    of `Int64` + one `Int64`), so it is safe across destroy-recreate and its address is stable for
    the dispatcher's whole life — which is what makes it safe for a shard to
    mark through a recycled pool slot."""

    comptime WORDS: Int = 16
    comptime CAPACITY: Int = 64 * Self.WORDS

    # SAFETY: plain Int64 storage, mutated ONLY through the static
    # `Atomic[DType.int64]` ops below (the same shape the dispatcher already
    # uses for `_in_flight`). Never read or written non-atomically after
    # construction. `UnsafePointer` never leaves this struct.
    var _delivered: Array[Int64, Self.WORDS]
    var _entered: Array[Int64, Self.WORDS]
    # Marks refused for being outside [0, CAPACITY). See the header.
    var _overflow: Int64

    def __init__(out self):
        self._delivered = Array[Int64, Self.WORDS](fill=Int64(0))
        self._entered = Array[Int64, Self.WORDS](fill=Int64(0))
        self._overflow = Int64(0)

    @always_inline
    def _bump_overflow(mut self):
        _ = AtomicI64.fetch_add(
            UnsafePointer(to=self._overflow), Int64(1)
        )

    @always_inline
    def mark_delivered(mut self, wid: Int32):
        """Record that `wid`'s shard reached `run()`. One atomic RMW."""
        var w = Int(wid)
        if w < 0 or w >= Self.CAPACITY:
            self._bump_overflow()
            return
        _ = AtomicI64.fetch_add(
            UnsafePointer(to=self._delivered[w >> 6]),
            Int64(1) << Int64(w & 63),
        )

    @always_inline
    def mark_entered(mut self, wid: Int32):
        """Record that `wid`'s shard passed the generation guard and entered its
        body. One atomic RMW, in a word array DISJOINT from `mark_delivered`'s —
        that disjointness is the whole fix."""
        var w = Int(wid)
        if w < 0 or w >= Self.CAPACITY:
            self._bump_overflow()
            return
        _ = AtomicI64.fetch_add(
            UnsafePointer(to=self._entered[w >> 6]),
            Int64(1) << Int64(w & 63),
        )

    def reset(mut self):
        """Zero both masks + the overflow counter. Called at `run_with_state`
        entry, before any shard of the new dispatch is posted.

        Deliberately unbounded — every word, not just the ones the current
        worker count reaches. A `reset(n_wids)` variant would save ~30 stores
        per dispatch and would be correct only while `wid < worker_count()`
        holds everywhere forever; that is a subtler invariant than this costs to
        avoid. Upper bound on the cost: 33 seq-cst stores into two cache-hot
        128-byte regions the previous dispatch just wrote, against an enqueue
        loop that already does a heap alloc, an MPSC send and a possible wake
        SYSCALL per shard. Note the layout also SPLITS the two masks onto
        different cache lines, where the shared cell had every worker's
        DELIVERED and ENTERED mark contending on one."""
        var i = 0
        while i < Self.WORDS:
            AtomicI64.store(
                UnsafePointer(to=self._delivered[i]), Int64(0)
            )
            AtomicI64.store(
                UnsafePointer(to=self._entered[i]), Int64(0)
            )
            i += 1
        AtomicI64.store(
            UnsafePointer(to=self._overflow), Int64(0)
        )

    def delivered_word(self, i: Int) -> Int64:
        """Raw word `i` of the DELIVERED mask — wids `64*i .. 64*i+63`."""
        if i < 0 or i >= Self.WORDS:
            return Int64(0)
        return AtomicI64.load(UnsafePointer(to=self._delivered[i]))

    def entered_word(self, i: Int) -> Int64:
        """Raw word `i` of the ENTERED mask — wids `64*i .. 64*i+63`."""
        if i < 0 or i >= Self.WORDS:
            return Int64(0)
        return AtomicI64.load(UnsafePointer(to=self._entered[i]))

    def delivered_bit(self, wid: Int) -> Bool:
        if wid < 0 or wid >= Self.CAPACITY:
            return False
        return (
            (self.delivered_word(wid >> 6) >> Int64(wid & 63)) & Int64(1)
        ) != Int64(0)

    def entered_bit(self, wid: Int) -> Bool:
        if wid < 0 or wid >= Self.CAPACITY:
            return False
        return (
            (self.entered_word(wid >> 6) >> Int64(wid & 63)) & Int64(1)
        ) != Int64(0)

    def overflow_marks(self) -> Int64:
        """Marks dropped for being outside [0, CAPACITY). Non-zero means the
        masks UNDER-report; it never means a neighbour was corrupted."""
        return AtomicI64.load(UnsafePointer(to=self._overflow))


# =============================================================================
# _DispatchShard — per-shard descriptor, the BORROWED/POOLED ErasedHandle member.
# =============================================================================
#
# The production `StateBoundWork`-shaped
# shard. Formerly carried SIX `UnsafePointer[_, MutExternalOrigin]` wildcard
# fields; now holds ONE `Pointer[_DispatchCtx, origin]` concrete-origin field +
# lo/hi/wid (the `_RealShard` shape proven in test_shared_erasure_real_shapes).
#
# `_DispatchShard` is now an
# `ErasableWork` member of the `ErasedHandle` family, carrying the FULL
# `_DispatchCtx` param set so its `run()` can call the typed ctx accessors + the
# REAL `seg.execute[State]` trait dispatch. The run body moved off the standalone
# `_run_shard_for` trampoline INTO `_DispatchShard.run()`; the channel now carries
# the Movable-only `ErasedHandle` (retiring the bespoke `_TaskEntry` POD).
#
# One shard descriptor per worker per dispatch. The dispatcher builds N_WORKERS
# descriptors at dispatch entry, binds each to the SAME `_DispatchCtx` (the
# bundle of the six borrows) with its (lo, hi) range, and publishes one OWNING
# `ErasedHandle` per shard onto the matching worker's MPSC queue via
# `make_erased[ShardT]` (the per-shard home, each shard owns its home; the
# `__del__` no-ops, so the pool keeps + reuses the bytes). The worker's drain
# step runs `handle.run()` BLIND; the family's per-W run trampoline dispatches to
# `_DispatchShard.run()`, which loops [lo, hi) calling
# `ctx.seg_ref().execute(ctx.state_ref(), wid, tid)` on the SHARED Segment over
# the borrowed State, fetch_subs in_flight, on last decrement bumps wake_word +
# futex wakes.
#
# WHY the concrete origin survives the MPSC channel: `make_erased[ShardT]`
# monomorphizes the family run trampoline `_erased_run_for[ShardT]` for THIS
# `ShardT` (which carries `origin_of(ctx)`); the trampoline bitcasts the
# channel-erased byte ptr back to `ShardT` recovering the SAME concrete origin
# (the blessed `_TaskEntry.task_raw` byte-ptr carve-out, now inside the family).
# The `origin` is therefore compiler-tracked end-to-end, and the wake-word
# barrier enforces that the borrowed ctx outlives every shard's `run`.


struct _DispatchShard[
    State: KeepAlive,
    T: Segment,
    state_origin: Origin[mut=True],
    seg_origin: Origin[mut=True],
    in_flight_origin: Origin[mut=True],
    wake_word_origin: Origin[mut=True],
    slot_origin: Origin[mut=True],
    cancel_origin: Origin[mut=True],
    gen_origin: Origin[mut=True],
    viol_origin: Origin[mut=True],
    marks_origin: Origin[mut=True],
    detail_origin: Origin[mut=True],
    cursor_origin: Origin[mut=True],
    origin: Origin[mut=True],
](Movable, Deinitable, ErasableWork):
    """Per-shard descriptor — the BORROWED/POOLED member of the `ErasedHandle`
    family. One per worker per dispatch.

    Holds ONE concrete-origin `Pointer[_DispatchCtx, origin]` to the bundled
    `_DispatchCtx` (NOT six wildcard fields), plus the shard's [lo, hi) task
    range + worker id. The `origin` ties the borrow to the caller's `ctx` home;
    the wake-word barrier guarantees no `run` reads through it after the `ctx`
    could go out of scope. POD (one Pointer + 3 ints; no heap-owning interior),
    so the bytes are a plain `alloc[ShardT](1)` home owned by this shard's handle
    and freed with it (safe across destroy-recreate). They are NOT reused across dispatches — see
    the per-shard home on the enqueue loop for why that reuse was the UAF.

    this struct is now an `ErasableWork` and is carried through the SAME
    `MpscChannel[ErasedHandle]` the spawner uses, via the OWNING family member
    (`make_erased`) — its `__del__` destroys + frees this shard's home, strictly
    after the run trampoline has returned. The run body that used to live
    in the standalone `_run_shard_for` trampoline is now `run()` below; it
    reaches the SHARED Segment + borrowed State + atomics through the bound ctx.
    The full `_DispatchCtx` param set is carried on the struct so `run()` can call
    the typed `_DispatchCtx` accessors (`seg_ref` / `state_ref` / ...) and the
    REAL `seg.execute[State]` trait dispatch.
    """

    # Borrowed per-dispatch context home, concrete `origin` — NOT a wildcard.
    # The caller (run_with_state) retains ownership; the barrier blocks until
    # every shard's `run` returns before the ctx scope ends.
    var _ctx: Pointer[
        _DispatchCtx[
            Self.State,
            Self.T,
            Self.state_origin,
            Self.seg_origin,
            Self.in_flight_origin,
            Self.wake_word_origin,
            Self.slot_origin,
            Self.cancel_origin,
        ],
        Self.origin,
    ]
    # --- the GENERATION STAMP ---
    #
    # WHY THIS EXISTS (read before "simplifying" it away).
    #
    # `_ctx` above is a pointer into the DRIVER'S STACK FRAME, so it is only
    # meaningful for the ONE dispatch generation that built this shard. Before
    # this stamp existed, a handle that outlived its dispatch by any route at all
    # dereferenced a popped stack frame — the bytes give no hint that
    # they are stale, so the barrier was the ENTIRE safety argument with no
    # runtime check behind it.
    #
    # Field proof: the
    # faulting worker's `_home` slot (wid=8) held `{ctx=0x7fff6a180400, lo=25,
    # hi=28}` — an n=64-over-20-workers shape, i.e. the COMBINE dispatch — while
    # all 19 sibling slots held the LIVE radix-drain ctx `{ctx=0x7fff6a17f0c0,
    # lo=wid, hi=wid+1}`. The stale ctx's `_cancel` pointed at a destroyed
    # `CancellationToken` whose `ArcPointer` box had already been recycled into
    # unrelated heap data, so the cancel poll's `movzbl (%rsi)` took the SIGSEGV.
    # The token was the VICTIM (the first heap-owning field the shard touches),
    # NOT the cause: the current dispatch's own token was healthy (strong=5).
    #
    # THE STAMP MAKES THE HANDLE SELF-VERIFYING. `_gen` is the dispatch
    # generation that wrote this slot; `_gen_cell` points at the dispatcher's
    # heap generation counter. `run()` compares them FIRST and returns having
    # touched NOTHING when they differ.
    #
    # SAFETY — why reading these two fields is sound even when the shard IS
    # stale, unlike `_ctx`: both are read out of this shard's own home, which the
    # handle keeps alive for the whole call, and both point
    # at dispatcher-owned `OwnedPointer[Atomic]` cells whose addresses are
    # STABLE for the dispatcher's whole life and identical for every generation
    # (empirically confirmed in the core: the stale ctx and the live ctx carried
    # the SAME `_in_flight` / `_wake_word` heap addresses). The runtime joins
    # every worker in its `__del__` before the dispatcher drops, so these cells
    # outlive every shard. `_ctx`, by contrast, is a STACK pointer — which is
    # exactly why it may not be dereferenced before the stamp check passes.
    var _gen_cell: Pointer[AtomicI64, Self.gen_origin]
    # STALE-SHARD refusal counter (diagnostic). Bumped ONLY when this shard
    # refuses on a generation mismatch. Deliberately SEPARATE from the
    # entry-leftover counter on the dispatcher (they were one conflated counter
    # at one point; a hang core showed the value 1 and it could not be
    # attributed to either cause, which is what stalled the diagnosis).
    var _viol_cell: Pointer[AtomicI64, Self.viol_origin]
    # PER-DISPATCH "this shard reached its body" counter (diagnostic). Bumped
    # immediately AFTER the generation guard passes, i.e. exactly once per shard
    # that will go on to run + decrement. `run_with_state` zeroes it at entry, so
    # in a stuck barrier `entered` vs `n_posted` vs `in_flight` separates the
    # three possible causes of a missing decrement:
    #   entered <  n_posted            -> a posted shard NEVER reached run()
    #                                     (never drained, or refused - the
    #                                     refusal counter above disambiguates)
    #   entered == n_posted, in_flight>0 -> a shard ran its body but never
    #                                     reached its `fetch_sub` (raised, or
    #                                     is still inside seg.execute)
    var _marks: Pointer[_ShardMarkTable, Self.marks_origin]
    # Last refusal's DETAIL, packed so one atomic carries it:
    #   bits 63..40 = the generation this shard OBSERVED in `_gen_cell`
    #   bits 39..16 = the generation STAMPED into this shard's slot
    #   bits 15..0  = the shard's wid
    # Written only on the refusal path, so it costs nothing on healthy traffic.
    # The counts alone cannot tell "the guard refused THIS dispatch's shard"
    # from "the guard refused a genuinely stale handle and a DIFFERENT shard was
    # never delivered" — and those are opposite bugs.
    var _detail_cell: Pointer[AtomicI64, Self.detail_origin]
    # ---- FORK-JOIN CLAIMING: the SHARED per-dispatch task cursor ----
    #
    # The dispatcher-owned `Atomic[int64]` every shard of THIS dispatch claims
    # from when `_claim` is true. Reached by CONCRETE origin (`Pointer(to=ref)`
    # of `self._task_cursor[]`), never a wildcard; the cell lives on the
    # dispatcher's own heap (`OwnedPointer[Atomic]`, address-stable) rather than
    # on the driver frame, so — unlike `_ctx` — reading it is sound even from a
    # slot the generation guard is about to refuse.
    var _cursor: Pointer[AtomicI64, Self.cursor_origin]
    # True => claim task ids dynamically off `_cursor`; False => run the static
    # [lo, hi) range, byte-for-byte the static-split loop. One Bool per shard,
    # copied from the dispatcher's construction-time gate — no getenv anywhere
    # on this path.
    var _claim: Bool
    # The dispatch generation that wrote this slot.
    var _gen: Int64
    # Inclusive lower / exclusive upper task-id bounds for this shard.
    # Under fork-join claiming `lo`/`hi` are NOT the execution range (the cursor is); they
    # are retained because the BARRIER-STALL dump and the shard-refusal detail
    # print them, and because they are the OFF arm's execution range.
    var lo: Int64
    var hi: Int64
    # Exclusive upper bound over ALL task ids in this dispatch (== `n`). Under
    # fork-join claiming this is the loop bound; it is `hi` for the last shard only.
    var n_all: Int64
    # Worker id (also implicit in the queue this entry was posted to).
    var wid: Int32

    def __init__(
        out self,
        ref [Self.origin] ctx: _DispatchCtx[
            Self.State,
            Self.T,
            Self.state_origin,
            Self.seg_origin,
            Self.in_flight_origin,
            Self.wake_word_origin,
            Self.slot_origin,
            Self.cancel_origin,
        ],
        ref [Self.gen_origin] gen_cell: AtomicI64,
        ref [Self.viol_origin] viol_cell: AtomicI64,
        ref [Self.marks_origin] marks: _ShardMarkTable,
        ref [Self.detail_origin] detail_cell: AtomicI64,
        ref [Self.cursor_origin] cursor: AtomicI64,
        gen: Int64,
        lo: Int64,
        hi: Int64,
        n_all: Int64,
        wid: Int32,
        claim: Bool,
    ):
        # Pointer(to=ref) ties the pointer's origin to the ref's origin — NO
        # wildcard cast.
        self._ctx = Pointer(to=ctx)
        self._gen_cell = Pointer(to=gen_cell)
        self._viol_cell = Pointer(to=viol_cell)
        self._marks = Pointer(to=marks)
        self._detail_cell = Pointer(to=detail_cell)
        self._cursor = Pointer(to=cursor)
        self._claim = claim
        self._gen = gen
        self.lo = lo
        self.hi = hi
        self.n_all = n_all
        self.wid = wid

    @always_inline
    def ctx_ref(self) -> ref [Self.origin] _DispatchCtx[
        Self.State,
        Self.T,
        Self.state_origin,
        Self.seg_origin,
        Self.in_flight_origin,
        Self.wake_word_origin,
        Self.slot_origin,
        Self.cancel_origin,
    ]:
        """Borrow the bound per-dispatch context through the concrete-origin
        pointer (ref tied to the inner pointer's origin — Repro 5/5b). The
        SHARED Segment + State + atomics are reached as members of this ctx,
        SHARED across every shard built over the SAME ctx."""
        return self._ctx[]

    def run(mut self) raises -> None:
        """The BORROWED/POOLED family member's run arm — runs one shard's
        [lo, hi) task range on the worker's pthread. The body that used to live
        in the standalone `_run_shard_for` trampoline.

        Reaches the SHARED Segment + borrowed State + atomics + error slot +
        cancel token through the bound concrete-origin `_DispatchCtx` pointer
        (`ctx_ref()`), folds each tid's `[lo, hi)` slice into the State via the
        REAL `seg.execute[State](state, wid, tid)` trait dispatch, fetch_subs
        in_flight, and on the last decrement bumps the wake-word + futex-wakes
        the driver.

        `ErasedHandle.run` uses the work IN-PLACE (no consume); the
        OWNING handle's `__del__` then destroys + frees this shard's home. That
        ordering is load-bearing — see the per-shard home. REQUIRED method (no trait
        default to statically shadow it post-erasure — the `ErasableWork`
        dispatch finding).
        """
        # --- STALE-GENERATION GUARD ---
        #
        # THIS MUST BE THE FIRST STATEMENT IN `run`, AND IT MUST PRECEDE EVERY
        # `self.ctx_ref()`. `self._ctx` points into the driver's STACK FRAME and
        # these bytes live in a RECYCLED pool slot; dereferencing `_ctx` before
        # proving the slot still belongs to a LIVE dispatch is precisely the
        # use-after-free a hang core captured (see the `_gen_cell` field
        # comment for the slab dump). `_gen_cell` / `_gen` are read from
        # dispatcher-owned heap, so reading THEM on a stale slot is sound.
        #
        # `_dispatch_gen` is bumped at dispatch entry AND again at the end of
        # `_drain_in_flight_barrier`, so `_gen_cell[] == self._gen` holds EXACTLY
        # while the dispatch that stamped this slot is still inside its barrier —
        # i.e. exactly while `_ctx` is still alive. Any other moment is a
        # barrier violation, and the only safe action is to touch nothing:
        # in particular we must NOT `fetch_sub` `in_flight`, because that counter
        # now belongs to a DIFFERENT dispatch and an extra decrement there would
        # release a later driver's barrier early — the mechanism that propagates
        # one leaked handle into a cascade of them.
        #
        # Do NOT "simplify" this into a check inside the task loop, and do NOT
        # move it after a `ctx_ref()` — either change re-opens the UAF.
        # DELIVERED mark, recorded BEFORE the guard, in the per-dispatch
        # DELIVERED mask (the ENTERED mask is marked after the guard).
        # This is the bit that separates the two remaining explanations for a
        # missing decrement, which the counts alone cannot: a shard that was
        # never handed to its worker leaves BOTH bits clear, while one that was
        # handed over and then refused leaves DELIVERED set and ENTERED clear.
        # Reading `self.wid` here is the same read the guard below
        # already performs, so it adds no new exposure on a stale slot.
        #
        # The two masks are SEPARATE WORD ARRAYS (`_ShardMarkTable`), not two
        # halves of one Int64. Sharing one cell would be
#         wrong: `wid = 32`'s ENTERED bit would be `wid = 0`'s
#         DELIVERED bit, so on any host wide enough to fan out past 32 workers
#         the dump would lie.
        self._marks[].mark_delivered(self.wid)
        var seen_gen = self._gen_cell[].load()
        if seen_gen != self._gen:
            _ = self._viol_cell[].fetch_add(Int64(1))
            # Record WHICH shard refused and against WHICH pair of generations.
            AtomicI64.store(
                UnsafePointer(to=self._detail_cell[]).unsafe_bitcast[Scalar[DType.int64]](),
                ((seen_gen & Int64(0xFFFFFF)) << 40)
                | ((self._gen & Int64(0xFFFFFF)) << 16)
                | (Int64(self.wid) & Int64(0xFFFF)),
            )
            # NOTE — do NOT add a `print` (or any address-taking
            # of `self`) to this branch. A shard-side probe here was measured to
            # SUPPRESS the defect entirely: 6 hangs / 12 reps without it, 0 / 52
            # with it. `run()`'s codegen is part of the race, so any observable
            # placed inside it changes the thing being measured. Every refusal
            # observable must be recorded through the dispatcher-owned atomics
            # above and printed from `_drain_in_flight_barrier` instead.
            return
        # Diagnostic: this shard's slot is LIVE and we are committed to running
        # the body + the `fetch_sub` below. Bumped here — after the guard, before
        # the first `ctx_ref()` — so a stuck barrier can tell "never reached the
        # body" from "reached the body and did not come back". A BITMASK, not a
        # count, so the dump can NAME the missing wid.
        # Still `fetch_add` of a distinct power of two, not `fetch_or` (which
        # this stdlib's Atomic still does not expose —
        # it has add/sub/xchg/max/min/CAS and no bitwise RMW). Equivalent here
        # because each wid sets its own bit at most ONCE per dispatch — and if
        # that ever stops being true, the carry makes the mask visibly wrong,
        # which is itself the signal (a shard that ran twice is the
        # double-decrement bug). THE SEPARATE-ARRAY LAYOUT IS WHAT KEEPS THAT
        # SIGNAL READABLE: one bit per (mask, wid) means a carry now has exactly
        # one possible cause. Under the old shared cell a carry could equally be
        # two different wids colliding across the two masks, which is why the
        # signal was unusable above 32 workers.
        self._marks[].mark_entered(self.wid)
        var lo = self.lo
        var hi = self.hi
        var wid = self.wid
        # ---------------------------------------------------------------------
        # FORK-JOIN CLAIMING — WHICH TASK IDS THIS SHARD RUNS.
        #
        # OFF (`set_claim_enabled(False)`): the static contiguous range
        # `[wid*n/nw, (wid+1)*n/nw)` computed by the enqueue loop, i.e. the
        # static-split instruction stream byte-for-byte.
        #
        # ON (default): every shard claims the NEXT unclaimed task id off ONE
        # shared cursor. `fetch_add(1)` is the claim, so a task id is handed to
        # exactly ONE shard and every id in `[0, n_all)` is handed out exactly
        # once — the same per-`tid` disjointness contract every Segment is
        # already written against. Nothing about the Segment API changes: it
        # still receives `(state, wid, tid)`.
        #
        # WHY. Consider a site whose scatter dispatch
        # has n=32 tasks over nw=22 workers:
        # under the static split 10 workers
        # draw 2 slices and 12 draw 1, so the wall is set by a DOUBLE slice
        # while half the pool is parked. 32/(22*2) = 0.727 is the occupancy
        # that geometry predicts. A shared cursor removes the geometry: a
        # worker that finishes early takes the next id instead of parking.
        #
        # COST. One `fetch_add` per task. Tasks in this engine are morsels /
        # partitions / row-group bands — never single rows — so the RMW is far
        # below the body it guards; the OFF arm exists for the case that is ever
        # not true.
        #
        # The two loops are written out SEPARATELY on purpose: the OFF arm must
        # be the previous instruction stream, or an A/B of this gate measures
        # the branch as well as the lever.
        # ---------------------------------------------------------------------
        if not self._claim:
            var tid = lo
            while tid < hi:
                # Skip remaining tasks if a prior shard already errored. Cheap
                # unsynchronized read (a benign racy fast-path read).
                if self.ctx_ref().error_slot_ref().is_set():
                    break
                # Cancellation: poll the per-dispatch token between tids.
                # First worker to observe cancel writes a "CancelledError" into
                # the error slot via the same first-error-wins CAS that captures
                # execute() errors. Subsequent workers observe
                # error_slot.is_set() and bail out without overwriting.
                if self.ctx_ref().cancel_ref().is_cancelled():
                    _ = self.ctx_ref().error_slot_ref().try_set(
                        String("CancelledError: ")
                        + self.ctx_ref().cancel_ref().reason()
                    )
                    break
                try:
                    # THE REAL TRAIT DISPATCH: the SHARED Segment's
                    # execute[State] (reached through the bound concrete-origin
                    # ctx pointer) folds the [lo, hi) slice into the borrowed
                    # State.
                    self.ctx_ref().seg_ref().execute[Self.State](
                        self.ctx_ref().state_ref(), wid, tid,
                    )
                except e:
                    _ = self.ctx_ref().error_slot_ref().try_set(String(e))
                    break
                tid = tid + 1
        else:
            var n_all = self.n_all
            while True:
                # Claim FIRST, then check the abort conditions — an abort that
                # skipped the claim would leave the id unrun AND unclaimed,
                # which is indistinguishable from a lost task in the counters.
                var tid = self._cursor[].fetch_add(Int64(1))
                if tid >= n_all:
                    break
                if self.ctx_ref().error_slot_ref().is_set():
                    break
                if self.ctx_ref().cancel_ref().is_cancelled():
                    _ = self.ctx_ref().error_slot_ref().try_set(
                        String("CancelledError: ")
                        + self.ctx_ref().cancel_ref().reason()
                    )
                    break
                try:
                    self.ctx_ref().seg_ref().execute[Self.State](
                        self.ctx_ref().state_ref(), wid, tid,
                    )
                except e:
                    _ = self.ctx_ref().error_slot_ref().try_set(String(e))
                    break
        # --- ORDERING INVERSION ---
        #
        # The `in_flight` decrement is the RELEASE of this shard's borrow on the
        # caller's `ctx`. It MUST therefore be the LAST thing that touches the
        # ctx: the instant `fetch_sub` returns `prev == 1`, `in_flight` is zero,
        # the driver's barrier may break, and `run_with_state` may drop `ctx` and
        # POP ITS STACK FRAME. The pre-fix code performed THREE more
        # `self.ctx_ref()` loads after that point (`wake_word_ref()` twice plus
        # the `in_flight_ref()` receiver), i.e. it read — and, via `fetch_add`,
        # WROTE 4 bytes through — a pointer loaded out of a frame that could
        # already be gone.
        #
        # Fix: snapshot BOTH borrowed pointers into locals FIRST (POD copies,
        # concrete origins preserved), then decrement. Everything after the
        # decrement touches only the two dispatcher-owned HEAP atomics, whose
        # addresses are `OwnedPointer`-stable and outlive every worker. Zero ctx
        # dereferences after the release.
        var in_flight_p = self.ctx_ref().in_flight_ptr()
        var wake_word_p = self.ctx_ref().wake_word_ptr()
        var prev = in_flight_p[].fetch_sub(Int64(1))
        if prev == Int64(1):
            _ = wake_word_p[].fetch_add(Int32(1))
            _ = wake_one_by_address(wake_word_p[])

    def step(mut self) raises -> Int:
        """Result arm — not this payload's arm (it is a void-`run` shard), so it
        explicitly signals DONE. REQUIRED for the same `ErasableWork` dispatch
        reason as `run`."""
        return STEP_DONE


# =============================================================================
# NOTE — `_box_owned_into_bytes` is DELETED (the per-shard home).
# =============================================================================
#
# It existed to launder Mojo's aliasing analyzer: a `_DispatchShard` carrying
# concrete-origin pointer fields reads as "embedded references" aliasing the
# live `state` / atomics / cancel-token args, so an INLINE
# `init_pointee_move(shard)` into the slab was rejected. The helper took the
# shard as a SINGLE opaque owned `W` (origins hidden inside `W`, not separate
# tracked parameters), so the analyzer had no aliasing partner to relate.
#
# `make_erased[W](var work)` has the IDENTICAL single-opaque-`W` shape and the
# identical `alloc[W](1)` + `init_pointee_move` body — it just KEEPS the
# allocation as the handle's home instead of memcpy-ing out of it and freeing.
# So the enqueue loop now calls `make_erased[ShardT]` directly: same laundering
# property, same allocation count, one memcpy and one free fewer, and no pooled
# bytes shared across dispatch generations.

# =============================================================================
# OnPoolDispatchGuard — process-global "inside an executor-pool dispatch" bracket
# =============================================================================
#
# Increments a process-global atomic depth counter
# (`komira_on_pool_enter`/`komira_on_pool_exit` in komira_core) on
# construction and decrements it on destruction. Constructed as a local at the
# top of `run_with_state` so the WHOLE dispatch window (enqueue + worker drain +
# wake-word barrier) is bracketed; the RAII destructor fires on EVERY exit path
# (success return, or any of the raise paths) — exception-safe by construction.
#
# Why: a stdlib `parallelize` fired from inside a `run_with_state` worker (e.g.
# `SortSink.combine_partition`'s per-partition gather under
# a parallel sort gather) nests under the LIVE pthread pool and
# LIVELOCKS the dispatcher. The gather's parallel decision
# (`compiler_helpers._on_pool_dispatch_active`) reads this depth and stays
# SERIAL when it is > 0. The per-partition gather already runs ~1/N of the data
# on N pool workers in parallel, so suppressing the inner parallelize loses no
# parallelism; the off-pool `finalize` gather (depth back to 0) still goes
# parallel. This ALSO closes the latent INT/FLOAT combine_partition livelock in
# one place, since it brackets EVERY dispatch.
#
# Pointer discipline: holds no pointer/heap — a zero-field POD guard whose only
# state lives process-global in the C shim. trivially safe across destroy-recreate.
struct _OnPoolDispatchGuard(Deinitable):
    var _active: Bool

    @always_inline
    def __init__(out self):
        _ = external_call["komira_on_pool_enter", Int64]()
        self._active = True

    @always_inline
    def __deinit__(deinit self):
        if self._active:
            _ = external_call["komira_on_pool_exit", Int64]()

    @always_inline
    def keepalive(self):
        # Method-based keepalive (the pointer rules: `_ = guard` is reorderable). A
        # method call on `self` holds the guard live up to this point, so ASAP
        # destruction cannot decrement the depth before the worker barrier the
        # caller touches this AFTER. Observable (reads `_active`) so it is not
        # elided.
        if not self._active:
            # Unreachable on the live path (the guard is always active until
            # drop); the branch makes the keepalive observable.
            _ = external_call["komira_on_pool_depth", Int64]()


# =============================================================================
# LocalDispatcher[S]
# =============================================================================


struct LocalDispatcher[
    S: WakerSink & Movable & Deinitable,
](ParallelDispatch, Movable, Deinitable):
    """trait-surface façade for the
    engine's `run_with_state` dispatch shape.

    The fork-join body is the
    per-worker MPSC enqueue + worker_main drain shape from impl plan
    Each call to `run_with_state` publishes one `_TaskEntry` per
    worker shard onto each worker's queue (the worker drains via
    `Worker.run_one_iteration`); the driver waits on the per-dispatch
    wake-word until in-flight reaches zero.

    Field set:
      var _in_dispatch: OwnedPointer[Atomic[DType.int32]]   # re-entrance CAS
      var _in_flight:   OwnedPointer[Atomic[DType.int64]]   # work counter
      var _wake_word:   OwnedPointer[Atomic[DType.int32]]   # completion signal
      var _seg_buf:     Slab[UInt8]                          # shared Segment
      var _worker_senders: List[MpscSender[_TaskEntry]]      # one per worker

    The dispatcher REQUIRES at least one worker to be attached + started;
    `run_with_state` raises if `_worker_senders` is empty.
    """

    var _in_dispatch: OwnedPointer[AtomicI32]
    var _in_flight: OwnedPointer[AtomicI64]
    var _wake_word: OwnedPointer[AtomicI32]
    # monotonic dispatch generation.
    # Bumped at `run_with_state` entry AND at the end of
    # `_drain_in_flight_barrier`, so its value equals a shard's stamp EXACTLY
    # while the dispatch that stamped that shard is still inside its barrier —
    # i.e. exactly while that shard's `_ctx` stack pointer is still alive. Every
    # posted `_DispatchShard` carries the stamp + a pointer to THIS cell and
    # refuses to run when they disagree. Heap-stable (`OwnedPointer`) so the
    # address is identical for every generation and safe to read out of a stale
    # pool slot. See `_DispatchShard._gen_cell`.
    var _dispatch_gen: OwnedPointer[AtomicI64]
    # --- Barrier-violation diagnostics ---
    #
    # These were ONE conflated counter (`_barrier_violations`) until a hang core
    # showed the value `1` and it could not be attributed: "a stale shard
    # refused" and "a previous dispatch left a charge behind" are DIFFERENT
    # defects with opposite signatures, and the sum tells you neither. Split.
    #
    # (1) stale-shard refusals: a posted `_DispatchShard` whose generation stamp
    #     no longer matched the dispatcher's counter and therefore returned
    #     without touching `_ctx` (and, deliberately, without decrementing).
    var _viol_stale_shard: OwnedPointer[AtomicI64]
    # (2) entry leftovers: a `run_with_state` entry that found `_in_flight != 0`
    #     from a previous dispatch — i.e. the previous barrier's zero-predicate
    #     was not a proof. (The entry `store(1)` erases the evidence, which is
    #     exactly why this leak stayed invisible; count it first.)
    var _viol_entry_leftover: OwnedPointer[AtomicI64]
    # (3) PER-DISPATCH BITMASKS of wids: DELIVERED (the shard reached `run()`)
    #     and ENTERED (it passed the generation guard and ran its body). Zeroed
    #     at `run_with_state` entry. See the `_DispatchShard.run` marks for the
    #     3-way attribution this enables in a stuck barrier; masks (rather than
    #     counts) let the stall dump NAME the wid that went missing.
    #     TWO SEPARATE WORD ARRAYS, not two halves of one Int64 — see
    #     `_ShardMarkTable` for what the shared cell cost above 32 workers.
    var _shard_marks: OwnedPointer[_ShardMarkTable]
    # (4) Packed detail of the most recent refusal (observed gen / stamped gen /
    #     wid). Written only on the refusal path. Without it the counts cannot
    #     separate "the guard refused a LIVE shard of this dispatch" from "the
    #     guard correctly refused a stale handle and a different shard was never
    #     delivered" — opposite bugs with identical counters.
    var _refusal_detail: OwnedPointer[AtomicI64]
    # FORK-JOIN CLAIMING: the shared task cursor every shard of the
    # CURRENT dispatch claims from. ONE cell is enough because `run_with_state`
    # is a fork-join barrier serialised by the `_in_dispatch` re-entrance CAS —
    # there is never more than one live dispatch per dispatcher — and the cell
    # is reset to 0 inside that CAS, before any shard is posted. `OwnedPointer`
    # so the address is stable while workers race `fetch_add` on it (the same
    # shape as `_in_flight`); it is NOT on the driver frame, so a refused stale
    # shard that reads it reads a live dispatcher-owned cell.
    var _task_cursor: OwnedPointer[AtomicI64]
    var _seg_buf: Slab[UInt8]
    # MpscSender is Movable but not Copyable, so a `List[MpscSender]`
    # rejects the trait bound. Wrap each sender in an OwnedPointer
    # (POD 8-byte handle) and store in a Slab — safe across destroy-recreate shape.
    var _worker_senders: Slab[OwnedPointer[MpscSender[ErasedHandle]]]
    # Per-worker wake handles (eventfd spin-park) populated at
    # attach time alongside the sender slab. WorkerWakeHandle is POD
    # (Int32+UInt64); Slab[WorkerWakeHandle] is safe across destroy-recreate directly
    # (no OwnedPointer wrap needed). Index matches _worker_senders.
    var _worker_wake_handles: Slab[WorkerWakeHandle]
    # The IO-lane senders (compute/IO hyperthread split),
    # registered SEPARATELY from
    # `_worker_senders` so the firewall holds: `worker_count()` /
    # `run_with_state` shard ONLY across `_worker_senders` (the compute lane);
    # `_io_senders` is reached ONLY by the `make_spill_prefetcher` factory (which
    # clones them into a `SpillPrefetcher` — the fire-and-forget prefetch poster)
    # (design — the load-bearing 4-path-independence + barrier-
    # accounting invariant). EMPTY on the default / flag-off / non-SMT path ->
    # `io_lane_active()` False -> the producer no-ops -> byte-identical to today.
    var _io_senders: Slab[OwnedPointer[MpscSender[ErasedHandle]]]
    # The DELIVERY half of the IO lane, index-parallel to
    # `_io_senders`. Same POD `Slab[WorkerWakeHandle]` shape as
    # `_worker_wake_handles`. Required, not optional: the worker park is
    # INDEFINITE (`PARK_TIMEOUT_US = -1`) and `MpscSender.try_send*` signals
    # nothing, so a post without a wake is not observed until shutdown. EMPTY on
    # the default / flag-off / non-SMT path.
    var _io_wake_handles: Slab[WorkerWakeHandle]
    # Round-robin cursor for `post_to_io_lane`. Plain Int, no atomic: the IO-lane
    # post path is single-driver-threaded (same contract as
    # `SpillPrefetcher._rr`), and the re-entrance CAS keeps two threads out of
    # the dispatcher.
    var _io_rr: Int
    # NOTE: the `_shard_buf` byte-slab
    # pool that used to be declared here is DELETED. introduced
    # it to avoid a per-shard alloc, but it recycled slot `wid` across every
    # dispatch, and that reuse WAS the UAF: a worker's compiler-emitted
    # store-back of its `mut self` aggregate could land after the barrier
    # released, reverting the slot to the previous generation's shard. Each
    # shard now owns its home via `make_erased` (see the enqueue loop). The
    # "zero alloc" this pool bought was fiction anyway — the laundering helper
    # it fed allocated and freed per shard regardless.
    # SCHED-TRACE: the scheduler-trace enabled flag, cached ONCE at
    # construction. The run_with_state fork/enqueue brackets
    # gate on this cold Bool field — ZERO external_call on the OFF hot path.
    var _sched_on: Bool
    # Fork-join task claiming, a plain field read on every dispatch. DEFAULT-ON;
    # `set_claim_enabled(False)` restores the static contiguous split.
    var _claim_on: Bool

    def __init__(out self):
        """Construct a LocalDispatcher with all atomics zero-initialized
        and an empty sender list. Senders are populated by
        PerCoreAsyncRuntime.attach_worker[s] via
        `_register_worker_handle`.
        """
        var in_dispatch_raw = alloc[AtomicI32](1)
        # SAFETY: in_dispatch_raw is a fresh allocation we own. Initialize
        # via direct field-style assignment (the Atomic ctor accepts a
        # Scalar value); ownership transfers to OwnedPointer; __del__ frees.
        in_dispatch_raw[] = AtomicI32(Int32(0))
        self._in_dispatch = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=in_dispatch_raw,
        )

        var in_flight_raw = alloc[AtomicI64](1)
        # SAFETY: as above.
        in_flight_raw[] = AtomicI64(Int64(0))
        self._in_flight = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=in_flight_raw,
        )

        var wake_word_raw = alloc[AtomicI32](1)
        # SAFETY: as above.
        wake_word_raw[] = AtomicI32(Int32(0))
        self._wake_word = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=wake_word_raw,
        )

        # generation counter + violation counter.
        # Both heap-stable so a shard can read them out of a recycled pool slot.
        var gen_raw = alloc[AtomicI64](1)
        # SAFETY: as above.
        gen_raw[] = AtomicI64(Int64(0))
        self._dispatch_gen = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=gen_raw,
        )

        var viol_raw = alloc[AtomicI64](1)
        # SAFETY: as above.
        viol_raw[] = AtomicI64(Int64(0))
        self._viol_stale_shard = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=viol_raw,
        )

        var leftover_raw = alloc[AtomicI64](1)
        # SAFETY: as above.
        leftover_raw[] = AtomicI64(Int64(0))
        self._viol_entry_leftover = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=leftover_raw,
        )

        var marks_raw = alloc[_ShardMarkTable](1)
        # SAFETY: as above. `_ShardMarkTable.__init__` zeroes both mask word
        # arrays + the overflow counter; ownership transfers to OwnedPointer, so
        # the table's address is stable for the dispatcher's whole life (which
        # is what lets a shard mark through it out of a recycled pool slot).
        marks_raw[] = _ShardMarkTable()
        self._shard_marks = OwnedPointer[_ShardMarkTable](
            unsafe_from_raw_pointer=marks_raw,
        )

        var detail_raw = alloc[AtomicI64](1)
        # SAFETY: as above.
        detail_raw[] = AtomicI64(Int64(-1))
        self._refusal_detail = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=detail_raw,
        )

        # FORK-JOIN CLAIMING: the shared per-dispatch task cursor, heap-stable.
        var cursor_raw = alloc[AtomicI64](1)
        # SAFETY: as above.
        cursor_raw[] = AtomicI64(Int64(0))
        self._task_cursor = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=cursor_raw,
        )

        self._seg_buf = Slab[UInt8]()
        self._worker_senders = Slab[OwnedPointer[MpscSender[ErasedHandle]]]()
        self._worker_wake_handles = Slab[WorkerWakeHandle]()
        # IO lane: IO-lane sender slab. Empty at ctor; populated by
        # `_register_io_worker_handle` ONLY when the runtime attaches an IO lane
        # (flag ON + SMT host). Stays empty on the default path (firewall: the
        # compute shard set in `_worker_senders` is unaffected).
        self._io_senders = Slab[OwnedPointer[MpscSender[ErasedHandle]]]()
        # Index-parallel to `_io_senders`: IO worker k's wake handle. Empty on
        # the default path (no IO lane). See `_register_io_worker_handle` — this
        # is the DELIVERY half of the lane; without it a parked IO worker never
        # observes a post.
        self._io_wake_handles = Slab[WorkerWakeHandle]()
        self._io_rr = 0
        # SCHED-TRACE: cache the env-gated trace flag once.
        self._sched_on = sched_trace_enabled()
        # Fork-join task claiming is ON by default; the owning runtime may
        # select the static split with `set_claim_enabled(False)` before it
        # dispatches.
        self._claim_on = True

    def _register_worker_handle(
        mut self,
        var sender: MpscSender[ErasedHandle],
        var wake_handle: WorkerWakeHandle,
    ):
        """Step 5 — 2-arg form. Called by PerCoreAsyncRuntime
        attach_worker[s] to seed one MpscSender clone + one
        WorkerWakeHandle per attached worker. The sender is the producer
        end of the matching MPSC channel whose receiver lives inside the
        worker's `_task_queue` field; the wake handle is the producer's
        own clone (refcount-bumped at the call site via
        WorkerWakeHandle.copy()) carrying its own ArcPointer<_SleepingFlag>
        clone for typed wake elision per

        The order of registration MUST match the worker order in
        PerCoreAsyncRuntime._workers, since the dispatcher's enqueue
        path uses the index to route shards to workers.

        `wake_handle` is `var`
        (consumed) — the caller produces a per-producer clone via
        `WorkerWakeHandle.copy()` and transfers ownership here. The
        previous borrow-then-implicit-copy shape relied on
        ImplicitlyCopyable; the typed ArcPointer field needs explicit
        clone semantics to make the refcount-bump visible at the
        boundary.
        """
        var owned = OwnedPointer[MpscSender[ErasedHandle]](value=sender^)
        self._worker_senders.append(owned^)
        self._worker_wake_handles.append(wake_handle^)

    def _register_io_worker_handle(
        mut self,
        var sender: MpscSender[ErasedHandle],
        var wake_handle: WorkerWakeHandle,
    ):
        """IO-lane prefetch-offload — register ONE IO-lane sender + its
        wake handle.

        Called by `PerCoreAsyncRuntime.attach_io_workers` for each IO worker
        AFTER the compute lane is registered. The sender is a clone of the IO
        worker's MPSC producer end; the matching receiver lives inside the IO
        worker's `_task_queue` (the IO worker drains it on its own pthread and
        runs each posted `ErasedHandle` BLIND via `drain_task_queue`).

        FIREWALL (the load-bearing invariant): the IO sender goes into
        `_io_senders`, NEVER `_worker_senders`. So `worker_count()` and the
        `run_with_state` fork-join shard set stay COMPUTE-only — an IO worker is
        never handed a compute shard. The IO lane is reached ONLY by the
        fire-and-forget post path (`SpillPrefetcher.prefetch_chunk`).

        ★ THE WAKE HANDLE IS NEW AND IT IS THE FIX FOR A DEAD LANE.
        The prior comment here said "No wake-handle is registered: the IO
        worker's own park/poll loop drains the queue". That was WRONG in a way
        that made the entire lane inert: the park is
        `poll_completions(PARK_TIMEOUT_US)` with `PARK_TIMEOUT_US = -1`
        (INDEFINITE), and `MpscSender.try_send*` issues no signal, so an IO
        worker that had parked never observed a post until `shutdown()`'s final
        drain. The producer still never WAITS on the IO lane (the offload stays
        fire-and-forget, so the barrier accounting and the `state` lifetime
        are untouched) — it only SIGNALS it, exactly as the compute-lane enqueue
        loop has always done via `_worker_wake_handles[wid].wake_with_elision()`.
        Same handle API, unmodified; no change to spin limits, park timeouts, or
        the eventfd protocol.
        """
        var owned = OwnedPointer[MpscSender[ErasedHandle]](value=sender^)
        self._io_senders.append(owned^)
        self._io_wake_handles.append(wake_handle^)

    @always_inline
    def io_lane_active(self) -> Bool:
        """True iff an IO lane is registered (IO lane attached + SMT host).

        The prefetch producer gates on this: False -> no IO workers -> the
        producer no-ops and the blocking read runs inline on the compute thread
        (today's behavior). Default / flag-off / non-SMT path returns False
        (the `_io_senders` slab is empty), so the producer is byte-identical to
        today whenever the IO lane was not actually created.
        """
        return self._io_senders.len() > 0

    def io_lane_count(self) -> Int:
        """number of IO-lane senders the dispatcher can post to.

        Distinct from `worker_count()` (the compute / fork-join shard count).
        Used by the producer's round-robin spread + by tests asserting the
        firewall (compute `worker_count()` unchanged by IO-lane registration).
        """
        return self._io_senders.len()

    def post_to_io_lane[W: ErasableWork](mut self, var work: W) -> Bool:
        """POST one fire-and-forget `ErasableWork` to the IO lane (round-robin),
        and SIGNAL the target IO worker.

        THE canonical IO-lane submit path. `SpillPrefetcher.prefetch_chunk` is
        the spill-shaped convenience wrapper over the same contract; this is the
        general form, so a new IO consumer does not need its own poster type.

        Returns True iff an IO worker accepted the work; False iff there is no IO
        lane (flag OFF / non-SMT / `IO_PLACEMENT_INLINE`) OR every IO queue was
        full. A False is ALWAYS benign for the caller in the sense that nothing
        was silently swallowed — the work is dropped and destroyed here, and the
        caller is expected to have an INLINE fallback for the operation. That
        "always have an inline fallback" requirement is what makes the whole lane
        default-OFF-safe.

        ── WHAT MAY BE POSTED (a real contract, not a style note) ──────────────
        1. SELF-CONTAINED. The work crosses an MPSC into another thread with NO
           compiler-tracked origin, so it must OWN everything it touches (its own
           `String` path copy, its own `ArcPointer` to any shared cell). It must
           NOT borrow the driver's state, a shared mutable buffer, or anything
           whose lifetime the fork-join barrier governs — that is what keeps this
           post OUTSIDE the barrier accounting and the dispatch `state`
           lifetime.
        2. GENUINELY BLOCKING, NOT POLLING. The IO lane's cheapness rests on the
           placed CPU hosting a thread that is HALTED in a syscall. A POLLING
           payload (a spin on a Pending future, a `sched_yield` retry loop) is
           RUNNING, and on the SIBLING placement a running thread steals issue
           slots from its compute partner. Post `read`/`pread`/`fsync`/page-cache
           prefault; do NOT post a reactor spin.
        3. FIRE-AND-FORGET. There is no completion signal and no join. If the
           caller needs the result, it must not use this path.

        SHUTDOWN / NO-LOSS: work still sitting in an IO worker's queue when
        shutdown is signalled is NOT dropped — the worker's loop exits with a
        final unbounded `drain_task_queue`, and `PerCoreAsyncRuntime.shutdown()`
        JOINS the IO pthread, so every accepted post has run before the runtime
        drops. (That join-before-drop is the same ordering the log engine and the
        idle hook already rely on.)
        """
        var n_io = self._io_senders.len()
        if n_io == 0:
            return False
        var handle = make_erased[W](work^)
        var start = self._io_rr % n_io
        var cur = handle^
        var i = 0
        while i < n_io:
            var idx = (start + i) % n_io
            var outcome = self._io_senders[idx][].try_send_back(cur^)
            if outcome.status == TRY_SEND_OK:
                self._io_rr = (idx + 1) % n_io
                # SEND THEN WAKE — order is load-bearing (the reverse loses
                # wakeups). Without this wake the post is invisible to a parked
                # IO worker until shutdown: the park is `poll_completions(-1)`
                # (INDEFINITE) and `try_send_back` signals nothing.
                if idx < self._io_wake_handles.len():
                    _ = self._io_wake_handles[idx].wake_with_elision()
                return True
            cur = outcome.take_value()
            i += 1
        # Every IO queue full/closed — drop the work (its __del__ frees whatever
        # it owns). The caller's inline fallback covers correctness.
        _ = cur^
        return False

    def make_spill_prefetcher(self) -> SpillPrefetcher:
        """IO-lane prefetch-offload — build a `SpillPrefetcher` holding
        CLONES of this dispatcher's IO-lane senders.

        The spill driver calls this at finalize entry and threads the returned
        prefetcher (as an `Optional`) into the spill-restore merge loop so the
        loop can prefetch run i+1's chunk into page cache while folding run i
        (the prefetch offload). The prefetcher holds IO senders ONLY — never the
        compute senders — so the firewall holds (an IO worker is never handed a
        compute shard).

        On the default / flag-off / non-SMT path `_io_senders` is empty, so the
        returned prefetcher is EMPTY (`is_active()` False) and the spill producer
        no-ops -> byte-identical to today. Each clone is an Arc bump on the IO
        worker's MPSC `_MpscShared`; the prefetcher drops them at finalize end.

        The prefetcher gets the matching WAKE HANDLE clone per IO worker too
        — a sender clone alone posts into a queue whose consumer is
        parked indefinitely. See `_register_io_worker_handle`.
        """
        var pf = SpillPrefetcher()
        var n_io = self._io_senders.len()
        var i = 0
        while i < n_io:
            # Index-parallel append (sender + its wake handle in ONE call), so
            # the prefetcher cannot end up waking the wrong worker.
            pf.add_io_sender(
                self._io_senders[i][].clone(),
                self._io_wake_handles[i].copy(),
            )
            i += 1
        return pf^

    def in_flight_snapshot(self) -> Int64:
        """Diagnostic accessor — the current value of the per-dispatch in-flight
        charge counter. Returns a typed scalar (no pointer crosses the boundary).

        Dispatch use-after-free: this is the observable the regression
        guard asserts on. The barrier invariant is that `run_with_state` NEVER
        returns or raises with this != 0 — a non-zero value on exit means a live
        borrower still holds a `_DispatchCtx` pointer into the caller's stack
        frame that is about to be popped. See
        `tests/test_local_dispatcher_barrier_bypass.mojo`.
        """
        return self._in_flight[].load()

    def barrier_violations_snapshot(self) -> Int64:
        """Diagnostic accessor — number of BARRIER VIOLATIONS observed so far.

        The generation guard. Counts two events, both of which
        mean the same thing — a previous dispatch's `in_flight == 0` was NOT a
        proof that every borrow into its stack frame was dead:

          1. a `_DispatchShard` that reached `run()` with a generation stamp that
             no longer matches `_dispatch_gen` (it outlived its dispatch), and
          2. a `run_with_state` entry that found `_in_flight != 0` left over from
             the previous dispatch.

        MUST be 0 on any healthy workload. A non-zero value is the residual
        barrier leak; the stale-generation guard makes it non-fatal (the shard
        refuses instead of dereferencing a popped stack frame) but it is still a
        real defect and this counter is how it is attributed. Returns a typed
        scalar (no pointer crosses the boundary).

        this is now the SUM of the two split counters below. Prefer
        `stale_shard_refusals_snapshot()` / `entry_leftover_snapshot()` for any
        NEW assertion — the sum cannot attribute a hang, which is exactly what
        stalls a hang-core diagnosis.
        """
        return (
            self._viol_stale_shard[].load()
            + self._viol_entry_leftover[].load()
        )

    def stale_shard_refusals_snapshot(self) -> Int64:
        """Diagnostic accessor — how many `_DispatchShard.run()` calls refused on
        a generation mismatch (the fix-4 guard firing). Each one is a handle that
        outlived the dispatch that stamped it. Expected to stay 0 since the per-shard home."""
        return self._viol_stale_shard[].load()

    def entry_leftover_snapshot(self) -> Int64:
        """Diagnostic accessor — how many `run_with_state` entries found a
        non-zero `_in_flight` left behind by the PREVIOUS dispatch. Each one is a
        barrier that returned while a charge was still outstanding."""
        return self._viol_entry_leftover[].load()

    # --- Per-dispatch shard marks ---
    #
    # These replaced `shard_entered_mask_snapshot()`, which returned the ONE
    # Int64 that used to carry both masks 32/32 and therefore could not answer
    # the question above 32 workers at all. Ask per wid, or per word; there is
    # no single-number form because there is no single number.
    def shard_entered_bit(self, wid: Int) -> Bool:
        """Did `wid`'s shard pass the generation guard and enter its body in the
        CURRENT (or most recent) dispatch? Reset at each `run_with_state` entry,
        so together with the shard count and `in_flight_snapshot()` this both
        attributes a missing decrement AND names the wid it belongs to."""
        return self._shard_marks[].entered_bit(wid)

    def shard_delivered_bit(self, wid: Int) -> Bool:
        """Did `wid`'s shard reach `run()` at all? Marked BEFORE the generation
        guard, so DELIVERED-set + ENTERED-clear is "handed over then refused",
        while both clear is "never handed to its worker"."""
        return self._shard_marks[].delivered_bit(wid)

    def shard_entered_word(self, i: Int) -> Int64:
        """Raw ENTERED word `i` — wids `64*i .. 64*i+63`, LSB = the lowest."""
        return self._shard_marks[].entered_word(i)

    def shard_delivered_word(self, i: Int) -> Int64:
        """Raw DELIVERED word `i` — wids `64*i .. 64*i+63`, LSB = the lowest."""
        return self._shard_marks[].delivered_word(i)

    def shard_mark_overflow_snapshot(self) -> Int64:
        """Shard marks DROPPED for carrying a wid outside the mark table's
        range. Non-zero means the masks under-report — never that a valid wid's
        bit was corrupted, which is the property the old shared cell lacked."""
        return self._shard_marks[].overflow_marks()

    def shard_mark_capacity(self) -> Int:
        """Highest wid + 1 the mark table can record. Comfortably above any
        single-host `physical_core_count()`; see `_ShardMarkTable`."""
        return _ShardMarkTable.CAPACITY

    def last_refusal_detail_snapshot(self) -> Int64:
        """Diagnostic accessor — packed detail of the most recent stale-shard
        refusal: `(observed_gen << 40) | (stamped_gen << 16) | wid`. -1 if the
        generation guard has never fired."""
        return self._refusal_detail[].load()

    def dispatch_gen_snapshot(self) -> Int64:
        """Diagnostic accessor — current dispatch generation. Bumped once at
        `run_with_state` entry and once when `_drain_in_flight_barrier`
        completes, so it is ODD exactly while a dispatch window is open."""
        return self._dispatch_gen[].load()

    def worker_count(self) -> Int:
        """Diagnostic accessor — number of worker queues the dispatcher
        can target. Equal to the number of attached workers on the
        runtime that owns this dispatcher.
        """
        return self._worker_senders.len()

    def claim_enabled(self) -> Bool:
        """Whether fork-join dispatch claims task ids from a shared cursor
        (True, the default) or gives each worker a fixed range (False).

        Exists because the choice CANNOT CHANGE ANY ANSWER — both arms run every
        task exactly once and return identical values — so no value oracle can
        see which arm is live. This is the structural observable that makes the
        setting testable.
        """
        return self._claim_on

    def set_claim_enabled(mut self, on: Bool):
        """Select claiming (True) or the static contiguous split (False) for
        every later fork-join dispatch. Set it before dispatching; it is a
        configuration value, not something to flip mid-run."""
        self._claim_on = on

    def task_cursor_value(self) -> Int64:
        """The shared claim cursor AFTER the last dispatch — a CONSERVATION
        witness, not a diagnostic. Under fork-join claiming a completed dispatch of `n`
        tasks over `w` workers leaves it at exactly `n + w` (every worker
        claims once past the end before it exits), so a value below that means
        a worker exited without proving the queue was empty, and a value above
        it means a shard claimed after its barrier release. Under the OFF arm
        it stays 0."""
        return self._task_cursor[].load()

    @always_inline
    def _release_in_dispatch(mut self):
        """Release the re-entrance CAS guard. Called on EVERY exit path
        from `run_with_state`."""
        AtomicI32.store(
            UnsafePointer(to=self._in_dispatch[]).unsafe_bitcast[Scalar[DType.int32]](), Int32(0),
        )

    def _drain_in_flight_barrier(
        mut self,
        refusals_base: Int64 = Int64(0),
        n_posted: Int64 = Int64(-1),
        n_diag: Int = 0,
        nw_diag: Int = 0,
    ) -> Int64:
        """Release the DRIVER's own in-flight charge, then block until every
        shard charge acquired during this dispatch has been released.

        `n_posted` is diagnostic only — the number of shard charges acquired by
        the caller so far, used by the stall dump below to say whether a posted
        shard never reached its body. Defaults to -1 ("unknown").

        THE barrier. On return,
        `_in_flight == 0`, which under the acquired-charge discipline means:
        every `ErasedHandle` that actually entered a worker queue for this
        dispatch has finished its `run()` AND performed its last dereference of
        the caller's `_DispatchCtx` (the ordering-inversion fix in
        `_DispatchShard.run` guarantees the decrement is the shard's final ctx
        touch). ONLY after this returns may the caller drop `ctx`, take `seg`
        back, or unwind its frame.

        This is called on EVERY exit path that reached the enqueue loop —
        including the two error unwinds (receiver CLOSED, persistently FULL).
        Pre-fix those two raised immediately with shards still running, popping
        the frame that owned `ctx` + `error_slot` underneath live borrowers; that
        is a use-after-free of the driver's stack frame, not a clean error.

        Drep lost-wakeup-safe: snapshot the wake word, re-check the
        counter, then park. A spurious wake simply re-loops. `Atomic.load`
        defaults to sequentially-consistent ordering, so the load is an acquire
        with respect to the shards' releasing `fetch_sub`.
        """
        _ = self._in_flight[].fetch_sub(Int64(1))
        # STALL DUMP. A stuck barrier is fail-stop and undebuggable
        # from outside the process: the driver blocks forever, no counter is ever
        # printed, and `yama/ptrace_scope` blocks a gdb attach on this box, so the
        # ONLY way to attribute it has been to SIGABRT the process and read a
        # core. Print the attribution ONCE from inside the wait instead. The
        # threshold is far outside any legitimate dispatch (a whole soak
        # invocation is ~5 s), the print costs nothing on the healthy path (one
        # Int compare per 1 ms wait), and by the time it fires the query is
        # already lost — so there is no reason to keep the evidence hidden.
        var waits: Int64 = 0
        var dumped = False
        # --- THE STRANDED CHARGE ---
        #
        # A shard that takes the generation guard's stale-generation guard returns WITHOUT
        # decrementing, deliberately (that counter may belong to another
        # dispatch, and an extra decrement there is what cascades one leaked
        # handle into many). So each refusal permanently removes one decrement
        # from this dispatch — and waiting for literal zero is then waiting for
        # an event that can never happen. That is the whole HANG: `in_flight=1`,
        # `stale_refusals=1`, every worker queue empty, forever.
        #
        # The barrier's real predicate was never "the counter is zero", it is
        # "no shard can still dereference my `ctx`". A refused shard cannot: the
        # guard runs BEFORE the first `ctx_ref()` and returns having touched only
        # dispatcher-owned heap cells (`_viol_cell`, `_detail_cell`,
        # `_shard_marks`), whose addresses are `OwnedPointer`-stable and outlive
        # every worker. So the correct predicate is
        #
        #     in_flight <= (refusals raised since this dispatch began)
        #
        # which is exactly the old one whenever nothing is refused, and is
        # reachable when something is.
        #
        # `<=` and not `==`: a refusal whose charge belongs to an ALREADY-CLOSED
        # dispatch adds to the refusal count without a matching charge here, and
        # `==` would then spin forever — the same failure this fix exists to
        # remove. `<=` degrades to "return promptly" instead.
        #
        # This is driver-side ONLY, on purpose. `_DispatchShard.run`'s codegen is
        # part of the race (a probe inside it suppressed the defect 0/52 vs 6/12
        # — see the note on the guard), so the barrier must be repaired without
        # touching the consumer.
        #
        # The refusal is a FAIL-STOP conversion, not a correctness fix: the
        # refused shard's task range NEVER RAN, and `run_with_state` raises on a
        # non-zero return so the work loss is loud instead of silent. The
        # underlying leak was removed separately — a worker writing the previous
        # generation's shard struct BACK into the pooled `_shard_buf` slot after
        # releasing the barrier — by deleting the pool: each shard now owns its
        # home, so there are no cross-generation bytes to revert. This predicate
        # is RETAINED as the belt-and-braces detector; it should now never fire.
        var stranded = self._viol_stale_shard[].load() - refusals_base
        if stranded < Int64(0):
            stranded = Int64(0)
        while self._in_flight[].load() > stranded:
            var snapshot = self._wake_word[].load()
            stranded = self._viol_stale_shard[].load() - refusals_base
            if stranded < Int64(0):
                stranded = Int64(0)
            if self._in_flight[].load() <= stranded:
                break
            _ = wait_on_address(
                self._wake_word[], snapshot,
                timeout_ns=Int64(1_000_000),  # 1ms
            )
            waits += Int64(1)
            if waits >= Int64(10_000) and not dumped:  # ~10 s of 1 ms waits
                dumped = True
                var detail = self._refusal_detail[].load()
                var nw = self._worker_senders.len()
                # `entered_mask` / `delivered_mask` are wids 0..63 — one WORD of
                # each mask, never two halves of one cell.
                # Higher wids get their own lines below rather
                # than folding onto these.
                print(
                    "[BARRIER-STALL] LocalDispatcher._drain_in_flight_barrier"
                    " stuck >10s:",
                    "in_flight=", self._in_flight[].load(),
                    "posted=", n_posted,
                    # UNSIGNED: a word whose wid-63 bit is set is a NEGATIVE
                    # Int64, and a full 64-wid band would print as `-1` — the
                    # healthiest possible mask wearing the scariest number.
                    "entered_mask=",
                    self._shard_marks[].entered_word(0).cast[DType.uint64](),
                    "delivered_mask=",
                    self._shard_marks[].delivered_word(0).cast[DType.uint64](),
                    "gen=", self._dispatch_gen[].load(),
                    "stale_refusals=", self._viol_stale_shard[].load(),
                    "entry_leftovers=", self._viol_entry_leftover[].load(),
                    "workers=", nw,
                    "mark_overflow=", self._shard_marks[].overflow_marks(),
                    "| last_refusal wid=", detail & Int64(0xFFFF),
                    "stamped_gen=", (detail >> 16) & Int64(0xFFFFFF),
                    "observed_gen=", (detail >> 40) & Int64(0xFFFFFF),
                file=_STDERR,
                )
                # WIDE HOSTS. Server hosts commonly exceed 64 cores, so wids
                # 64+ are an ordinary case, not an exotic one. One line per additional 64-wid band, printed only
                # when the worker set actually reaches it.
                var mw = 1
                while mw * 64 < nw and mw < _ShardMarkTable.WORDS:
                    print(
                        "[BARRIER-STALL]   wids", mw * 64, "..", mw * 64 + 63,
                        "entered_mask=",
                        self._shard_marks[].entered_word(mw).cast[
                            DType.uint64
                        ](),
                        "delivered_mask=",
                        self._shard_marks[].delivered_word(mw).cast[
                            DType.uint64
                        ](),
                    file=_STDERR,
                    )
                    mw += 1
                # NAME the wids, which is the whole reason these are masks and
                # not counts — and which the shared cell made impossible above
                # 32 workers. The two buckets are the two distinct diagnoses:
                #   never_delivered            -> the handle never reached
                #                                 `run()` (never drained, or
                #                                 posted to nobody)
                #   delivered_but_never_entered-> it reached `run()` and the
                #                                 generation guard refused it
                var never_delivered = String("")
                var delivered_not_entered = String("")
                var mi = 0
                while mi < nw:
                    if not self._shard_marks[].delivered_bit(mi):
                        never_delivered += String(mi) + " "
                    elif not self._shard_marks[].entered_bit(mi):
                        delivered_not_entered += String(mi) + " "
                    mi += 1
                print(
                    "[BARRIER-STALL]   never_delivered=[", never_delivered,
                    "] delivered_but_never_entered=[", delivered_not_entered,
                    "]",
                file=_STDERR,
                )
                # The SLAB READ-BACK that used to live here is GONE with the
                # slab (the per-shard home): there is no pooled `_shard_buf` to read back,
                # because each shard now owns its home. It did its job — it is
                # what proved the refusing slot held a complete, self-consistent
                # shard from `observed_gen - 2`, which is what identified the
                # cross-generation reuse as the defect.
                #
                # `expect_lo`/`expect_hi` are retained: on any FUTURE refusal
                # they still say which dispatch shape the refusing wid belonged
                # to, and they need no shared bytes to compute.
                var rwid = Int(detail & Int64(0xFFFF))
                print(
                    "[BARRIER-STALL]   refusing_wid=", rwid,
                    " n=", n_diag,
                    " n_workers=", nw_diag,
                    " expect_lo=",
                    (rwid * n_diag) // nw_diag if nw_diag > 0 else -1,
                    " expect_hi=",
                    ((rwid + 1) * n_diag) // nw_diag if nw_diag > 0 else -1,
                file=_STDERR,
                )
                # entered < posted  -> a posted shard never reached run():
                #                      never drained (delivery) if
                #                      stale_refusals did not move, refused
                #                      (generation) if it did.
                # entered == posted -> a shard ran its body and never came back
                #                      to its fetch_sub.
                #
                # Per-worker queue depth is the last discriminator: a wid whose
                # bit is clear in `entered_mask` AND whose queue still holds an
                # entry means the handle IS there and the consumer stopped
                # draining; depth 0 means the handle was consumed (and refused)
                # and no replacement was ever posted.
                var qi = 0
                while qi < self._worker_senders.len():
                    var depth = self._worker_senders[qi][].approx_depth()
                    if depth != Int64(0):
                        print(
                            "[BARRIER-STALL]   worker", qi,
                            "queue_depth=", depth,
                        file=_STDERR,
                        )
                    qi += 1
        # CLOSE THE GENERATION.
        # From this instant the caller is free to drop `ctx` and unwind, so every
        # shard stamped with the current generation must stop being allowed to
        # dereference `_ctx`. Bumping here — inside the ONE barrier function all
        # three exit paths share — is what makes the stamp check in
        # `_DispatchShard.run` mean exactly "the ctx I point at is still alive"
        # rather than the weaker "some dispatch is running". Must stay the LAST
        # statement of the barrier.
        #
        # the stranded-charge settlement: settle the stranded charges FIRST. Every refused shard left one
        # charge on `_in_flight` that nobody will ever release; if we leave it
        # there the NEXT dispatch's entry sees a non-zero counter, mis-reports it
        # as an `entry_leftover` (a DIFFERENT defect) and then erases it with the
        # entry `store(1)` anyway. Settling here keeps the counter honest and
        # keeps `entry_leftover` meaning what it says. Safe at this point: the
        # loop above already proved every shard — refused or not — is done
        # touching this dispatch.
        stranded = self._viol_stale_shard[].load() - refusals_base
        if stranded < Int64(0):
            stranded = Int64(0)
        if stranded > Int64(0):
            _ = self._in_flight[].fetch_sub(stranded)
        _ = self._dispatch_gen[].fetch_add(Int64(1))
        return stranded

    def run_with_state[
        State: KeepAlive, T: Segment,
    ](
        mut self,
        mut state: State,
        var seg: T,
        n: Int,
        var cancel_token: CancellationToken,
        site_id: UInt32 = UInt32(0),
    ) raises -> T:
        """Dispatch `n` copies of
        `seg.execute[State](state, wid, task_id)` across the runtime's
        worker pool via per-worker MPSC enqueue.

        The `cancel_token`
        parameter gives for first-error-wins cancellation. Callers thread
        `session.shutdown_token()` for SDK ctrl-C semantics, or
        `CancellationToken.never()^` for non-cancellable dispatch.
        The trampoline polls `cancel_token.is_cancelled()` BETWEEN tids
        on every worker; the first worker to observe cancellation (or
        an execute() error) wins the CAS and writes the message; the
        driver raises after the wake-word barrier returns.

        Public surface contract:
          - `state` is BORROWED for the dispatch window. Caller retains
            ownership; the wake-word barrier guarantees every worker has
            finished its shard before this method returns, so workers
            cannot dereference state after the caller's `state` could
            go out of scope.
          - `seg` is MOVED into the dispatcher's `_seg_buf` for the
            duration. On return (success or Error) the caller regains
            ownership.
          - `n` is the number of task instances (task_ids in [0, n)).
            n=0 short-circuits with no enqueue.
          - `cancel_token` is MOVED for the dispatch window. Cancellation
            is observed BETWEEN tids on every worker; in-flight
            execute() calls are NOT interrupted (cooperative model).
          - Raises:
              * "LocalDispatcher.run_with_state: nested dispatch detected"
                if a worker re-entered or two driver threads called
                concurrently (re-entrance CAS).
              * "LocalDispatcher.run_with_state: negative n" for n<0.
              * "LocalDispatcher.run_with_state: no workers attached"
                if no workers have been registered with the dispatcher
                (call PerCoreAsyncRuntime.attach_worker[s] first).
              * "LocalDispatcher.run_with_state: <worker error>" if any
                shard's trampoline raised.

        Algorithm:
          1. Re-entrance CAS on _in_dispatch (0 → 1). If False, raise.
          2. Validation: n < 0 → raise (release CAS first); no workers
             → raise (release CAS first).
          3. n == 0 short-circuit (release CAS first; return seg^).
          4. Move `seg` into _seg_buf bytes via init_pointee_move.
          5. Choose n_workers = min(worker_count, n).
          6. Initialize _in_flight = n_workers, _wake_word = 0.
          7. For each shard wid in [0, n_workers): allocate a fresh
             _DispatchShard[State, T] descriptor on the heap; build a
             _TaskEntry pointing at it; try_send to worker[wid]'s MPSC
             queue. Retry on TRY_SEND_FULL with cpu_pause.
          8. Wait on _wake_word until _in_flight == 0.
          9. Dual keepalive on State + Segment.
         10. Destructure _seg_buf: take_pointee on the inner Segment.
         11. Release CAS BEFORE possibly raising.
         12. Return seg^ on success, or raise the worker's first Error.
        """
        # --- Re-entrance CAS ---
        var expected = Int32(0)
        var acquired = self._in_dispatch[].compare_exchange(
            expected, Int32(1)
        )
        if not acquired:
            _ = seg^
            _ = cancel_token^
            raise Error(
                "LocalDispatcher.run_with_state: nested dispatch detected."
                " Workers processing a Segment must not call"
                " run_with_state, and two threads must not drive the"
                " same dispatcher concurrently. Restructure into driver-"
                "coordinated phases (nested dispatch is not supported)."
            )

        # ---: bracket the whole dispatch window as "on the pool"
        # so a `gather_batch` reached from any worker (combine_partition's
        # per-partition sort, a scan-phase filter) suppresses its inner parallel
        # gather (nested stdlib parallelize under THIS live pool = livelock). The
        # RAII destructor decrements on EVERY exit path below (success + all
        # raises), so the bracket is exception-safe. Placed AFTER the re-entrance
        # CAS (so the nested-dispatch raise above does NOT touch the depth) and
        # BEFORE any worker dispatch, spanning the wake-word barrier wait.
        var _on_pool_guard = _OnPoolDispatchGuard()

        # SCHED-TRACE: bracket the fork->barrier span (bucket a
        # driver-view cross-check) + the enqueue-loop dispatch wall (bucket c).
        # Gated on the cached `_sched_on` field — ZERO external_call on the OFF
        # hot path (only perf_counter_ns behind the branch). Placed AFTER the
        # re-entrance CAS so a nested-dispatch raise never records a span.
        var sched_on = self._sched_on
        var fork_start_ns: UInt64 = UInt64(0)
        # IN-BAND OCCUPANCY. Snapshot total worker-busy ns here and
        # again at the barrier; the delta over the fork's wall is the average
        # number of workers concurrently busy, and dividing by n_workers gives
        # the fraction of the posted fan that was actually used. This is the
        # per-site figure a hand-derived count would otherwise give, now free on every
        # fork with no per-cell code. One 512-slot sum on the trace-on path only.
        var busy_at_fork_ns: UInt64 = UInt64(0)
        if sched_on:
            busy_at_fork_ns = sched_trace_worker_busy_total()
            fork_start_ns = UInt64(perf_counter_ns())

        # --- Validation + short-circuits (release guard BEFORE raising) ---
        if n < 0:
            _ = seg^
            _ = cancel_token^
            self._release_in_dispatch()
            raise Error(
                "LocalDispatcher.run_with_state: negative n"
            )
        if n == 0:
            _ = cancel_token^
            self._release_in_dispatch()
            return seg^
        if self._worker_senders.len() == 0:
            _ = seg^
            _ = cancel_token^
            self._release_in_dispatch()
            raise Error(
                "LocalDispatcher.run_with_state: no workers attached."
                " Call PerCoreAsyncRuntime.attach_worker[s] +"
                " start() before run_with_state."
            )

        # --- Fast path: pre-cancelled token short-circuits with
        # CancelledError before any enqueue. ---
        if cancel_token.is_cancelled():
            var reason = String(cancel_token.reason())
            _ = seg^
            _ = cancel_token^
            self._release_in_dispatch()
            raise Error(
                "LocalDispatcher.run_with_state: CancelledError: " + reason
            )

        # --- Choose worker count ---
        # Default: one shard per attached worker,
        # bounded above by n itself).
        var n_workers_avail = self._worker_senders.len()
        var n_workers = n_workers_avail
        if n < n_workers:
            n_workers = n

        # --- Reset per-dispatch state ---
        # `_in_flight` is now ACQUIRED,
        # not ASSERTED. It is seeded with ONE charge — the DRIVER's own — and each
        # shard's charge is `fetch_add`-ed at the moment that shard is actually
        # handed to a worker queue. A counter that is asserted up front
        # (`store(n_workers)`) is not a proof of anything: every deviation between
        # "handles that really entered a queue" and `n_workers` (a barrier-
        # bypassing early return, a send that never landed, a handle drained a
        # generation late) drives the counter to zero while a live borrower still
        # holds the caller's `ctx`, and the driver then pops the frame underneath
        # it. Acquiring the charge per successful post makes `_in_flight == 0`
        # mean exactly "every handle that entered a queue has run to completion".
        #
        # The driver's own charge is what keeps the counter off zero while the
        # enqueue loop is still running (worker 0 can finish its shard before
        # worker 1 has even been posted); the driver releases it once, after the
        # loop, on EVERY exit path — see `_drain_in_flight_barrier` below.
        #
        # before the reset, RECORD
        # whether the previous barrier told the truth. A non-zero `_in_flight`
        # here means a charge from a previous dispatch was never released — i.e.
        # that dispatch left the barrier with a live borrower into a stack frame
        # it then popped. The `store` below erases that evidence, which is
        # exactly why the leak was invisible for so long; count it first.
        # Deliberately NOT a raise: the stale-generation guard on
        # `_DispatchShard.run` already makes the leaked handle harmless, so
        # turning a rare race into a query failure would trade a fixed crash for
        # a new one. See `barrier_violations_snapshot()`.
        if self._in_flight[].load() != Int64(0):
            _ = self._viol_entry_leftover[].fetch_add(Int64(1))
        AtomicI64.store(
            UnsafePointer(to=self._in_flight[]).unsafe_bitcast[Scalar[DType.int64]](), Int64(1),
        )
        # Diagnostic: zero the per-dispatch DELIVERED / ENTERED shard masks.
        # Read by the barrier's stall dump to separate "a posted shard never
        # reached run()" from "a shard ran and never came back".
        self._shard_marks[].reset()
        AtomicI32.store(
            UnsafePointer(to=self._wake_word[]).unsafe_bitcast[Scalar[DType.int32]](), Int32(0),
        )
        # OPEN this dispatch's generation. Every
        # shard posted below is stamped with `my_gen`; `_drain_in_flight_barrier`
        # bumps the counter again on the way out, so the stamp matches ONLY while
        # `ctx` (built on THIS frame, below) is still alive.
        var my_gen = self._dispatch_gen[].fetch_add(Int64(1)) + Int64(1)
        # the stranded-charge settlement: the refusal count as of THIS dispatch's start. The barrier's
        # predicate is `in_flight <= (refusals raised since here)`, because a
        # refused shard never decrements. Snapshot BEFORE any shard is posted.
        var refusals_base = self._viol_stale_shard[].load()

        # --- Per-dispatch error slot ---
        var error_slot = _LdErrorSlot()

        # --- Move `seg` into _seg_buf (shared across shards) ---
        # SAFETY (per-dispatch wildcard carve-out): the dispatcher owns
        # _seg_buf for the lifetime of `self`. Multiple shard trampolines
        # READ through `seg_ptr` concurrently; Segment.execute is
        # required to be safe under shared-read access.
        comptime SegSize = size_of[T]()
        if self._seg_buf.capacity() < SegSize:
            self._seg_buf.resize(SegSize)
            self._seg_buf.set_len_unchecked(SegSize)
        elif self._seg_buf.len() < SegSize:
            self._seg_buf.set_len_unchecked(SegSize)
        var seg_byte_ptr = self._seg_buf._mut_ptr(0)
        var seg_typed_ptr = seg_byte_ptr.bitcast[T]()
        # SAFETY: Slab._mut_ptr returns a typed UnsafePointer into
        # heap-stable backing buffer; init_pointee_move consumes seg^
        # for the dispatch window.
        UnsafePointer(to=seg_typed_ptr[]).unsafe_write(seg^)

        # --- build the ONE per-dispatch context the shards
        # borrow INTO (the StateBoundWork concrete-origin Ctx) ---
        # The six borrows (state, shared Segment, in_flight, wake_word, error
        # slot, cancel token) bundle into ONE `_DispatchCtx` that lives on THIS
        # stack frame for the whole dispatch. Each member is reached BY CONCRETE
        # ORIGIN (Pointer(to=ref) inside _DispatchCtx.__init__) — NO wildcard
        # cast, NO Int laundering. The wake-word barrier below holds `ctx` alive
        # until every shard returns; the concrete origins make that lifetime
        # relation COMPILER-ENFORCED (the ctx cannot drop while a shard's
        # borrow is live — strictly safer than the six wildcard fields, which
        # erased the relation).
        # Origins are INFERRED from the `ref [origin]` ctor args (Pointer(to=ref)
        # ties each pointer's origin to the ref's origin — NO wildcard cast). The
        # same origins are re-derived for the trampoline monomorphization below.
        var ctx = _DispatchCtx(
            state,
            seg_typed_ptr[],
            self._in_flight[],
            self._wake_word[],
            error_slot,
            cancel_token,
        )

        # --- the BORROWED/POOLED `_DispatchShard` type, with
        # the FULL `_DispatchCtx` param set so its `ErasableWork.run()` can call
        # the typed ctx accessors + the REAL `seg.execute[State]` trait dispatch.
        # The shard binds the SAME `ctx` under ONE concrete `origin_of(ctx)`. ---
        comptime ShardT = _DispatchShard[
            State,
            T,
            origin_of(state),
            origin_of(seg_typed_ptr[]),
            origin_of(self._in_flight[]),
            origin_of(self._wake_word[]),
            origin_of(error_slot),
            origin_of(cancel_token),
            origin_of(self._dispatch_gen[]),
            origin_of(self._viol_stale_shard[]),
            origin_of(self._shard_marks[]),
            origin_of(self._refusal_detail[]),
            origin_of(self._task_cursor[]),
            origin_of(ctx),
        ]

        # FORK-JOIN CLAIMING: arm the shared cursor BEFORE the first shard is
        # posted. This is inside the `_in_dispatch` re-entrance CAS, so no other
        # dispatch can be reading it, and it strictly precedes every
        # `try_send`, so no shard can claim against a stale value. The OFF arm
        # never reads the cell; the store is one uncontended 8-byte write per
        # dispatch either way.
        AtomicI64.store(
            UnsafePointer(to=self._task_cursor[]).unsafe_bitcast[Scalar[DType.int64]](), Int64(0)
        )
        var claim_on = self._claim_on

        # --- Enqueue one shard per worker ---
        # SCHED-TRACE: the enqueue loop (make_erased + shard build
        # + try_send) is the bucket (c) dispatch CPU. Bracket its wall on the
        # cached-flag path.
        var enq_t0: UInt64 = UInt64(0)
        if sched_on:
            enq_t0 = UInt64(perf_counter_ns())
        var wid: Int = 0
        var n_sent: Int = 0
        var n_capture = n
        var n_workers_capture = n_workers
        while wid < n_workers:
            var lo = (wid * n_capture) // n_workers_capture
            var hi = ((wid + 1) * n_capture) // n_workers_capture
            # --- THE POOLED SLOT IS
            # THE BUG. Each shard now gets its OWN heap home. ---
            #
            # WHAT WAS HERE, AND WHY IT WAS WRONG. The shard used to be memcpy'd
            # into `self._shard_buf` slot `wid` and published as a NON-OWNING
            # `make_borrowed_erased` handle, so slot `wid` was REUSED by every
            # subsequent dispatch. That sharing is the defect. Worker `wid` runs
            # the slot through `_erased_run_for[ShardT]`, whose `work_ptr[].run()`
            # takes `mut self` on a trivially-copyable aggregate — the compiler
            # is free to materialise the struct into registers and STORE IT BACK
            # after `run()` returns. But `run()` RELEASES the barrier (the
            # `in_flight` `fetch_sub`) as its last statement, so that store-back
            # happens AFTER the driver is free to recycle the slot. A worker that
            # is descheduled in that window writes its own generation's bytes
            # back OVER the next dispatch's `memcpy`, and the slot silently
            # reverts one dispatch. That is exactly the measured fingerprint:
            # the refusing slot always holds a COMPLETE, SELF-CONSISTENT shard
            # from `observed_gen - 2` (`_gen`, `lo`, `hi`, `wid` all agreeing),
            # the enqueue read-back proved the driver's write DID land, and the
            # affected `wid` varies run to run.
            #
            # THE FIX IS TO STOP SHARING THE BYTES, not to detect the reversion
            # (fixes 4-6 detected it; the stamp made the failure SAFE, never
            # CORRECT — refused shards' task ranges simply did not run). With an
            # OWNING home the store-back is harmless by construction: it targets
            # THIS shard's private allocation, which no other generation can be
            # using, and which is freed only by this handle's own `__del__` —
            # strictly after `_erased_run_for` has returned, i.e. strictly after
            # the store-back. There is no window and no counter to get right.
            #
            # THIS COSTS NOTHING. The "ZERO per-shard heap alloc" the pool
            # existed for was already fiction: `_box_owned_into_bytes` did an
            # `alloc` + `free` PER SHARD PER DISPATCH to launder the aliasing
            # analyzer, and we then memcpy'd out of it. `make_erased[ShardT]`
            # does the SAME single `alloc` + `init_pointee_move` (it is the same
            # opaque-owned-`W` boundary shape, so the analyzer is equally
            # satisfied) and simply KEEPS that allocation as the handle's home.
            # Net change: one memcpy and one free REMOVED from the enqueue loop.
            #
            # `_shard_buf` and `_box_owned_into_bytes` had no other users and
            # are deleted along with this change.
            #
            # Each shard binds the SAME `ctx` (the
            # bundle of six borrows) under ONE concrete origin — `Pointer(to=ctx)`
            # inside `_DispatchShard.__init__`. The Segment is SHARED by
            # construction (a member of the ONE `ctx` every shard reaches).
            #
            # try_send_back with retry on FULL — `ErasedHandle` is Movable-only,
            # so the value comes BACK on non-OK and is re-sent. CLOSED is
            # unexpected — would mean a worker shut down its receiver. Treat as
            # fatal.
            var send_attempts = 0
            var max_send_attempts = 1_000_000
            var pending = Optional[ErasedHandle](
                make_erased[ShardT](
                    ShardT(
                        ctx,
                        self._dispatch_gen[],
                        self._viol_stale_shard[],
                        self._shard_marks[],
                        self._refusal_detail[],
                        self._task_cursor[],
                        gen=my_gen,
                        lo=Int64(lo),
                        hi=Int64(hi),
                        n_all=Int64(n_capture),
                        wid=Int32(wid),
                        claim=claim_on,
                    )
                )
            )
            # ACQUIRE this shard's barrier charge
            # BEFORE the send. It must precede the send, not follow it: the
            # instant `try_send_back` returns OK the consuming worker may already
            # be running the shard and decrementing, so a post-send `fetch_add`
            # could observe a counter the shard has already driven below its own
            # charge. The charge is UNDONE explicitly on each of the two failure
            # unwinds below (the handle never entered a queue there).
            _ = self._in_flight[].fetch_add(Int64(1))
            while send_attempts < max_send_attempts:
                var outcome = self._worker_senders[wid][].try_send_back(
                    pending.take()
                )
                if outcome.status == TRY_SEND_OK:
                    # Real count of handles that actually landed in a queue.
                    # `posted=n_workers` in the stall dump was a STATIC number,
                    # so it could never contradict the loop; this one can.
                    n_sent = n_sent + 1
                    # +: send THEN
                    # wake. Order is load-bearing (reverse causes lost-
                    # wake;). The dispatcher always invokes
                    # wake_with_elision() — the typed _SleepingFlag deref
                    # skips the eventfd_write syscall when the worker is
                    # already awake (the common case under fan-out where
                    # multiple shards complete back-to-back). When the
                    # worker IS parked the elision misses → real wake
                    # syscall fires. Drepper-safety lives in the worker's
                    # park-bracket (worker.mojo:680-715 re-checks queues
                    # AFTER setting _sleeping=1).
                    _ = self._worker_wake_handles[wid].wake_with_elision()
                    break
                if outcome.status == TRY_SEND_CLOSED:
                    # Receiver closed; release CAS; raise. Dropping the
                    # un-sent OWNING handle here frees this shard's home
                    # (the per-shard home) — it never entered a queue, so nothing else
                    # can be looking at it. The remaining shards are simply
                    # never built.
                    _ = outcome^
                    # THE BARRIER-BYPASS FIX.
                    # This handle never entered a queue, so give its charge back;
                    # then release the driver charge and WAIT for every shard
                    # already posted in THIS dispatch (wids 0..wid-1, which may be
                    # running right now) to finish. Pre-fix this branch raised
                    # immediately and popped the frame that owns `ctx` +
                    # `error_slot` while those shards were still dereferencing it
                    # — a use-after-free of the driver's stack frame, reported as
                    # a clean error.
                    # MOJO 1.0.0: `ctx` bundles borrows of `self._in_flight` /
                    # `self._wake_word`; the `mut self` calls below form new
                    # origins over those fields and invalidate them. Dropping
                    # the borrow-BUNDLE here changes nothing the drop-order comment
                    # below protects: what must not happen is consuming `seg` /
                    # `cancel_token` before `ctx` is gone, and that take-back
                    # is still further down.
                    _ = ctx^
                    _ = self._in_flight[].fetch_sub(Int64(1))
                    # `wid` charges landed in a queue (wids 0..wid-1); this one
                    # did not.
                    _ = self._drain_in_flight_barrier(refusals_base=refusals_base, n_posted=Int64(wid), n_diag=n, nw_diag=n_workers)
                    # --- KEEP
                    # `error_slot` ALIVE ACROSS THE BARRIER ON THIS UNWIND
                    # PATH. ---
                    #
                    # Mojo destroys a value at its LAST USE, PER BRANCH. On the
                    # SUCCESS path `error_slot` is read after the barrier (`if
                    # error_slot.is_set()` at the bottom of this function), so
                    # ASAP destruction holds it alive for the whole dispatch
                    # window for free. On THIS path nothing used it again, so
                    # the `_ = ctx^` above was `error_slot`'s last mention and
                    # the slot -- whose `_flag` is an `OwnedPointer` heap cell
                    # FREED BY ITS DESTRUCTOR -- was freed BEFORE
                    # `_drain_in_flight_barrier` was even entered, i.e. while
                    # every shard posted in wids 0..wid-1 was still running and
                    # still calling `self.ctx_ref().error_slot_ref().is_set()`
                    # on every task it claims.
                    #
                    # That is the exact use-after-free this unwind's barrier
                    # exists to prevent, reopened by the 1.0.0 borrow-checker
                    # migration that moved `_ = ctx^` above the barrier: the
                    # BARRIER survived that move, but one of the things it was
                    # holding alive did not. The barrier proves no shard still
                    # dereferences the ctx STORAGE; it cannot prove the
                    # borrowED values are still constructed, and only their
                    # live ranges can.
                    #
                    # Without it (reproduced deterministically by
                    # `test_local_dispatcher_barrier_bypass`):
                    # shard 0 was DELIVERED and
                    # ENTERED `run()` (both mask bits set, zero stale refusals,
                    # in_flight back to 0) and then ran ZERO tasks. Its first
                    # `error_slot.is_set()` read the freed cell, saw a non-zero
                    # byte and broke out of the claim loop, so the driver
                    # returned a `queue closed` error having silently dropped
                    # every task. A shard taking the error arm instead would
                    # `try_set()` -- a WRITE of a `String` into the freed slot.
                    #
                    # One atomic load is the whole fix: it is a USE, so ASAP
                    # destruction cannot free the flag until after the barrier
                    # has proved no shard can reach it. Same Trap-2 keepalive
                    # shield the success path already applies to `seg` /
                    # `state` / `cancel_token`.
                    _ = error_slot.is_set()  # keepalive touch -- see above
                    # Same shield for the on-pool depth bracket, for the same
                    # reason: the shards this barrier just waited out may call
                    # `gather_batch`, which requires depth > 0 for the whole
                    # window -- exactly as on the success path.
                    _on_pool_guard.keepalive()
                    self._release_in_dispatch()
                    # Drop the bundled-borrow `ctx` BEFORE
                    # consuming the values it borrows (seg + cancel_token) — the
                    # concrete origins make those borrows compiler-tracked, so
                    # the borrowed-from values can only be consumed after the
                    # borrow-holder is gone. Now sound: the barrier above proved
                    # no shard still holds a borrow into it. (1.0.0 moved the
                    # `_ = ctx^` above the barrier -- see the note there.)
                    # Take the moved-in seg back so the caller doesn't
                    # leak it either.
                    var seg_back_err = UnsafePointer(
                        to=seg_typed_ptr[]
                    ).take_pointee()
                    _ = seg_back_err^
                    self._seg_buf.set_len_unchecked(0)
                    # consume the var cancel_token
                    # parameter so it drops here. Replaces the prior
                    # `_ = owned_token^` (heap-pin consumption).
                    _ = cancel_token^
                    raise Error(
                        "LocalDispatcher.run_with_state: worker"
                        + String(wid)
                        + " queue closed (worker shut down before barrier)"
                    )
                # TRY_SEND_FULL — take the handle back + back off + retry.
                pending = Optional[ErasedHandle](outcome.take_value())
                cpu_pause()
                send_attempts = send_attempts + 1
            if send_attempts >= max_send_attempts:
                # Treat persistent FULL as queue-deadlock; release +
                # raise. Dropping the still-pending OWNING handle frees
                # this shard's home (the per-shard home) — it never entered a queue.
                _ = pending.take()
                # twin of the CLOSED branch above:
                # give back the charge for the handle that never landed, release
                # the driver charge, and WAIT OUT the shards already posted in
                # this dispatch before the frame that owns `ctx` unwinds.
                # MOJO 1.0.0: drop the borrow-BUNDLE before the `mut self`
                # calls that re-form origins over the fields it borrows. See
                # the sibling note on the CLOSED branch above.
                _ = ctx^
                _ = self._in_flight[].fetch_sub(Int64(1))
                _ = self._drain_in_flight_barrier(refusals_base=refusals_base, n_posted=Int64(wid), n_diag=n, nw_diag=n_workers)
                # --- KEEP
                # `error_slot` ALIVE ACROSS THE BARRIER ON THIS UNWIND PATH.
                # ---
                #
                # Mojo destroys a value at its LAST USE, PER BRANCH. On the
                # SUCCESS path `error_slot` is read after the barrier (`if
                # error_slot.is_set()` at the bottom of this function), so ASAP
                # destruction holds it alive for the whole dispatch window for
                # free. On THIS path nothing used it again, so the `_ = ctx^`
                # above was `error_slot`'s last mention and the slot -- whose
                # `_flag` is an `OwnedPointer` heap cell FREED BY ITS
                # DESTRUCTOR -- was freed BEFORE `_drain_in_flight_barrier` was
                # even entered, i.e. while every shard posted in wids 0..wid-1
                # was still running and still calling
                # `self.ctx_ref().error_slot_ref().is_set()` on every task it
                # claims.
                #
                # That is the exact use-after-free this unwind's barrier exists
                # to prevent, reopened by the 1.0.0 borrow-checker migration
                # that moved `_ = ctx^` above the barrier: the BARRIER survived
                # that move, but one of the things it was holding alive did
                # not. The barrier proves no shard still dereferences the ctx
                # STORAGE; it cannot prove the borrowED values are still
                # constructed, and only their live ranges can.
                #
                # Without it (reproduced deterministically by
                # `test_local_dispatcher_barrier_bypass`): shard 0 was
                # DELIVERED and ENTERED `run()` (both mask bits set, zero stale
                # refusals, in_flight back to 0) and then ran ZERO tasks. Its
                # first `error_slot.is_set()` read the freed cell, saw a non-
                # zero byte and broke out of the claim loop, so the driver
                # returned a `queue closed` error having silently dropped every
                # task. A shard taking the error arm instead would `try_set()`
                # -- a WRITE of a `String` into the freed slot.
                #
                # One atomic load is the whole fix: it is a USE, so ASAP
                # destruction cannot free the flag until after the barrier has
                # proved no shard can reach it. Same Trap-2 keepalive shield
                # the success path already applies to `seg` / `state` /
                # `cancel_token`.
                _ = error_slot.is_set()  # keepalive touch -- see above
                # Same shield for the on-pool depth bracket, for the same
                # reason: the shards this barrier just waited out may call
                # `gather_batch`, which requires depth > 0 for the whole window
                # -- exactly as on the success path.
                _on_pool_guard.keepalive()
                self._release_in_dispatch()
                # The bundled-borrow `ctx` is dropped ABOVE the barrier
                # under 1.0.0 (see the note there); what still matters here is
                # that `seg` / `cancel_token` are consumed only after it.
                var seg_back_err2 = UnsafePointer(
                    to=seg_typed_ptr[]
                ).take_pointee()
                _ = seg_back_err2^
                self._seg_buf.set_len_unchecked(0)
                # see twin _ = cancel_token^ above.
                _ = cancel_token^
                raise Error(
                    "LocalDispatcher.run_with_state: worker"
                    + String(wid)
                    + " queue persistently FULL"
                    " (worker not draining; check that start() was called)"
                )
            wid = wid + 1

        # SCHED-TRACE: enqueue-loop wall complete (bucket c) +
        # erasure volume (= n_workers make_erased calls this dispatch).
        if sched_on:
            sched_trace_add_dispatch(
                UInt64(perf_counter_ns()) - enq_t0, UInt64(n_workers),
            )

        # --- Driver-side barrier: release the driver charge, wait for 0 ---
        # ONE barrier implementation, shared with the
        # two error unwinds above so no exit path can bypass it. On return, every
        # handle that entered a worker queue has completed its last `ctx`
        # dereference, which is what makes the `ctx` drop + frame unwind below
        # sound. See `_drain_in_flight_barrier`.
        # MOJO 1.0.0: `ctx` bundles borrows of `self._in_flight` /
        # `self._wake_word`, and this `mut self` call re-forms origins over
        # those fields, invalidating them. The ordering it protects is
        # "drop `ctx` BEFORE consuming `seg` / `cancel_token`", and the
        # seg take-back is still far below -- so dropping the borrow-BUNDLE
        # here preserves that ordering exactly. What the barrier proves
        # (no shard still dereferences the ctx STORAGE) is unaffected: this
        # destroys a borrow value, it does not free the frame.
        _ = ctx^
        var stranded_shards = self._drain_in_flight_barrier(refusals_base=refusals_base, n_posted=Int64(n_sent), n_diag=n, nw_diag=n_workers)

        # SCHED-TRACE: the barrier returned — record this fork's
        # span (fork_start -> now) + the driver-serial inter-fork gap since the
        # previous dispatch (bucket a driver-view). Every barrier return is a real
        # segment (a subsequent error_slot raise still means work forked + ran).
        if sched_on:
            # Effective call-site: the explicit `site_id` arg wins; when unlabeled
            # (0), fall back to the ambient SchedSiteScope pushed by an owned
            # enclosing frame (labels forks in a callee this file cannot edit).
            var eff_site = site_id
            if eff_site == UInt32(0):
                eff_site = sched_trace_get_site()
            # The barrier has returned, so every shard's final `store()` has
            # landed and the busy delta covers this fork's whole window.
            sched_trace_add_segment_occ(
                eff_site,
                fork_start_ns,
                UInt64(perf_counter_ns()),
                UInt64(n_workers),
                busy_at_fork_ns,
                sched_trace_worker_busy_total(),
            )

        # --- Dual keepalive (Wave UAF Trap 2 shield) ---
        # Also keep cancel_token alive past the wake-word
        # barrier so the trampoline's cancel poll is guaranteed to see live
        # memory.
        # cancel_token now lives at its
        # var-parameter stack slot (no heap pin). Touch via direct
        # is_cancelled() call to hold the parameter live across the
        # barrier — same effect as the prior OwnedPointer touch.
        # Keep `ctx` (the bundled-borrow owner the shards
        # borrow INTO) alive past the barrier — its concrete origins already
        # make the borrow lifetime compiler-enforced, but the explicit touch
        # after the barrier-wait is the canonical Trap-2 shield.
        seg_typed_ptr[].__keep_alive()
        state.__keep_alive()
        _ = cancel_token.is_cancelled()  # keepalive touch
        # MOJO 1.0.0: `ctx`'s borrow of `self._in_flight` is invalidated by
        # the `mut self` barrier above, so this keepalive touch can no longer
        # read THROUGH it. Touch the field directly -- same atomic, same
        # keepalive intent, no borrow.
        _ = self._in_flight[].load()  # ctx keepalive touch
        # Hold the on-pool depth bracket live PAST the worker
        # barrier — the depth must stay > 0 for the whole window any worker
        # could call `gather_batch`. The destructor decrements after this point.
        _on_pool_guard.keepalive()
        # `ctx` (the bundled-borrow owner) is dropped ABOVE
        # the barrier under 1.0.0 — see the note there. What is still
        # compiler-enforced here is the half that matters: the values it
        # borrows (seg / cancel_token) are consumed only after it is gone.

        # --- Destructure: take seg back out of _seg_buf ---
        # SAFETY (carve-out for per-dispatch wrapper bytes
        # in Slab[UInt8]): the canonical per-dispatch wrapper shape. The bytes
        # are init'd with `seg^` at dispatch entry; we extract via
        # take_pointee and mark the slab empty so no destructor runs on
        # moved-out bytes.
        var seg_back = UnsafePointer(to=seg_typed_ptr[]).take_pointee()
        self._seg_buf.set_len_unchecked(0)

        # --- Release re-entrance flag BEFORE possibly raising ---
        self._release_in_dispatch()

        # --- First-error check ---
        if error_slot.is_set():
            _ = seg_back^
            raise Error(
                "LocalDispatcher.run_with_state: " + error_slot.message()
            )
        # --- FAIL LOUD ON A REFUSED SHARD ---
        # A refused shard's task range NEVER RAN. The barrier can now return
        # instead of hanging forever, but the RESULT IS INCOMPLETE — silently
        # returning it would trade a fail-stop wedge for wrong answers, which is
        # strictly worse for a query engine. Raise instead: same class of outcome
        # as the hang (this query is lost) with none of the process wedge.
        if stranded_shards > Int64(0):
            _ = seg_back^
            raise Error(
                "LocalDispatcher.run_with_state: "
                + String(stranded_shards)
                + " shard(s) refused by the stale-generation guard and their"
                " task ranges did not run. Result is INCOMPLETE. This guard was"
                " built for a use-after-free (cross-generation reuse of a"
                " pooled shard slot), which cannot recur now that each"
                " shard has its own home — so a refusal here is a NEW defect, not"
                " that one, and the shard's `_gen` stamp cannot go stale by the"
                " old mechanism. Do not re-add slot pooling to 'fix' it."
            )
        return seg_back^

    # -------------------------------------------------------------------------
    # for_each_morsel — morsel-stealing dispatch surface
    # -------------------------------------------------------------------------

    def for_each_morsel[
        State: KeepAlive,
        MorselT: Copyable & ImplicitlyCopyable
            & Movable & Deinitable,
        B: MorselBody,
    ](
        mut self,
        mut state: State,
        var morsels: List[MorselT],
        var body: B,
        var cancel_token: CancellationToken,
    ) raises -> B:
        """Dispatch `body.process(state, wid, morsel)` once per morsel
        across the worker pool. Adapts dispatch shape to the morsel /
        worker-count ratio:

          * `n_morsels <= W`: STATIC dispatch — one task per morsel,
            no MorselPool overhead. Cheapest path.
          * `n_morsels >  W`: POOLED dispatch — MorselPool[MorselT] +
            W drain-tasks. DuckDB-style work-stealing at the data level
            (measured as a large wall reduction at batch=16 vs static partition
            on 10:1 skew).

        Cancellation: `cancel_token` is polled BETWEEN morsels by every
        drain-task. On cancel, the drain loop exits cleanly and the
        first-error-wins surface raises
        `LocalDispatcher.run_with_state: CancelledError: <reason>`.

        Args:
          state: Borrowed for the dispatch window. Caller retains
            ownership; the wake-word barrier in `run_with_state`
            guarantees workers return before this method returns.
          morsels: MOVED into the dispatcher. Static-mode: each morsel
            is taken via Optional.take() at its index. Pooled-mode: each
            morsel is `submit()`-ed into the internal MorselPool. On
            return the list / pool are empty (any unclaimed morsels
            after a cancel are dropped via the pool's destructor).
          body: MOVED into the dispatcher; returned to the caller on
            success (move-back); on Error, the body is dropped (Movable
            but not Copyable, so no copy is made).
          cancel_token: MOVED for the dispatch window. Pass
            `CancellationToken.never()^` to disable cancellation; pass
            `caller_token.clone()^` to retain a separate handle on the
            caller side for `cancel()`.

        Returns:
          The body, moved back from the dispatcher.

        Raises:
          * "LocalDispatcher.run_with_state: CancelledError: <reason>"
            if the cancel_token was cancelled mid-dispatch.
          * "LocalDispatcher.run_with_state: <body error>" if any
            invocation of `body.process` raised.
          * Any error raised by `run_with_state` (no-workers, nested
            dispatch, etc.).
        """
        var n = len(morsels)
        if n == 0:
            _ = morsels^
            _ = cancel_token^
            return body^

        var w = self._worker_senders.len()
        if w == 0:
            _ = morsels^
            _ = cancel_token^
            _ = body^
            raise Error(
                "LocalDispatcher.for_each_morsel: no workers attached."
                " Call PerCoreAsyncRuntime.attach_worker[s] +"
                " start() before for_each_morsel."
            )

        # Decide dispatch mode.
        var use_pool = n > w

        # Build the per-dispatch wrapper state: either populate the
        # static `morsels` list (n_dispatch_tasks = n) OR populate the
        # MorselPool (n_dispatch_tasks = w). The pool lives on this
        # stack frame (MorselPool is non-Movable); pool_ptr is a
        # per-dispatch wildcard borrow good for the wake-word barrier.
        var static_morsels = List[Optional[MorselT]]()
        var pool_cap = _next_pow2_ge(n) if use_pool else UInt(2)
        var pool = MorselPool[MorselT].with_capacity(pool_cap)

        if use_pool:
            # Submit every morsel into the pool. The pool's submit
            # raises only on full or already-closed; capacity is sized
            # to next_pow2(n) so full is impossible at populate time.
            var i = 0
            while i < n:
                pool.submit(morsels[i])
                i = i + 1
            _ = morsels^
            # Close the pool so workers can detect drained state via
            # is_drained() if they want; for our drain loop we exit on
            # first empty try_claim() (single-producer-completed-before
            # -dispatch contract).
            pool.close()
        else:
            # Static mode: stash each morsel into Optional slots so
            # workers can take() by index without partial-move.
            var i = 0
            while i < n:
                static_morsels.append(Optional[MorselT](morsels[i]))
                i = i + 1
            _ = morsels^

        # Build the wrapper state. The THREE per-dispatch borrows (outer State,
        # NON-Movable MorselPool, CancellationToken) are ENCAPSULATED behind the
        # ONE `NestedBorrowBundle` primitive: the SOLE
        # allowlisted `MutExternalOrigin` FIELD of the whole `_ForEachState`
        # encapsulation lives inside that primitive — `for_each_morsel` and
        # `_ForEachState` carry ZERO bespoke wildcard fields.
        #
        # The concrete-origin frame and the borrow/owned SPLIT
        # confirmed the wildcard CANNOT be eliminated for this
        # nested-dispatch site: the `StateBoundWork` concrete-origin migration was
        # attempted for the three borrows and HALTED again under Mojo 1.0.0b1's
        # aliasing analyzer — giving the borrows concrete origins makes the
        # SEGMENT's `execute` body accessors (reached via a bitcast of `state`
        # over `origin_of(state)`) trip "reading a memory location previously
        # writable through another aliased argument" (every access aliases the
        # live `mut state` borrow). This is the same structural wall the
        # Pattern-A wall, shifted from the
        # `run_with_state(wrapper, seg)` call (which the new POD-segment +
        # `_DispatchCtx` dispatch DID unblock) to the segment-body accessors —
        # and there is no opaque-owned-`W` laundering escape (the shape
        # `make_erased[W](var work)` uses) because the wrapper IS the `state`
        # arg, not an internally-built POD the dispatcher boxes itself. So the wildcard is a SANCTIONED per-dispatch carve-out, now
        # ENCAPSULATED behind `NestedBorrowBundle` (constructed + dropped within
        # `for_each_morsel`'s stack frame, NOT in the destroy-recreate lifecycle).
        #
        # The three wildcard borrow pointers are formed ONCE here, at the bundle
        # boundary, and handed to `NestedBorrowBundle.new` which confines them
        # behind its ONE blessed `_home` byte-ptr handle.
        var outer_state_ptr = UnsafePointer(to=state).unsafe_origin_cast[
            MutUntrackedOrigin,
        ]()
        var cancel_token_ptr = UnsafePointer(
            to=cancel_token,
        ).unsafe_origin_cast[MutUntrackedOrigin]()
        var pool_ptr = UnsafePointer(to=pool).unsafe_origin_cast[
            MutUntrackedOrigin,
        ]()
        var borrows = NestedBorrowBundle[State, MorselT].new(
            outer_state_ptr=outer_state_ptr,
            pool_ptr=pool_ptr,
            cancel_token_ptr=cancel_token_ptr,
        )
        var wrapper = _ForEachState[State, MorselT, B](
            body=body^,
            morsels=static_morsels^,
            use_pool=use_pool,
            borrows=borrows^,
        )

        # Dispatch through the existing run_with_state. The number of
        # tasks differs per mode: static ⇒ n (one per morsel); pooled
        # ⇒ w (one drain-task per worker).
        var n_tasks = w if use_pool else n

        # Use a try/except to catch errors from run_with_state so we
        # can surface the body back cleanly.
        var raised_msg = String("")
        var did_raise = False
        # Pass `never()` to the inner run_with_state — the
        # for_each_morsel path already polls the per-morsel cancel_token
        # in its own body loop (`_ForEachState.cancel_token_ptr` →
        # body.process gating). Layering a second poll on the inner
        # run_with_state would be redundant and would attempt to consume
        # the caller's `cancel_token` from inside the wrapper state,
        # which we want to keep accessible for the inner morsel loop.
        if use_pool:
            var seg = _ForEachPooledSegment[State, MorselT, B](_pad=0)
            try:
                var _seg_back = self.run_with_state[
                    _ForEachState[State, MorselT, B],
                    _ForEachPooledSegment[State, MorselT, B],
                ](wrapper, seg^, n_tasks, CancellationToken.never())
                _ = _seg_back^
            except e:
                did_raise = True
                raised_msg = String(e)
        else:
            var seg = _ForEachStaticSegment[State, MorselT, B](_pad=0)
            try:
                var _seg_back = self.run_with_state[
                    _ForEachState[State, MorselT, B],
                    _ForEachStaticSegment[State, MorselT, B],
                ](wrapper, seg^, n_tasks, CancellationToken.never())
                _ = _seg_back^
            except e:
                did_raise = True
                raised_msg = String(e)

        # Extract body back from the wrapper state via the
        # heap-stash + OwnedPointer.into_inner pattern.
        # Each take_pointee operates on POD bytes (the OwnedPointer
        # handle); the inner value is then extracted via .take().
        var buf = alloc[_ForEachState[State, MorselT, B]](1)
        UnsafePointer(to=buf[]).unsafe_write(wrapper^)
        var body_handle = UnsafePointer(to=buf[].body).take_pointee()
        var _morsels_handle = UnsafePointer(to=buf[].morsels).take_pointee()
        # The encapsulated `borrows` bundle OWNS one small POD carrier
        # — extract it via take_pointee (the bundle
        # itself is POD: one byte-ptr handle) and explicitly drop it below so
        # its `__del__` frees the carrier exactly once (no leak). The three
        # borrows it reached are caller-owned and outlive the bundle (the
        # wake-word barrier already joined every worker above).
        var borrows_handle = UnsafePointer(to=buf[].borrows).take_pointee()
        # use_pool is POD; safe to leave in place. Free the heap stash without
        # running destructors over the moved-out fields (each was take_pointee'd
        # out, so the stash bytes hold no live owner).
        buf.bitcast[UInt8]().free()

        var body_back = body_handle^.into_inner()
        _ = _morsels_handle^
        # Drop the bundle — its `__del__` frees the carrier heap allocation.
        _ = borrows_handle^
        _ = cancel_token^
        _ = pool^

        if did_raise:
            _ = body_back^
            raise Error(raised_msg)
        return body_back^

    def for_each_index[
        State: KeepAlive, B: MorselBody,
    ](
        mut self,
        mut state: State,
        n: Int,
        var body: B,
        var cancel_token: CancellationToken,
    ) raises -> B:
        """Convenience: for_each_morsel over the integer range [0, n).

        Equivalent to building `[0, 1, ..., n-1]` and passing to
        `for_each_morsel`. The body's `process` receives the index as
        the morsel value. Used by engine sites that only need the
        morsel-index dispatch shape (`run_with_state(..., n)`
        ergonomics).
        """
        var ids = List[Int](capacity=n)
        for i in range(n):
            ids.append(i)
        return self.for_each_morsel[State, Int, B](
            state, ids^, body^, cancel_token^,
        )
