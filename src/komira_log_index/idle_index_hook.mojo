# =============================================================================
# komira_log_index.idle_index_hook: the native-index idle hook.
# =============================================================================
#
# This is the producer side of the type-erasure boundary that
# `komira_async.runtime.installable_hook` crosses. The hook names the concrete
# parametric store, the `SearchMetastore[Storage]` and the index config, none of
# which the worker can name (komira_async cannot import komira_log_index). It
# monomorphizes the fire trampoline `_run_idle_hook_for[...]` and installs it on
# every worker through `install_native_index_idle_hook`. The type-erasure
# handle and the context-home allocation live once, in the installable-hook
# primitive; this file reaches the erased context through the opaque
# `HookCtxPtr` alias and never spells a wildcard origin.
#
# THE ENGINE REACH. The worker-side drain must reach the long-lived
# `SharedEngine` to consume its own SPSC ring. A `MutCarriedHandle[SharedEngine,
# engine_origin]` is baked into the context at install time, where the engine
# and the install are both in scope with concrete origins. The worker rebuilds
# the context (through an OwnedPointer wrap) and reaches the engine through the
# carried handle's `get_mut()`, a concrete-origin pointer the compiler tracks.
# The lifetime contract is join-before-drop: the runtime joins every worker
# before the owner drops the engine.
#
# WHAT THE HOOK DOES (each idle window; it builds inline and does not spawn):
#   On the owning worker's own thread, in the empty-spin idle window:
#     1. drain up to `DRAIN_CAP` records from the worker's ring through the baked
#        engine handle (`drain_worker_to_records`). This is SPSC-safe by
#        construction: it runs on the worker that owns `ring(worker_id)`;
#     2. transpose on-core (`log_views_to_record_batch`);
#     3. build the cheap L0 posting split inline (`L0SegmentBuilder`, the same
#        body as `L0BuildTask.run`, lifted here so it runs on the draining
#        thread with no re-dispatch);
#     4. publish into the worker's drain sub-lineage: the split PUT first (an
#        idempotent orphan on a crash), then the metastore CAS-append (the
#        linearization point that makes it searchable). Each worker has its own
#        shard (`make_shard_id(node, worker_id, "drain")`), so workers do not
#        contend on a shared manifest head.
#
# WHY INLINE, NOT SPAWN: a round-robin spawn would land the build on the wrong
# worker. The drained `List[LogRecordView]` is owned plain data, so the build is
# worker-agnostic after the drain; drain and build stay on the one calling
# thread with no re-dispatch.
#
# DURABILITY:
#   - Idle path: an idle worker drains and publishes every non-empty window.
#   - Busy worker (no idle windows): the hook only fires on idle windows, so a
#     perpetually busy worker does not drain its own ring; its durability is the
#     owner's `flush_all_pending` (a final flush and a periodic flush tick). The
#     un-flushed window is the documented at-most-once loss.
#   - Graceful shutdown: `flush_all_pending` drains every worker's ring
#     synchronously (the runtime has joined all workers, so there is no SPSC
#     race) and publishes, with no loss. Only a hard crash loses the un-flushed
#     window.
#
# OWNERSHIP: the concrete context `IdleIndexContext[Storage, engine_origin]` is
# consumed into a long-lived raw home (through `installable_hook_home`) that the
# worker borrows through the `ErasedHook.ctx_raw` byte pointer. The owner holds
# the returned `InstalledIndexHook` and frees the home through
# `drop_installed_hook` after the runtime joins every worker (`flush_all_pending`
# first, then drop).
#
# Pointer discipline: no public signature has a pointer type.
# `IdleIndexContext` holds owned-by-value config Strings, the cloneable store by
# value, an `OwnedPointer[Atomic]` sequence counter and the baked
# `MutCarriedHandle` (a plain concrete-origin `Pointer`, no heap). The drained
# views are an owned `List[LogRecordView]`. The remaining unsafe operations are
# the `bitcast` and `OwnedPointer(unsafe_from_raw_pointer=)` calls that rebuild
# the context from the erased handle; each carries a `# SAFETY:` comment.
# =============================================================================

from std.atomic import Atomic
from std.memory import alloc, OwnedPointer

from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy

from komira_search_catalog import (
    SearchMetastore,
    make_shard_id,
    shard_manifest_prefix,
    make_split_summary,
)

from komira_async.runtime.installable_hook import (
    ErasedHook,
    HookCtxPtr,
    installable_hook_home,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.shared_erasure import MutCarriedHandle
from komira_async.ops.waker_sink import WakerSink

from komira_log import LogRecordView
from komira_log.engine.shared_engine import SharedEngine

from komira_log_index.transpose import (
    LOG_INDEX_TEXT_FIELD,
    log_index_schema,
    log_views_to_record_batch,
)
from komira_log_index.l0_index import L0SegmentBuilder
from komira_log_index.l0_build_task import _object_key_for_uuid


# -----------------------------------------------------------------------------
# DRAIN_CAP — the per-fire drain bound. Sized to one cheap L0 build's worth of
# records (about 16 to 24 documents, roughly 50us, below one reactor-poll
# starvation window). One idle visit does at most one cheap build and publish;
# the remaining records ride the next idle window or the owner's flush tick.
comptime DRAIN_CAP: Int = 24


# -----------------------------------------------------------------------------
# IdleIndexContext[Storage, engine_origin] — the concrete parametric context the
# hook body names (the thing the worker cannot name). Held in a long-lived raw
# home owned by the caller of the install.
# -----------------------------------------------------------------------------


struct IdleIndexContext[
    Storage: CloneableConditionalWriteStore,
    engine_origin: Origin[mut=True],
](Movable, Deinitable):
    """The long-lived native-index hook context. Owns the cloneable store, the
    publish config and the baked engine handle; per-build it mints per-worker
    drain-shard metastores.

    `[Storage]` selects the store backend (the in-memory conditional store in
    tests, any `CloneableConditionalWriteStore` in production), the same
    selector `L0BuildTask` and `SearchMetastore` use. `[engine_origin]` ties the
    baked `MutCarriedHandle[SharedEngine, engine_origin]` to the engine's
    concrete mutable origin.

    Thread-safety: the worker fires the hook on its own thread, and multiple
    workers share ONE context (through the byte-pointer borrow). The config
    fields are read-only (cloned per build); the only mutable state is `_seq`,
    an `OwnedPointer[Atomic]` that is a process-wide monotone split-uuid
    disambiguator (`fetch_add` is thread-safe). Each worker drains its own ring
    (`drain_worker_to_records(worker_id)`, SPSC) and writes its own drain shard
    (`make_shard_id` keys on worker_id), so there is no cross-worker manifest
    contention.

    The store is owned by value; `_seq` is the non-Movable-Atomic OwnedPointer
    pattern; the Strings are owned; `_engine` is a plain `MutCarriedHandle` (a
    single concrete-origin `Pointer`, no heap).
    """

    var _store: Self.Storage
    var _node_id: String
    var _meta_root: String  # "<key_prefix>/<index>/meta"
    var _index: String  # the index name (for example "logs")
    var _seq: OwnedPointer[Atomic[DType.int64]]
    var _retry: RetryPolicy
    # The baked engine reach: a concrete-mutable-origin handle to the engine,
    # reached through `get_mut()` for the `mut self` drain.
    var _engine: MutCarriedHandle[SharedEngine, Self.engine_origin]

    def __init__(
        out self,
        var store: Self.Storage,
        var node_id: String,
        var meta_root: String,
        var index: String,
        ref [Self.engine_origin] engine: SharedEngine,
        retry: RetryPolicy = RetryPolicy.fast_test(),
    ):
        self._store = store^
        self._node_id = node_id^
        self._meta_root = meta_root^
        self._index = index^
        # Atomic is not Movable, so: alloc, assign in place, then transfer
        # ownership to the OwnedPointer (not `value=`, which needs a Movable
        # payload).
        var seq_ptr = alloc[Atomic[DType.int64]](1)
        # SAFETY: fresh allocation we own; assign in place, then move into the
        # OwnedPointer, whose destructor frees it.
        seq_ptr[] = Atomic[DType.int64](Int64(0))
        self._seq = OwnedPointer[Atomic[DType.int64]](
            unsafe_from_raw_pointer=seq_ptr
        )
        self._retry = retry
        # Bake the concrete-mutable-origin engine handle; the worker reaches the
        # engine through it at drain time.
        self._engine = MutCarriedHandle[SharedEngine, Self.engine_origin](engine)

    def _next_uuid(mut self, worker_id: UInt16) -> InlineArray[UInt8, 16]:
        """Mint a unique-per-build split uuid: worker_id in bytes 0 and 1 and a
        process-wide atomic seq in bytes 8..16. (worker_id, seq) is unique across
        all workers in this process, so content-addressed object keys never
        collide."""
        var s = self._seq[].fetch_add(1)
        var u = InlineArray[UInt8, 16](fill=UInt8(0))
        u[0] = UInt8(Int(worker_id) & 0xFF)
        u[1] = UInt8((Int(worker_id) >> 8) & 0xFF)
        var sv = UInt64(s)
        for i in range(8):
            u[8 + i] = UInt8(Int((sv >> UInt64(i * 8)) & UInt64(0xFF)))
        return u^

    def next_uuid(mut self, worker_id: UInt16) -> InlineArray[UInt8, 16]:
        """Public alias of `_next_uuid`; the trampoline reads the sequence
        through this on the first-level borrow (atomic, thread-safe)."""
        return self._next_uuid(worker_id)

    def drain_build_publish_one(mut self, worker_id: UInt16) raises -> Int:
        """One hook fire. Drain up to DRAIN_CAP records from `worker_id`'s ring
        (through the baked engine handle, `self._engine.get_mut()`) and build and
        publish them. The worker-thread fire and the main-thread flush callers
        both route here."""
        var wid = Int(worker_id)
        if not self._engine.get_mut().worker_ring_nonempty(wid):
            return 0
        var views = self._engine.get_mut().drain_worker_to_records(wid, DRAIN_CAP)
        if len(views) == 0:
            return 0
        var node_id = self._node_id.copy()
        var meta_root = self._meta_root.copy()
        var index = self._index.copy()
        var store = self._store.clone()
        var retry = self._retry
        var uuid = self._next_uuid(worker_id)
        return _build_and_publish_split[Self.Storage](
            views^, worker_id, node_id^, meta_root^, index^, store, uuid^, retry
        )

    def flush_worker_unbounded(mut self, worker_id: UInt16) raises -> Int:
        """Drain and publish EVERY record currently on `worker_id`'s ring, in
        DRAIN_CAP-sized splits, until the ring is empty. The graceful-shutdown
        and flush-tick path: the owner calls this per worker after the runtime
        has joined all workers (no SPSC race), so the un-flushed window is
        published and nothing is lost on a graceful shutdown."""
        var total = 0
        while True:
            var wid = Int(worker_id)
            if not self._engine.get_mut().worker_ring_nonempty(wid):
                break
            var views = self._engine.get_mut().drain_worker_to_records(
                wid, DRAIN_CAP
            )
            if len(views) == 0:
                break
            var node_id = self._node_id.copy()
            var meta_root = self._meta_root.copy()
            var index = self._index.copy()
            var store = self._store.clone()
            var retry = self._retry
            var uuid = self._next_uuid(worker_id)
            total += _build_and_publish_split[Self.Storage](
                views^, worker_id, node_id^, meta_root^, index^, store, uuid^,
                retry,
            )
        return total

    def flush_all_pending(mut self, num_workers: Int) raises -> Int:
        """Graceful-shutdown final flush: drain and publish every worker's
        pending ring. Call after `runtime.shutdown()` joins all worker threads
        and before dropping the context. Returns the total docs published. Nothing
        is lost on a graceful shutdown; only a hard crash loses the un-flushed
        window (the at-most-once contract). Main-thread caller."""
        var total = 0
        var w = 0
        while w < num_workers:
            total += self.flush_worker_unbounded(UInt16(w))
            w += 1
        return total


# -----------------------------------------------------------------------------
# InstalledIndexHook — the install return, and the thing that keeps the engine
# alive.
# -----------------------------------------------------------------------------
#
# `ErasedHook` is plain data and carries no origin; that is the point of it, it
# is the type-erasure boundary the worker can name. If the install returned a
# bare `ErasedHook`, no live value in the caller's frame would have a type that
# mentions `engine_origin`, and the compiler's as-soon-as-possible destruction
# would end the engine's life at its last direct use (the emit), before the hook
# ever fires. The installed hook would then drain a destroyed `SharedEngine`
# (what that looks like: a freed block reads as an engine with zero workers and
# partly valid rings, and which record goes bad depends on allocator traffic).
#
# The fix is a type, not a convention. The install returns THIS struct, whose
# type mentions `engine_origin`, so the borrow the hook holds is a borrow the
# compiler can see. Every use of the returned value (the fire in between, the
# flush, the drop) extends the engine's life past that point.
#
# What is load-bearing: `engine_origin` appearing in the TYPE of a live value.
# The keepalive FIELD is not what fixes this (deleting it while leaving the
# struct parameterized on `engine_origin` still passes the end-to-end test). The
# field is kept so that `engine_origin` is a parameter this struct visibly uses;
# without it the parameter appears nowhere in the struct body, reads as
# removable, and removing it silently restores a use-after-free. It costs one
# pointer on a value constructed once per process. Do not delete either one, and
# do not return the bare `ErasedHook`.
#
# The field is not redundant with the `MutCarriedHandle` inside
# `IdleIndexContext`: that one is consumed into the erased home at install and
# vanishes from the caller's type environment, which is the hole this struct
# closes.
#
# Two plain fields: the `ErasedHook` and a single concrete-origin `Pointer` (the
# `MutCarriedHandle` shape). No wildcard origin, no heap, nothing to free.
# -----------------------------------------------------------------------------


struct InstalledIndexHook[
    Storage: CloneableConditionalWriteStore,
    engine_origin: Origin[mut=True],
](Movable, Copyable, Deinitable):
    """The install return: the `ErasedHook` plus the engine borrow that makes
    the hook's lifetime dependency visible to the compiler."""

    var hook: ErasedHook
    # The keepalive. Never dereferenced; the fire path reaches the engine through
    # the context's own baked handle. See the block above for what is and is not
    # load-bearing here.
    var _engine_keepalive: MutCarriedHandle[SharedEngine, Self.engine_origin]

    def __init__(
        out self,
        hook: ErasedHook,
        engine: MutCarriedHandle[SharedEngine, Self.engine_origin],
    ):
        self.hook = hook
        self._engine_keepalive = engine.copy()


# -----------------------------------------------------------------------------
# flush_all_pending_via_hook — the owner's graceful-shutdown and flush-tick
# entry. It rebuilds the context from the hook's context home (the install
# return), runs the final flush, and disowns it (the home is freed by
# `drop_installed_hook`). Runs on the main thread after the join.
# -----------------------------------------------------------------------------


def flush_all_pending_via_hook[
    Storage: CloneableConditionalWriteStore,
    engine_origin: Origin[mut=True],
](
    installed: InstalledIndexHook[Storage, engine_origin], num_workers: Int
) raises -> Int:
    """Rebuild the context from the hook's context home (through an
    OwnedPointer wrap), run `flush_all_pending`, then
    `unsafe_take_allocation().unsafe_leak()` to disown it (the home is freed once
    by `drop_installed_hook`, not here). The public surface is pointer-free.

    Takes the `InstalledIndexHook`, not the bare `ErasedHook`: this call drains
    the engine, so it must be a use that keeps the engine alive, and only a
    parameter whose type names `engine_origin` is.

    DO NOT "simplify" the disown to `dealloc(allocation^)`.
    `unsafe_take_allocation()` returns a linear `Allocation[T]` that must be
    consumed, and the compiler's own remediation text names `dealloc(allocation^)`
    first. `dealloc` is wrong at every disown site in this file: the context is a
    long-lived home that `_drop_idle_hook_for` frees exactly once after the join,
    so freeing it here is a double free on a live worker context. It compiles
    clean, and a mismatched-layout `dealloc` survives tens of thousands of
    iterations, so it does not announce itself. `unsafe_leak()` relinquishes this
    owner's free and hands the bytes on without freeing them."""
    # SAFETY: `ctx_raw` is the home `installable_hook_home` allocated for an
    # `IdleIndexContext[Storage, engine_origin]`; the bitcast recovers its
    # concrete type. The home is live until `drop_installed_hook`, which the
    # caller runs after this call.
    var ctx_typed = installed.hook.ctx_raw.bitcast[
        IdleIndexContext[Storage, engine_origin]
    ]()
    # SAFETY: the OwnedPointer is a borrow-in-disguise: it is disowned with
    # `unsafe_leak()` below before it can free the home.
    var owned = OwnedPointer[IdleIndexContext[Storage, engine_origin]](
        unsafe_from_raw_pointer=ctx_typed
    )
    var total = owned[].flush_all_pending(num_workers)
    var _disowned = owned^.unsafe_take_allocation().unsafe_leak()
    return total


# -----------------------------------------------------------------------------
# _build_and_publish_split — the transpose, build cheap L0, publish unit, a free
# function taking ALL config by value (it never reads a struct field). It is the
# same body as L0BuildTask.run. Both the worker-thread trampoline (which reads
# the config off the first-level `owned[]` borrow and passes it by value) and
# the main-thread flush methods use it.
# -----------------------------------------------------------------------------


def _build_and_publish_split[
    Storage: CloneableConditionalWriteStore
](
    var views: List[LogRecordView],
    worker_id: UInt16,
    var node_id: String,
    var meta_root: String,
    var index: String,
    store: Storage,
    var uuid: InlineArray[UInt8, 16],
    retry: RetryPolicy,
) raises -> Int:
    """Transpose, build the cheap L0 split, and publish it into the worker's
    drain sub-lineage. Returns the docs published.

    A free function with the config passed by value (no struct-field read): the
    worker-thread trampoline rebuilds the context from the erased context home
    and reads the config off the first-level `owned[]` borrow, threading every
    config value as a plain owned argument. It is shared verbatim by the
    worker-thread trampoline and the main-thread flush methods."""
    var n = len(views)
    if n == 0:
        return 0
    # (1) transpose the OWNED views -> the typed log-index batch.
    var batch = log_views_to_record_batch(views)
    # (2) build the cheap L0 posting split.
    var schema = log_index_schema()
    var seg = L0SegmentBuilder(schema^)
    seg.add_batch(batch^)
    var split_bytes = seg.serialize_split_bytes(LOG_INDEX_TEXT_FIELD, uuid)
    var blen = Int64(len(split_bytes))
    # (3) PUBLISH: the split PUT first (an idempotent, content-addressed orphan
    #     on a crash before the CAS), then the metastore CAS-append (the
    #     linearization point that makes it searchable), into the per-worker
    #     drain shard.
    var object_key = _object_key_for_uuid(meta_root, index, uuid)
    _ = store.put(Path.parse(object_key), split_bytes)
    var drain_shard = make_shard_id(node_id^, Int(worker_id), String("drain"))
    var lineage = shard_manifest_prefix(meta_root.copy(), drain_shard)
    var manifest = CasManifestStore[Storage](store.clone(), lineage^, retry)
    var metastore = SearchMetastore[Storage](manifest^, index.copy())
    var summary = make_split_summary(
        uuid^,
        Int64(n),
        blen,
        Int64(0),  # min_doc_id (per-split base 0)
        Int64(n) - Int64(1),  # max_doc_id
        index^,
        LOG_INDEX_TEXT_FIELD,
        object_key,
    )
    _ = metastore.publish(summary^)
    return n


# -----------------------------------------------------------------------------
# _run_idle_hook_for[Storage, engine_origin] — the monomorphized run trampoline
# (the producer side of the erasure boundary). The worker calls it blind
# through the plain function pointer; it rebuilds the concrete IdleIndexContext
# from the erased byte pointer and fires one bounded drain, build and publish.
# -----------------------------------------------------------------------------


def _run_idle_hook_for[
    Storage: CloneableConditionalWriteStore,
    engine_origin: Origin[mut=True],
](ctx_raw: HookCtxPtr, worker_id: UInt16) raises -> None:
    """The monomorphized fire trampoline. `ctx_raw` is the erased (opaque
    `HookCtxPtr`) handle to the `IdleIndexContext[Storage, engine_origin]` home
    the owner holds; rebuild the concrete typed view, read the config off it at
    this scope, drain the worker's ring through the context's baked engine
    handle, and call the free `_build_and_publish_split` with the config by
    value.

    The drain reaches the engine through the context's baked
    `MutCarriedHandle.get_mut()`, a concrete-mutable-origin pointer the compiler
    tracks.

    Everything is read here, not in a `mut self` method: a `mut self` method
    called through the rebuilt pointer reads the context's heap-owning field
    interiors incoherently (the field is coherent at this trampoline scope, but
    empty inside the method), including the baked engine handle. So every field,
    the config and the baked engine handle alike, is read at this scope, the
    drain goes through `owned[]._engine.get_mut()` here, and the config is
    threaded into the free `_build_and_publish_split` as plain owned values.

    SAFETY (the type-erasure handle rebuilt on the producer side): `ctx_raw`
    targets a long-lived allocation the owner holds and frees after the join. The
    bitcast recovers the concrete typed view; no UnsafePointer is stored or
    crosses any signature boundary beyond the opaque `HookCtxPtr`."""
    # Rebuild the context the way the spawner rebuilds a task header: bitcast the
    # erased handle to the concrete type, wrap it in an OwnedPointer (a tracked
    # origin, so reads of heap-owning fields are coherent), read the config and
    # drain through `owned[]` at this scope, then
    # `unsafe_take_allocation().unsafe_leak()` to disown it. The context is the
    # long-lived home, freed ONCE by the drop trampoline after the join, not
    # here. Not `dealloc(allocation^)`: see `flush_all_pending_via_hook`.
    # SAFETY: see the docstring; `ctx_raw` is a live
    # `IdleIndexContext[Storage, engine_origin]` home.
    var ctx_typed = ctx_raw.bitcast[
        IdleIndexContext[Storage, engine_origin]
    ]()
    # SAFETY: disowned with `unsafe_leak()` on every exit path below, so the
    # OwnedPointer never frees the home.
    var owned = OwnedPointer[IdleIndexContext[Storage, engine_origin]](
        unsafe_from_raw_pointer=ctx_typed
    )
    var wid = Int(worker_id)
    # Drain through the baked engine handle at this scope (not inside a
    # `mut self` method, which reads the engine incoherently).
    if not owned[]._engine.get_mut().worker_ring_nonempty(wid):
        var _d0 = owned^.unsafe_take_allocation().unsafe_leak()
        return
    var views = owned[]._engine.get_mut().drain_worker_to_records(wid, DRAIN_CAP)
    if len(views) == 0:
        var _d1 = owned^.unsafe_take_allocation().unsafe_leak()
        return
    # Read the config and mint the uuid at this scope, then thread them into the
    # free function as plain owned values.
    var node_id = owned[]._node_id.copy()
    var meta_root = owned[]._meta_root.copy()
    var index = owned[]._index.copy()
    var store = owned[]._store.clone()
    var retry = owned[]._retry
    var uuid = owned[].next_uuid(worker_id)
    var _disowned = owned^.unsafe_take_allocation().unsafe_leak()
    _ = _build_and_publish_split[Storage](
        views^, worker_id, node_id^, meta_root^, index^, store, uuid^, retry
    )


def _drop_idle_hook_for[
    Storage: CloneableConditionalWriteStore,
    engine_origin: Origin[mut=True],
](ctx_raw: HookCtxPtr):
    """The drop trampoline: frees the context home (allocated at install through
    `installable_hook_home`). It rebuilds the OwnedPointer over the raw context
    allocation and lets it drop, which runs the `IdleIndexContext` destructor and
    frees the allocation in one shot. Called ONCE by the owner after
    `runtime.shutdown()` joins all workers, never by a worker."""
    # SAFETY: `ctx_raw` is the home `installable_hook_home` allocated for this
    # context type; this is the single owner that frees it, after the join.
    var ctx_typed = ctx_raw.bitcast[
        IdleIndexContext[Storage, engine_origin]
    ]()
    # SAFETY: the OwnedPointer takes ownership of the home and frees it on drop.
    var owned = OwnedPointer[IdleIndexContext[Storage, engine_origin]](
        unsafe_from_raw_pointer=ctx_typed
    )
    _ = owned^  # drop -> destructor + free, exactly once.


def drop_installed_hook[
    Storage: CloneableConditionalWriteStore,
    engine_origin: Origin[mut=True],
](installed: InstalledIndexHook[Storage, engine_origin]):
    """Pointer-free public drop entry: free the context home the hook borrows.
    Routes to the typed `_drop_idle_hook_for` over the hook's context handle.
    Called ONCE by the owner after the join.

    Takes the `InstalledIndexHook` so that the engine is still alive here, at the
    last point anything can reach the context. Passing the bare `ErasedHook`
    would let the engine die at the emit, the defect `InstalledIndexHook` exists
    to make impossible."""
    _drop_idle_hook_for[Storage, engine_origin](installed.hook.ctx_raw)


# -----------------------------------------------------------------------------
# install_native_index_idle_hook — the install entry. The owner calls it once at
# setup: it consumes the context into a long-lived raw home (through
# `installable_hook_home`), builds the `ErasedHook` (monomorphized fire and drop
# trampolines), and pushes it onto every worker. It returns the
# `InstalledIndexHook` (pointer-free) that the owner must hold and later free
# through `drop_installed_hook` after the join.
# -----------------------------------------------------------------------------


def install_native_index_idle_hook[
    S: WakerSink & Movable & Deinitable,
    Storage: CloneableConditionalWriteStore,
    engine_origin: Origin[mut=True],
](
    mut runtime: PerCoreAsyncRuntime[S],
    var ctx: IdleIndexContext[Storage, engine_origin],
) -> InstalledIndexHook[Storage, engine_origin]:
    """Install the native-index idle hook onto every worker of `runtime`.

    The public API is pointer-free: it takes the typed `IdleIndexContext` (which
    already carries the baked engine handle) and returns an `InstalledIndexHook`
    (the `ErasedHook` plus the engine borrow) that the owner holds and later
    frees through `drop_installed_hook` after the join.

    Ownership: the context is consumed into a long-lived raw home
    (`installable_hook_home` is `alloc` plus `init_pointee_move`), and the worker
    rebuilds it through `OwnedPointer(unsafe_from_raw_pointer=)`. The
    `ErasedHook` the owner holds borrows that home; the owner frees it through
    `drop_installed_hook[Storage, engine_origin]` after `runtime.shutdown()`
    joins all workers. There is no second owner, so no double free.

    The monomorphized `_run_idle_hook_for[Storage, engine_origin]` and
    `_drop_idle_hook_for[Storage, engine_origin]` are produced here, on the side
    that names the concrete Storage and engine_origin; the worker invokes the
    resulting function pointers blind."""
    # Take a COPY of the context's baked engine handle BEFORE the context is
    # consumed into the erased home. It is plain data and Copyable, and its
    # origin is the engine's, not the context's, so it survives the move.
    # Carrying it in the return type is what keeps the engine alive. (This is why
    # the install needs no extra parameter: the caller already named the engine
    # when it built `ctx`.)
    var engine_handle = ctx._engine.copy()
    var ctx_raw = installable_hook_home[
        IdleIndexContext[Storage, engine_origin]
    ](ctx^)
    # Bind the parametrized trampolines to `var`s first so they coerce into the
    # `ErasedHook` function-pointer fields, as the spawner does for its task
    # trampolines.
    var fire_trampoline = _run_idle_hook_for[Storage, engine_origin]
    var drop_trampoline = _drop_idle_hook_for[Storage, engine_origin]
    var hook = ErasedHook(
        ctx_raw=ctx_raw,
        fire_fn=fire_trampoline,
        drop_fn=drop_trampoline,
    )
    runtime.install_idle_hook(hook)
    # Return the hook WITH the engine borrow. `engine_handle` names the same
    # engine the caller baked into `ctx`; carrying it out puts `engine_origin`
    # into the returned value's type, which is the only reason the engine
    # outlives the hook. See the struct's header.
    return InstalledIndexHook[Storage, engine_origin](hook, engine_handle)
