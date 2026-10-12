# =============================================================================
# ⭐⭐ THE CONNECTOR VTABLE DOOR — `register_scan_kind` grows function pointers
# =============================================================================
#
# THE QUESTION THIS FILE ANSWERS (maintainer, 2026-09-06):
#   *"we're going to put everything into the engine, but let's say I want to
#    use sqs source. From a customer perspective, what do I do? Do I lose
#    performance with this composability as opposed to stuffing everything
#    into the big .so?"*
#
# WHAT THE CUSTOMER DOES: export SIX C functions from their own `.so`, fill a
# `KomiraScanVTable`, hand it to the engine once. Nothing else. The engine
# never names their types, never links their library, and a user who does not
# call the door loads none of their code.
#
# ⚠ THE PRIOR STATE, AND WHY THIS FILE EXISTS.
# `komira_sdk_ctx_register_scan_kind` (`komira_so/komira_abi.mojo:1921`) carries
# name + orientation + snapshot_policy + required_params and **ZERO FUNCTION
# POINTERS**. `komira_abi.mojo` states the consequence in its own words: *"A
# FOREIGN KIND PLANS BUT DOES NOT EXECUTE"* — the binding is enough to build,
# type, EXPLAIN and cache-key a plan, and not enough to pull a morsel. This is
# the missing callback channel.
#
# =============================================================================
# THE FIVE CONSTRAINTS THE DOOR IS DESIGNED AGAINST (all measured, not assumed)
# =============================================================================
#
# 1. ⛔ `abi("C")` REFUSES `raises`. Every entry is NON-RAISING with an out-param
#    status. `VTableMorselSource.next_morsel` is the ONE raising function, and
#    it raises on the connector's STATUS CODE, translated at this boundary.
#
# 2. ⛔ `abi("C")` REFUSES PARAMETRIC FUNCTIONS. Every signature is monomorphic
#    over an OPAQUE HANDLE (`UnsafePointer[NoneType]`) — never over a Komira
#    type. an internal tool measured the alternative: a door
#    naming a VENDOR TYPE fails the consumer with `unable to locate module
#    'vendorlib'`; the opaque-handle door compiles, links and runs with no
#    vendor package reachable. THE SIGNATURE'S TYPE VOCABULARY DECIDES WHAT A
#    USER PULLS IN.
#
# 3. ⭐ THE UNIT IS A MORSEL, NOT A ROW. `next_morsel` returns a BATCH of a few
#    thousand rows, so the indirect call is paid once per few-thousand rows,
#    not per row. That is the whole performance answer and it is MEASURED, not
#    argued — see an internal tool.
#
# 4. ⛔ THE CONCURRENCY CONTRACT IS IMMUTABLE-BORROW. `MorselSourceImpl.
#    next_morsel` takes `self`, NOT `mut self`, and parallel workers pull
#    through one shared source. See `_CONCURRENCY` below — the door cannot
#    ENFORCE this on a foreign connector and says so in the loudest terms
#    available, because it is a footgun we would otherwise ship silently.
#
# 5. ⭐ THE HOOKS ARE SETUP, NOT HOT PATH. `set_projection` /
#    `set_pushed_predicate` run ONCE inside `apply_source_hooks` BEFORE the
#    first `next_morsel`. They cross the seam at a cost that rounds to zero
#    per query. PUSHDOWN IS WHERE SCAN PERFORMANCE LIVES, so this is the half
#    that matters most, and `HOOKS_CONSUMED_AT_CONSTRUCTION = False` is the
#    mode this door picks — see `_HOOK_MODE` below for why.
#
# =============================================================================
# _CONCURRENCY — ⛔ THE DOOR CANNOT ENFORCE THIS, AND THAT IS A REAL FOOTGUN
# =============================================================================
#
# `MorselSourceImpl`'s contract: *"`next_morsel` takes `self` (immutable
# borrow) ... every parallel worker calls `source.next_morsel(wid)` through a
# shared immutable borrow"*, and *"Concrete sources push mutable shared state
# (e.g. the RG cursor) behind `Atomic[...]`"*.
#
# `VTableMorselSource` upholds its half EXACTLY: its `next_morsel` is an
# immutable borrow, and the only state it mutates is an `Atomic` morsel
# counter on a heap slab — the same shape `MockMorselSource` and
# `ParquetMorselSource` use.
#
# ⛔ BUT THE CONNECTOR'S HALF IS BEYOND THE TYPE SYSTEM. `komira_scan_next` is
# a C function pointer taking a `void*`. C HAS NO `mut`. A connector whose
# handle holds a plain `int cursor;` advanced with `s->cursor++` IS A DATA RACE
# under parallel workers, it will compile, it will link, it will pass a
# single-threaded test, and NOTHING IN THIS FILE CAN DETECT IT. That is the
# honest statement, and it is the cost of a C seam.
#
# THREE MITIGATIONS, in decreasing strength, all implemented below:
#
#   (a) THE CONNECTOR DECLARES ITS OWN THREAD-SAFETY, and a connector that
#       does not is SERIALISED rather than trusted. `KOMIRA_SCAN_CAP_MT_SAFE`
#       (bit 0 of `capabilities`) is OPT-IN: absent, `VTableMorselSource`
#       takes a lock around `next` so a single-threaded connector is CORRECT
#       BY DEFAULT and merely slower. FAIL-SAFE, not fail-fast: a customer who
#       reads no documentation gets right answers.
#   (b) `worker_id` IS PASSED THROUGH, so a connector that wants per-worker
#       state can key on it with no shared mutation at all — the shape we
#       recommend and the shape the example connector uses.
#   (c) THE COST OF (a) IS MEASURED, not assumed. See the bench: the lock is
#       paid once per MORSEL. If it were per ROW it would be catastrophic;
#       it is not, and the numbers say by how much.
#
# =============================================================================
# _HOOK_MODE — WHY `HOOKS_CONSUMED_AT_CONSTRUCTION = False`
# =============================================================================
#
# `MorselSourceImpl` offers two shapes and a vtable door must pick one.
# This door picks HOOKS-AFTER-CONSTRUCTION (`False`, the default) because the
# two shapes differ in WHO OWNS THE ORDERING, and only one of them survives a
# C seam:
#
#   * caps-at-ctor (`True`) requires the ENGINE to build the source with a
#     `SourceCapabilityConfig` in hand. Across a C seam the engine does not
#     BUILD the connector's source — the connector's `open` does — so the
#     engine would have to marshal the whole capability bundle into `open`'s
#     signature. Every future capability then changes `open`'s ARITY, i.e. an
#     ABI BUMP PER CAPABILITY. That is the growth order this whole design
#     exists to avoid.
#   * hooks-after-construction (`False`) makes each capability its OWN thunk
#     slot, gated by its OWN bit in `capabilities()`. A connector that does
#     not implement one leaves the bit CLEAR and the engine never reads the
#     slot. `open`'s arity never changes.
#
# ⇒ THE CAPABILITY BIT IS THE PRESENCE DECLARATION, and it only works in the
#   hooks-after-construction shape.
#
# ⛔ AND THE HONEST LIMIT OF THAT: the vtable is passed BY VALUE, so APPENDING
#   a slot still changes the struct's size and needs a
#   `KOMIRA_SCAN_VTABLE_ABI_VERSION` bump — refused by name at `open`, never a
#   short read of a foreign struct. Making appends free needs the vtable passed
#   BY POINTER with a `struct_size` field the engine bounds every slot read
#   against (the Arrow C Data / `sockaddr` shape). That is a one-field change to
#   this signature and it is NOT DONE. Do not read "the Nth connector is free"
#   as "the Nth CAPABILITY is free": the first is true today, the second wants
#   that field.
#
# =============================================================================
# ⭐⭐ WHY THIS IS THE PAYLOAD CHANNEL THE SESSION COULD NOT OTHERWISE HAVE
# =============================================================================
#
# `_SdkAbiSession.scan_kinds` (`komira_so/komira_abi.mojo:842`) states the
# asymmetry that has blocked foreign-source EXECUTION:
#
#   *"A DESCRIPTOR REGISTERED THROUGH THIS ABI SURVIVES ACROSS CALLS. A PAYLOAD
#    HANDLE MINTED THROUGH IT CANNOT — the registry that minted it is destroyed
#    when the entry returns."*
#
# ⭐ A VTABLE IS NEITHER. It is ten machine words of POD — one `void*` and nine
# code pointers — whose LIFETIME THE CONNECTOR OWNS. It is exactly as
# session-parkable as a `ScanKindDescriptor`, for the same reason
# (`ScanKindRegistry` is Movable pure data), and it does NOT need the
# non-Movable `EngineContext` that a `ScanRegistry` payload handle does. So the
# thing that could not cross — the DATA — stops needing to: the engine stops
# being handed bytes and starts being handed A WAY TO ASK FOR THEM.
#
# ⇒ That is why this is the shape that unblocks `komira_abi.mojo`'s *"A FOREIGN
#   KIND PLANS BUT DOES NOT EXECUTE"*, and it is why the C entry point
#   (`komira_sdk_ctx_register_scan_vtable`) is a small edit rather than a
#   campaign. It is NOT YET WRITTEN — see the residual list below.
#
# =============================================================================
# THE LIFETIME CONTRACT THE CUSTOMER MUST UPHOLD — three sentences, all binding
# =============================================================================
#
# 1. THE VTABLE STRUCT IS BORROWED FOR THE DURATION OF THE REGISTRATION CALL
#    ONLY. `VTableMorselSource.__init__` COPIES it into engine-owned storage,
#    so the customer may build it on their own stack and drop it immediately
#    after. (At the C boundary the same struct is passed by POINTER and copied
#    identically.)
# 2. THE HANDLE MUST OUTLIVE `close`. The engine calls `close(handle)` from the
#    source's destructor and never touches it after.
# 3. A BATCH'S BUFFERS MUST LIVE ONLY UNTIL `release` RETURNS. The engine
#    COPIES every byte it needs before calling `release`, so one reused scratch
#    buffer per worker is legal and is what the example connectors do.
#
# ⛔ AND THE ONE THAT IS NOT ENFORCEABLE: **a stack local whose address crosses
# an `abi("C")` call is not reliably observed on Mojo.** Measured
# 2026-09-06 in an internal tool, BOTH directions, with
# a green build and a silently wrong answer each time. Every C-ABI out-param
# and every C-ABI struct passed by pointer in this door lives on the HEAP; see
# `_VtCounters.slots`.
#
# =============================================================================
# WHAT THIS DOOR DOES **NOT** DO — say it here, not in a footnote
# =============================================================================
#
# * ⛔ THE v1 PAYLOAD IS INT64 COLUMNS, NON-NULL. `KomiraScanBatch` carries an
#   array of `int64*`. Widening to the full Arrow type set is a TYPE-CODE
#   TABLE on `KomiraScanBatch` (add `col_types: int32*` + a validity pointer
#   array) — mechanical, and NOT DONE. Do not read this file as "connectors
#   can return anything".
# * ⛔ THE PREDICATE THAT CROSSES IS A LOWERED `col <cmp> int64-literal`.
#   `set_pushed_predicate` takes an `ExprId`; `_lower_predicate` resolves it
#   through the ExprPool and pushes ONLY that shape. Anything else is NOT
#   pushed — the engine keeps the filter above the scan, which is the correct
#   conservative answer, not a wrong one.
# * ⛔ THE C ENTRY POINT IS NOT WRITTEN. `komira_sdk_ctx_register_scan_vtable`
#   does not exist yet, so this door is reachable from inside the engine (and
#   across two shared libraries in an internal tool)
#   but NOT from `komira.so`'s 56-symbol C surface. Do not read this file as
#   "a customer can register a source through the shipped `.so` today".
# * ⛔ NO PUSHDOWN GATE BITS RIDE `register_scan_kind` YET. That is
#   `komira_abi.mojo`'s named residual and it is unchanged by this file. The
#   capability bitmask here is the source's SELF-DESCRIPTION at the vtable;
#   plumbing it up into `PushdownGate` is the next edit and it is ONE change
#   to ONE existing signature.
# =============================================================================

from komira_atomic_alias import AtomicI8, AtomicI64
from std.memory import alloc, UnsafePointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column, HeapRegion
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import (
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    EXPR_BINARY_OP,
    EXPR_COL_IDX,
    EXPR_LITERAL,
)
from komira_plan_expr.expr_pool import ExprPool
from komira_plan_expr.expr_id import ExprId
from komira_scan_source.source_capabilities import SourceCapabilities

from .morsel import Morsel
from .morsel_source import MorselSourceImpl


# =============================================================================
# THE C VOCABULARY. Every one of these is a machine word or a pointer to one;
# not one of them names a Komira type.
# =============================================================================

@always_inline
def _vt_null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer. Mojo removed the null ctor; this is the
    tree's established replacement (`komira_arrow_ipc/c_data_interface.mojo`
    `_null_ptr`), copied here rather than imported so this file's `-I` closure
    stays the core packages plus `komira_morsel`.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer and `None` is the all-zero bit pattern. No `unsafe_from_address`.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


comptime KOMIRA_SCAN_VTABLE_ABI_VERSION: Int32 = 1
"""Bumped ONLY when an EXISTING slot's signature changes. Appending a slot at
the end and NULL-checking it is not a bump — see `_HOOK_MODE`."""

comptime CScanOpaque = UnsafePointer[NoneType, MutUntrackedOrigin]
comptime CScanI64Ptr = UnsafePointer[Int64, MutUntrackedOrigin]
comptime CScanI32Ptr = UnsafePointer[Int32, MutUntrackedOrigin]

# ---- status codes (returned by every fallible entry) ------------------------
comptime KOMIRA_SCAN_OK: Int32 = 0
comptime KOMIRA_SCAN_EOF: Int32 = 1
comptime KOMIRA_SCAN_ERR: Int32 = -1
comptime KOMIRA_SCAN_ERR_UNSUPPORTED: Int32 = -2

# ---- capability bitmask (returned by the `caps` slot) -----------------------
comptime KOMIRA_SCAN_CAP_MT_SAFE: Int64 = 1
"""⭐ THE MOST IMPORTANT BIT. Set it and the engine pulls from N workers
concurrently. LEAVE IT CLEAR and the engine SERIALISES the pulls for you. It
is opt-IN so that a connector written without reading a word of documentation
is CORRECT, and merely slower."""
comptime KOMIRA_SCAN_CAP_PROJECTION: Int64 = 2
comptime KOMIRA_SCAN_CAP_PREDICATE: Int64 = 4

# ---- lowered predicate ops (what actually crosses the seam) -----------------
comptime KOMIRA_SCAN_CMP_EQ: Int32 = 0
comptime KOMIRA_SCAN_CMP_LT: Int32 = 1
comptime KOMIRA_SCAN_CMP_LE: Int32 = 2
comptime KOMIRA_SCAN_CMP_GT: Int32 = 3
comptime KOMIRA_SCAN_CMP_GE: Int32 = 4


@fieldwise_init
struct KomiraScanBatch(Copyable, Movable):
    """The flat columnar payload a connector hands back. POD, C layout.

    ⛔ v1: EVERY COLUMN IS `int64`, NON-NULL. `col_ptrs[i]` is an
    `const int64_t*` with `n_rows` elements. Widening is a type-code array
    plus a validity-pointer array on this struct; see the file header.

    `token` is the CONNECTOR'S OWN release cookie — an index, a pointer, a
    generation, whatever it likes. The engine treats it as opaque and hands it
    straight back to `release`. It exists so the connector can own the buffer
    lifetime without the engine ever calling `free` on foreign memory.
    """

    # SAFETY (safety model §7.11 / §6 FFI carve-out):
    #   (a) WHY A WILDCARD IS LOAD-BEARING: this is a C-ABI struct whose bytes
    #       a FOREIGN producer writes. `col_ptrs` points into the CONNECTOR's
    #       memory, in another shared library, with a lifetime this type system
    #       has no way to name. It is the FFI boundary, not a Komira allocation.
    #   (b) NON-NULL WINDOW: only between a `next()` that returned
    #       `KOMIRA_SCAN_OK` and the matching `release()`. `next_morsel` zeroes
    #       all four fields before every call, so a connector that returns OK
    #       without filling them yields `n_cols = 0` (an empty batch), never a
    #       stale pointer from the previous morsel.
    #   (c) OWNING? NO. Non-owning, borrowed. The engine COPIES every byte it
    #       needs inside `_materialize` and NEVER retains the pointer past
    #       `release` -- which is the whole reason `_materialize` copies rather
    #       than wrapping, and the bug an internal tool falsifies.
    #   (d) TEARDOWN: nothing to retire. The engine allocated none of it; the
    #       connector reclaims it in `release`.
    var n_rows: Int64
    var n_cols: Int64
    var col_ptrs: UnsafePointer[CScanI64Ptr, MutUntrackedOrigin]
    var token: Int64


comptime CScanBatchPtr = UnsafePointer[KomiraScanBatch, MutUntrackedOrigin]

# ---- the six thunk types ----------------------------------------------------
# ⛔ Not one of these is `raises` (`abi("C")` refuses it) and not one is
# parametric (`abi("C")` refuses that too). Status is the return value.
comptime ScanOpenThunk = def (CScanOpaque) abi("C") thin -> Int32
comptime ScanNextThunk = def (CScanOpaque, Int32, CScanBatchPtr) abi("C") thin -> Int32
comptime ScanReleaseThunk = def (CScanOpaque, CScanBatchPtr) abi("C") thin -> None
comptime ScanCloseThunk = def (CScanOpaque) abi("C") thin -> None
comptime ScanCapsThunk = def (CScanOpaque) abi("C") thin -> Int64
comptime ScanSetProjThunk = def (CScanOpaque, CScanI32Ptr, Int32) abi("C") thin -> Int32
comptime ScanSetPredThunk = def (CScanOpaque, Int32, Int32, Int64) abi("C") thin -> Int32
comptime ScanRowsHintThunk = def (CScanOpaque) abi("C") thin -> Int64


@fieldwise_init
struct KomiraScanVTable(Copyable, Movable):
    """⭐ THE WHOLE CUSTOMER-FACING SURFACE. One handle + eight code pointers.

    The customer fills this, hands it to the engine once, and is done. The
    engine's side of the seam is `VTableMorselSource` below.

    ⚠ SIX SLOTS ARE REQUIRED (`open`/`next`/`release`/`close`/`caps`/
    `rows_hint`); `set_projection` and `set_predicate` are read ONLY when the
    connector's `caps` bitmask sets the matching bit. A connector that does not
    implement a capability leaves the bit clear and MAY point the slot at any
    stub — the engine never calls it.

    ⛔ A CONNECTOR THAT SETS A BIT AND SUPPLIES A NULL SLOT CRASHES, and the
    door cannot tell (Mojo has no null test on a `def (...) thin` — the
    type is non-nullable by construction). The bit IS the promise. Said plainly
    because it is a footgun, not because it is acceptable.
    """

    var abi_version: Int32
    var handle: CScanOpaque
    var open: ScanOpenThunk
    var next: ScanNextThunk
    var release: ScanReleaseThunk
    var close: ScanCloseThunk
    var caps: ScanCapsThunk
    var set_projection: ScanSetProjThunk
    var set_predicate: ScanSetPredThunk
    var rows_hint: ScanRowsHintThunk


# =============================================================================
# The engine side. `_VtCounters` mirrors `MockMorselSource._MockCounters` /
# `ParquetMorselSource`'s heap `_Counters` slab: Atomic is non-Movable in
# Mojo, so the mutable state lives on the heap behind a pointer and the
# outer struct stays Movable.
# =============================================================================


comptime _VT_MAX_WORKERS: Int = 128
"""Matches `batch_morsel_source._MAX_WORKERS` / the parquet source's
`_MAX_WORKERS_FOR_SPLIT`: the scheduler's worst-case worker id."""

comptime _VT_SLOT_CELLS: Int = _VT_MAX_WORKERS + 1
"""Cells in `_VtCounters.slots`: one per in-range worker, plus the OVERFLOW
cell at index `_VT_SLOT_CELLS - 1` that every worker id outside
`[0, _VT_MAX_WORKERS)` shares. Both the allocation and the overflow index use
this one constant so they cannot drift apart: an overflow index past the
allocation would write one cell past the end, which no test here can see."""


struct _VtCounters:
    """Heap slab: the morsel id counter, the SERIALISING lock, and the
    PER-WORKER out-param slots.

    `lock` is a test-and-set spin flag held by every call on a connector that
    did NOT set `KOMIRA_SCAN_CAP_MT_SAFE`, and by every call on the shared
    OVERFLOW slot cell (a worker id outside `[0, _VT_MAX_WORKERS)`) whatever
    the connector declared. It is `int8` for the same reason the cancel
    flag is (`morsel_source.mojo`: Mojo's LLVM backend refuses atomic
    loads on i1)."""

    var next_id: AtomicI64
    var lock: AtomicI8
    var eof: AtomicI8
    # ⛔⛔ THE OUT-PARAM SLOT MUST NOT BE A STACK LOCAL. MEASURED 2026-09-06 in
    # an internal tool: an engine that declared
    # `var cb = KomiraScanBatch(0, 0, null, 0)` and handed
    # `UnsafePointer(to=cb)` to an `abi("C")` callee BUILT GREEN AND READ BACK
    # ITS OWN INITIALISER -- rows=0, checksum=0, while the connector's own
    # counter said it had been called six times and filled five batches. The
    # loads were forwarded from the stores across the foreign call. Moving the
    # slot to the heap fixed it; the same shape bit the CONNECTOR side too (its
    # stack-built vtable read back a wrong `abi_version`, so the engine refused
    # with -1).
    #
    # ⚠ AND IT IS PER WORKER, NOT ONE SLOT. `next_morsel` is an IMMUTABLE
    # borrow that N workers call concurrently; one shared out-param slot would
    # be a data race the door itself introduced -- exactly the class it exists
    # to keep the connector out of. Index `_VT_SLOT_CELLS - 1` is the OVERFLOW
    # cell every worker id outside `[0, _VT_MAX_WORKERS)` shares; a call on it
    # always holds `lock`, even on an MT-safe connector (see `next_morsel`).
    # SAFETY (safety model §7.11):
    #   (a) WHY A WILDCARD: `KomiraScanBatch` is a C-ABI POD whose address is
    #       handed to a foreign callee. It CANNOT be a `Slab[T]`/`OwnedPointer`
    #       whose address the engine only borrows internally -- and it cannot
    #       be a stack local at all, per the measured finding above.
    #   (b) NON-NULL WINDOW: from `VTableMorselSource.__init__` to `__del__`.
    #       Never null in between; there is no "between dispatches" state.
    #   (c) OWNING? YES, and it is a FIXED-SIZE POD ARRAY of
    #       `_VT_SLOT_CELLS` scratch cells -- no `List`, `String`,
    #       `OwnedPointer` or nested heap in the element type, so it is not the
    #       gap6 shape. The ban targets owning pointers to HEAP-OWNING
    #       elements; every field of `KomiraScanBatch` is a machine word.
    #   (d) TEARDOWN: freed in `VTableMorselSource.__del__` immediately before
    #       the counters slab itself, and the source is the only holder.
    var slots: UnsafePointer[KomiraScanBatch, MutUntrackedOrigin]


struct VTableMorselSource(MorselSourceImpl):
    """⭐⭐ A `MorselSourceImpl` whose body is EIGHT C FUNCTION POINTERS.

    Every other conformer in this repo is monomorphized into the executor at
    the USER's compile time. This one is the seam: `execute[S, K]` still
    monomorphizes over `S = VTableMorselSource`, so the EXECUTOR is fully
    specialised — what is NOT inlined is the connector's own body, which lives
    in a different `.so` and could never have been inlined anyway.

    ⇒ THAT IS THE PRECISE SHAPE OF THE PERFORMANCE ANSWER: the engine keeps
      its specialisation; the connector loses the inlining of ITS OWN read
      loop into the engine's. Measured in an internal tool.

    CONCURRENCY: `next_morsel` is an immutable borrow, exactly as the trait
    requires; every mutation goes through `_counters`, a heap `Atomic` slab.
    A connector that did not declare `KOMIRA_SCAN_CAP_MT_SAFE` is serialised
    by `_counters[].lock` so it is CORRECT under parallel workers. See
    `_CONCURRENCY` in the file header for what this still cannot enforce.
    """

    comptime HOOKS_CONSUMED_AT_CONSTRUCTION: Bool = False

    var _vt: KomiraScanVTable
    var _schema: Schema
    var _caps: Int64
    var _rows_hint: Int
    var _partitions: Int
    # SAFETY: heap slab holding non-Movable Atomics; allocated in __init__,
    # freed in __del__, never aliased outside this struct. Same shape as
    # `MockMorselSource._counters` and `ParquetMorselSource`'s `_Counters`.
    var _counters: UnsafePointer[_VtCounters, MutUntrackedOrigin]
    # SAFETY: non-owning ExprPool pointer installed by `set_expr_pool`. The
    # framework invariant in `MorselSourceImpl.set_expr_pool` is the lifetime
    # proof: the pool outlives every `next_morsel` reachable from this source.
    var _pool: UnsafePointer[ExprPool, MutUntrackedOrigin]
    var _pushed: Bool

    def __init__(
        out self,
        var vt: KomiraScanVTable,
        var schema: Schema,
        partitions: Int = 1,
    ) raises:
        """Open the connector and take ownership of its handle.

        RAISES if the connector's `abi_version` is not one this engine speaks,
        or if `open` returns a non-zero status. Refusing here — before a single
        morsel — is the whole point of an out-param status code: a version
        mismatch is a NAMED failure at setup, never a wrong answer at execute.
        """
        if vt.abi_version != KOMIRA_SCAN_VTABLE_ABI_VERSION:
            raise Error(
                String("VTableMorselSource: connector declares vtable ABI ")
                + String(Int(vt.abi_version))
                + String("; this engine speaks ")
                + String(Int(KOMIRA_SCAN_VTABLE_ABI_VERSION))
            )
        var rc = vt.open(vt.handle)
        if rc != KOMIRA_SCAN_OK:
            raise Error(
                String("VTableMorselSource: connector open() returned ")
                + String(Int(rc))
            )
        self._caps = vt.caps(vt.handle)
        self._rows_hint = Int(vt.rows_hint(vt.handle))
        self._partitions = partitions
        self._schema = schema^
        # SAFETY: alloc returns uninitialized storage; Atomic is non-Movable so
        # each field is constructed in place through the pointer.
        self._counters = alloc[_VtCounters](1)
        self._counters[].next_id = AtomicI64(0)
        self._counters[].lock = AtomicI8(0)
        self._counters[].eof = AtomicI8(0)
        self._counters[].slots = alloc[KomiraScanBatch](_VT_SLOT_CELLS)
        self._pool = _vt_null_ptr[ExprPool, MutUntrackedOrigin]()
        self._pushed = False
        self._vt = vt^

    def __deinit__(deinit self):
        if Int(self._vt.handle) != 0:
            self._vt.close(self._vt.handle)
        if Int(self._counters) != 0:
            self._counters[].slots.free()
            self._counters.free()

    # ---------------------------------------------------------------- hot path

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        """ONE indirect call per MORSEL — a few thousand rows, not one row.

        ⛔ IF THIS EVER BECOMES ONE INDIRECT CALL PER ROW, THE DESIGN IS WRONG.
        It does not: the connector fills a whole `KomiraScanBatch` per call and
        the per-row work below is a straight-line copy the compiler vectorises,
        with no function pointer in it.
        """
        # EOF is sticky: the single-pass contract (§4.3) says the scheduler
        # must never call next_morsel after seeing None, but a foreign
        # connector must not be able to turn a scheduler bug into a wrong
        # answer, so we latch it.
        if self._counters[].eof.load() != Int8(0):
            return None

        # ⛔ HEAP slot, indexed by worker. See `_VtCounters.slots` -- a stack
        # local here builds green and reads back its own initialiser. A worker
        # id outside the table takes the shared OVERFLOW cell, and therefore
        # the lock, even on an MT-safe connector: two such workers on one cell
        # unlocked would read each other's columns. In-range workers on an
        # MT-safe connector stay lock-free.
        var w = worker_id
        var overflow = w < 0 or w >= _VT_MAX_WORKERS
        if overflow:
            w = _VT_SLOT_CELLS - 1
        var mt_safe = (
            (self._caps & KOMIRA_SCAN_CAP_MT_SAFE) != Int64(0) and not overflow
        )
        if not mt_safe:
            self._acquire()
        var cbp = self._counters[].slots + w
        cbp[].n_rows = Int64(0)
        cbp[].n_cols = Int64(0)
        cbp[].col_ptrs = _vt_null_ptr[CScanI64Ptr, MutUntrackedOrigin]()
        cbp[].token = Int64(0)
        var rc = self._vt.next(self._vt.handle, Int32(worker_id), cbp)

        if rc == KOMIRA_SCAN_EOF:
            if not mt_safe:
                self._release_lock()
            AtomicI8.store(
                UnsafePointer(to=self._counters[].eof)
                .unsafe_bitcast[Scalar[DType.int8]](),
                Int8(1),
            )
            return None
        if rc != KOMIRA_SCAN_OK:
            if not mt_safe:
                self._release_lock()
            raise Error(
                String("VTableMorselSource: connector next() returned status ")
                + String(Int(rc))
                + String(" (worker ")
                + String(worker_id)
                + String(")")
            )

        # ⛔ THE LOCK SPANS next -> materialize -> release, NOT just `next`.
        # A connector that did not promise MT-safety very likely owns ONE
        # scratch buffer, so the engine's READ of that buffer is inside the
        # critical section too. Releasing after `next` alone would hand a
        # second worker the connector while the first is still copying out of
        # it -- a race the door would have introduced, which is precisely the
        # class the serialising arm exists to prevent.
        #
        # ⚠ AND `release` RUNS ON THE ERROR PATH. A materialize that raises
        # must still hand the connector its buffers back, or a foreign
        # connector leaks one batch per engine-side failure.
        var failed = String("")
        var batch = RecordBatch()
        try:
            batch = self._materialize(cbp)
        except e:
            failed = String(e)
        # Hand the buffers back: the connector owns them and the engine has
        # copied every byte it needs. A connector that reuses one scratch
        # buffer per worker is therefore legal.
        self._vt.release(self._vt.handle, cbp)
        if not mt_safe:
            self._release_lock()
        if failed.byte_length() > 0:
            raise Error(failed)

        var mid = Int(self._counters[].next_id.fetch_add(Int64(1)))
        return Morsel(batch^, morsel_id=mid, partition_id=worker_id)

    def _materialize(self, cbp: CScanBatchPtr) raises -> RecordBatch:
        """Copy the connector's flat int64 columns into a `RecordBatch`.

        ⚠ THIS IS A COPY, AND THE COPY IS A REAL COST OF THE COMPOSABLE PATH —
        measured separately from dispatch in the bench, because conflating them
        is how a seam gets blamed for a marshalling bill. It is also the SAFE
        choice: retaining pointers into a foreign `.so`'s memory across a
        morsel boundary is the handle-lifetime bug an internal tool
        exists to falsify.
        """
        var n_rows = Int(cbp[].n_rows)
        var n_cols = Int(cbp[].n_cols)
        if n_cols > self._schema.num_columns():
            raise Error(
                String("VTableMorselSource: connector returned ")
                + String(n_cols)
                + String(" columns; schema declares ")
                + String(self._schema.num_columns())
            )
        var out = RecordBatch()
        for c in range(n_cols):
            var arr = PrimitiveArray[DType.int64].allocate(n_rows)
            var dst = arr._typed_ptr_mut()
            var src = cbp[].col_ptrs[c]
            for r in range(n_rows):
                dst[r] = Scalar[DType.int64](src[r])
            out.append_column(
                self._schema.field_at(c), Column.from_primitive(arr)
            )
        return out^

    @always_inline
    def _acquire(self):
        """Spin-acquire the serialising lock. Reached on every call when the
        connector did NOT declare `KOMIRA_SCAN_CAP_MT_SAFE` (the fail-SAFE
        arm), and on an MT-safe connector only for a call on the shared
        OVERFLOW slot cell."""
        while True:
            var expected = Int8(0)
            if self._counters[].lock.compare_exchange(expected, Int8(1)):
                return

    @always_inline
    def _release_lock(self):
        AtomicI8.store(
            UnsafePointer(to=self._counters[].lock)
            .unsafe_bitcast[Scalar[DType.int8]](),
            Int8(0),
        )

    # ------------------------------------------------------------ description

    def output_schema(self) -> Schema:
        return self._schema.copy()

    def partition_hint(self) -> Int:
        return self._partitions

    def row_count_hint(self) -> Int:
        return self._rows_hint

    def capabilities(self) -> SourceCapabilities:
        """Translate the connector's C bitmask into the engine's descriptor.

        ⚠ ONLY the bits the connector ACTUALLY declared. A connector that does
        not implement `set_projection` (NULL slot) never advertises
        `supports_projection`, so the optimizer never offers it one — the
        `capabilities()`-before-hook rule in `MorselSourceImpl` holds across
        the seam by construction, not by convention.
        """
        var proj = (self._caps & KOMIRA_SCAN_CAP_PROJECTION) != Int64(0)
        var pred = (self._caps & KOMIRA_SCAN_CAP_PREDICATE) != Int64(0)
        return SourceCapabilities(
            supports_projection=proj,
            supports_decode_filter=False,
            supports_dict_preservation=False,
            supports_dynamic_filter=False,
            supports_row_group_pruning=pred,
            supports_bypass_columns=False,
            supports_as_source=False,
        )

    # ------------------------------------------------- capability hooks (SETUP)
    # ⭐ These run ONCE inside `apply_source_hooks`, BEFORE the first
    # `next_morsel`. They are the half where scan performance lives.

    def set_projection(mut self, cols: List[Int]) -> None:
        """⭐ PROJECTION PUSHDOWN ACROSS THE SEAM. `List[Int]` -> `int32*`.

        The marshal is a stack `InlineArray` copy of at most 256 indices; a
        wider projection is NOT pushed (the engine projects above the scan,
        which is correct, just slower). Nor is one holding an index outside
        the schema (below 0 or at/above its width): such an index means
        nothing to the connector, and pushing it would leave the connector
        and `output_schema()` disagreeing on the column set. Not pushing
        keeps both on the full schema, as for a source with no projection.
        No allocation, no raising, once per query.
        """
        if (self._caps & KOMIRA_SCAN_CAP_PROJECTION) == Int64(0):
            return
        var n = len(cols)
        if n == 0 or n > 256:
            return
        var width = self._schema.num_columns()
        var buf = Array[Int32, 256](fill=Int32(0))
        for i in range(n):
            if cols[i] < 0 or cols[i] >= width:
                return
            buf[i] = Int32(cols[i])
        var rc = self._vt.set_projection(
            self._vt.handle,
            UnsafePointer(to=buf[0]).unsafe_origin_cast[MutUntrackedOrigin](),
            Int32(n),
        )
        if rc != KOMIRA_SCAN_OK:
            return
        # The source's own schema narrows to the projected columns, exactly as
        # a monomorphized source's would -- otherwise `_materialize` would
        # mis-name the columns the connector now returns.
        try:
            var sb = SchemaBuilder()
            for i in range(n):
                sb.add_field(self._schema.field_at(cols[i]))
            self._schema = sb.build()
        except:
            pass

    def set_pushed_predicate(mut self, expr: ExprId) -> None:
        """⭐ PREDICATE PUSHDOWN ACROSS THE SEAM — the lowered subset.

        ⛔ WHAT CROSSES: `col <cmp> int64-literal`. Nothing else. An expression
        outside that envelope is NOT pushed and the engine keeps its own
        filter above the scan — a conservative, correct answer, never a wrong
        one. Widening the envelope is a serialisation format on this slot, and
        is deliberately not attempted here.
        """
        if (self._caps & KOMIRA_SCAN_CAP_PREDICATE) == Int64(0):
            return
        if Int(self._pool) == 0:
            return
        var lowered = self._lower_predicate(expr)
        if not lowered:
            return
        var t = lowered.value()
        var rc = self._vt.set_predicate(self._vt.handle, t[0], t[1], t[2])
        if rc == KOMIRA_SCAN_OK:
            self._pushed = True

    def _lower_predicate(
        self, expr: ExprId
    ) -> Optional[Tuple[Int32, Int32, Int64]]:
        """`EXPR_BINARY_OP(cmp, EXPR_COL_IDX, EXPR_LITERAL[int])` -> (col, op,
        value). `None` for every other shape — the refusal that keeps the
        engine's answer correct when the connector cannot help."""
        # SAFETY: `_pool` is the caller-owned ExprPool installed by
        # `set_expr_pool`; the framework invariant on that trait method is the
        # lifetime proof. Null-checked by the only caller.
        ref node = self._pool[].resolve(expr)
        if node.tag != EXPR_BINARY_OP:
            return None
        var op = node.binary_op()
        var cmp: Int32
        if op == BIN_EQ:
            cmp = KOMIRA_SCAN_CMP_EQ
        elif op == BIN_LT:
            cmp = KOMIRA_SCAN_CMP_LT
        elif op == BIN_LE:
            cmp = KOMIRA_SCAN_CMP_LE
        elif op == BIN_GT:
            cmp = KOMIRA_SCAN_CMP_GT
        elif op == BIN_GE:
            cmp = KOMIRA_SCAN_CMP_GE
        else:
            return None
        ref lhs = node.binary_left_ref()
        ref rhs = node.binary_right_ref()
        if lhs.tag != EXPR_COL_IDX or rhs.tag != EXPR_LITERAL:
            return None
        var lit = rhs.literal_value()
        if not lit.is_int():
            return None
        return Optional(
            Tuple(Int32(lhs.col_idx_index()), cmp, lit.int_val)
        )

    def set_expr_pool[
        origin: Origin[mut=True]
    ](mut self, pool: UnsafePointer[ExprPool, origin]) -> None:
        """Stash the non-owning ExprPool pointer.

        SAFETY: the widening to `MutExternalOrigin` at this PRIVATE field is
        the safety-model §5.1 carve-out; the lifetime proof is the framework
        invariant stated on `MorselSourceImpl.set_expr_pool` — the pool
        outlives every `next_morsel` reachable from this source.
        """
        self._pool = pool.unsafe_origin_cast[MutUntrackedOrigin]()

    @always_inline
    def predicate_was_pushed(self) -> Bool:
        """Did a predicate actually reach the connector? The PROOF a pushdown
        test asserts on — an assertion on row count alone cannot distinguish
        "the connector filtered" from "the connector returned fewer rows"."""
        return self._pushed
