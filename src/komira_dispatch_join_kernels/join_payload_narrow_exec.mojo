# =============================================================================
# join_payload_narrow_exec -- the DELIVERY half of join payload narrowing
# =============================================================================
#
# The decision half is an optimizer rule: it proves, off folded parquet footer
# statistics, that a join's non-key INT64 payload column fits in 1/2/4
# unsigned bytes with a frame-of-reference `base`, and stamps a
# `PayloadNarrowSpec` on the scan
# (`ScanData.payload_narrow` -> `ParquetSourceData.payload_narrow`). This
# file is the reader.
#
# ⛔ WHY THE LEAF OWNS BOTH HALVES, AND WHY THERE IS NO PLAN REWRITE.
# DuckDB's `compressed_materialization/compress_comparison_join.cpp` spells the
# same rewrite as two projections -- a compress `Project(CAST(...))` on each
# join child and a decompress `Project` above the join. BOTH are unavailable
# here, and each for its own reason:
#   * compress BELOW: `join_node_exec._pure_colref_project_outputs` returns
#     None for a cast, so a computed project on ONE side declines the WHOLE
#     join to the legacy path.
#   * decompress ABOVE: the `PLAN_JOIN` ROOT gate, decline #9 "OFF-ROOT join".
# Either half independently takes the cell OFF the fused parquet-on-parquet
# leaf this lever exists to accelerate -- a ROUTE FLIP, which is invisible in
# values and in wall alone. So the rewrite rides as DATA and the leaf performs
# both halves internally, where the narrow representation is created and
# destroyed inside one driver and cannot escape.
#
# ★ SHAPE (A) -- NARROW THROUGH, WIDEN ONCE. This file implements that shape,
# and the reason for choosing it is the property to preserve: it touches NO
# existing gather kernel. The 1/2/4/8-byte typed gather arms serve a narrowed
# column unchanged, because every
# one of them dispatches on the SOURCE column's own byte width and copies the
# SOURCE column's own `arrow_type` onto the output. So this lever can only ever
# be wrong by being SLOW.
#
#   1. NARROW the BUILD-side resident batch (`_narrow_columns`), after the hash
#      table is built and before the output schema is derived from it.
#   2. The join runs unchanged. `emit_gather_column_projected` /
#      `_gather_fixed_into_range` read the narrow source at the narrow stride
#      and emit a narrow output column; the leaf's output schema follows the
#      narrowed build batch automatically.
#   3. WIDEN the joined `Table` at the leaf's exit
#      (`widen_payload_table_parallel`), chunk-AND-row-range parallel, back to
#      the byte-identical schema the leaf would have returned without the
#      lever.
#
# ⛔ THE BUILD SIDE ONLY, AND THAT IS A MEASURED CHOICE, NOT AN OMISSION.
# Under shape (A) the OUTPUT-path byte arithmetic is a LOSS for every column:
# the assembly writes `2N` instead of `8N`, then the widen reads `2N` and
# writes `8N` -- net `+2N` read and `+2N` written. The whole prize is on the
# SOURCE side: the build-side gather is RANDOM over the resident build column
# (on a high-cardinality join, 100M gathers into 25M x 8 B = 200 MB), and
# narrowing it to 2 B takes that array to 50 MB where cache residency is
# reachable. The probe side is streamed and near-sequential within one
# ~15,360-row morsel, i.e. already L2-resident, so narrowing it buys no
# locality and pays the same `+2N/+2N`.
#
# ⛔ AND THAT IS ALSO WHY THERE IS A SOURCE-SIZE ADMISSION GATE. The prize is
# source-side cache residency. A build side that ALREADY fits in cache has no
# residency to win and would pay only the extra widen pass -- which is exactly
# the `h2o/j1..j4` shape (build sides of 100 / 10K / 10K / 100K rows). The gate
# is stated in BYTES of the source column, `JOIN_PAYLOAD_NARROW_MIN_SRC_BYTES`,
# because that is the quantity the mechanism is about;
# `join_payload_narrow_all_sizes()` bypasses it so the gate's own contribution
# stays MEASURABLE in one binary rather than argued.
#
# POINTER DISCIPLINE: no `UnsafePointer` in
# any public signature here. The two dispatch States own every heap value
# behind `OwnedPointer` and carry NO wildcard-origin field; the only
# raw pointers are inside the kernels and inside the `Segment.execute` bitcast
# the substrate's own dispatch shape requires, each with a `# SAFETY:` note.
# =============================================================================

from komira_atomic_alias import AtomicI8
from std.memory import alloc, OwnedPointer, Pointer, UnsafePointer

from komira_arrow.arrow_types import ArrowType, arrow_fixed_byte_width
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.table import Table
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.payload_narrow import (
    PayloadNarrowSpec,
    find_narrow_spec,
    PAYLOAD_NARROW_1B,
    PAYLOAD_NARROW_2B,
    PAYLOAD_NARROW_4B,
)
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from std.ffi import _Global

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.sched_trace import SITE_CONCAT


# =============================================================================
# §0 -- the settings and the constants
# =============================================================================


def join_payload_narrow_enabled() raises -> Bool:
    """THE LEVER, **DEFAULT-ON**. The binary sets it once at startup from its
    flag with `configure_join_payload_narrow`; until then it reads ON. Off is
    the kill switch and the A/B baseline.

    Promoted from default-off on its own measured A/B: a high-cardinality join
    -4.33% with block-median ranges DISJOINT against an identical-binary
    control of -0.67% that OVERLAPS, the other four narrowed cells all
    OVERLAPPING (i.e. no established movement), NO route flip on any cell on
    any arm, and 84/84 `VALUE_IDENTICAL` on both armed arms.

    ⛔ THE FLIP NEEDED NO PER-CALLER CONJUNCT, AND THAT WAS CHECKED RATHER THAN
    ASSUMED -- the segmented-output flip DID need one
    (`_seg_out = allow_segments and join_seg_out_enabled()`) because a
    process-wide gate changed the SHAPE the leaf returns and single-batch
    consumers RAISE on >1 chunk. This lever changes no observable shape:
      * `ParquetSourceData.payload_narrow` is READ at exactly one site
        (`materialize_join.materialize_parquet_join` -> the `build_narrow`
        argument of `_run_fused_parquet_probe`). The other caller of that
        leaf, `materialize_parquet_probe_inmem_build_join`, passes an EMPTY
        list unconditionally, and the `_agg` / `_agg_mapped` / `_multi_key`
        siblings have no such parameter at all.
      * `_run_fused_parquet_probe` has exactly ONE `return`, and the widen sits
        unconditionally above it -- so no exit path can leak a narrow column.
      * the leaf derives `_pn_wide_schema` BEFORE the narrow and returns THAT
        on both arms, so no caller can observe a different type, name or order.
      * the zero-chunk and zero-row results are handled explicitly in
        `widen_payload_table_parallel` and still carry the WIDE schema.

    Read ONCE, at the driver's decision point; no arm re-reads it mid-flight.
    """
    # SAFETY: `_Global.get_or_create_ptr` targets KGEN-runtime static storage
    # (process-lifetime); the untracked origin is the stdlib API's own return
    # type, confined to this function.
    var g = _PN_ENABLED.get_or_create_ptr()
    return g[][].load() != Int8(0)


def join_payload_narrow_all_sizes() raises -> Bool:
    """THE ADMISSION-GATE BYPASS -- an INSTRUMENT, not a second lever.

    DEFAULT-OFF, set with `configure_join_payload_narrow`, and inert unless the
    lever above is on. It exists so that "the source-size gate earns its place"
    is a MEASUREMENT taken with one binary and two run-time arms, rather than
    an argument: with it set, every column the optimizer stamped is narrowed
    whatever its source size, so the cells the gate declines can be priced
    both ways in one sweep.
    """
    # SAFETY: as `join_payload_narrow_enabled`.
    var g = _PN_ALL_SIZES.get_or_create_ptr()
    return g[][].load() != Int8(0)


def configure_join_payload_narrow(enabled: Bool, all_sizes: Bool) raises:
    """Set both settings for this process from the binary's flags. Call it once
    at startup, before any join runs."""
    # SAFETY: as `join_payload_narrow_enabled`.
    var e = _PN_ENABLED.get_or_create_ptr()
    e[][].store(Int8(1) if enabled else Int8(0))
    var a = _PN_ALL_SIZES.get_or_create_ptr()
    a[][].store(Int8(1) if all_sizes else Int8(0))


def _init_pn_on() -> OwnedPointer[AtomicI8]:
    # SAFETY: `alloc` returns one uninitialised `AtomicI8` slot, owned by this
    # function until the `OwnedPointer` below takes it. The write initialises
    # it through an int8 view of the same byte (an `AtomicI8` holds one int8).
    # From then on the returned `OwnedPointer` owns the slot and frees it when
    # it is destroyed; `_Global` keeps that `OwnedPointer` in its
    # process-global slot.
    var raw = alloc[AtomicI8](1)
    raw.unsafe_bitcast[Scalar[DType.int8]]().unsafe_write(Scalar[DType.int8](1))
    return OwnedPointer[AtomicI8](unsafe_from_raw_pointer=raw)


def _init_pn_off() -> OwnedPointer[AtomicI8]:
    # SAFETY: as `_init_pn_on`, with 0 (OFF) written instead of 1.
    var raw = alloc[AtomicI8](1)
    raw.unsafe_bitcast[Scalar[DType.int8]]().unsafe_write(Scalar[DType.int8](0))
    return OwnedPointer[AtomicI8](unsafe_from_raw_pointer=raw)


comptime _PN_ENABLED = _Global[
    "komira_dispatch_join_payload_narrow_on", _init_pn_on
]
comptime _PN_ALL_SIZES = _Global[
    "komira_dispatch_join_payload_narrow_all_sizes", _init_pn_off
]


comptime JOIN_PAYLOAD_NARROW_MIN_SRC_BYTES: Int = 16 * 1024 * 1024
"""The SOURCE-SIZE admission floor, in bytes of the build column as declared.

⚠ DERIVED FROM THE MECHANISM, NOT FITTED TO A CELL. Shape (A)'s only prize is
that a RANDOMLY gathered build column stops missing cache; its cost (`+2N`
read, `+2N` written over the OUTPUT) is paid regardless. So the discriminator
is "is the source bigger than the cache it is being gathered out of". 16 MiB is
above every per-core cache on the boxes this engine is measured on and below a
socket's LLC, which is the interval where a random gather starts paying DRAM.

⚠ IT IS A FLOOR ON THE SOURCE, NOT ON THE OUTPUT. A big output over a small
build side (`h2o/j1`: 6,000,000 output rows over a 100-row build) is precisely
the shape that pays the widen and wins nothing, and an output-row floor would
ADMIT it."""


comptime _PN_MIN_PARALLEL_ROWS: Int = 65536
"""Below this many total rows the fork costs more than the pass. A
`run_with_state` round trip is a wake-word barrier plus one enqueue per worker;
the serial arm below calls the SAME kernels, so this is a cost decision and
never a semantic one."""

comptime _PN_MIN_TILE_ROWS: Int = 16384
"""Smallest row-range tile worth its own task."""


# --- Per-column dispositions. A predicate with N ways to say no must return
#     WHICH ONE: a witness reading "declined" cannot tell a stats refusal from
#     a rule that never ran, and that ambiguity has already cost a day of
#     diagnosis.
comptime PN_ADMIT: UInt8 = 0
comptime PN_NO_SPEC: UInt8 = 1
comptime PN_NOT_INT64: UInt8 = 2
comptime PN_NULLABLE: UInt8 = 3
comptime PN_SRC_TOO_SMALL: UInt8 = 4
comptime PN_BAD_WIDTH: UInt8 = 5
comptime PN_NOT_NARROWER: UInt8 = 6
comptime PN_RANGE_VIOLATION: UInt8 = 7

# --- Whole-lever dispositions.
comptime PNL_ADMIT: UInt8 = 0
comptime PNL_GATE_OFF: UInt8 = 1
comptime PNL_NO_SPECS: UInt8 = 2
comptime PNL_NOT_INNER: UInt8 = 3
comptime PNL_COUNT_ONLY: UInt8 = 4
comptime PNL_SCHEMA_SHAPE: UInt8 = 5
comptime PNL_PAYLOAD_INLINE_ON: UInt8 = 6
comptime PNL_NO_COLUMN: UInt8 = 7
comptime PNL_RANGE_VIOLATION: UInt8 = 8


# =============================================================================
# §1 -- the plan the two halves share
# =============================================================================


struct PayloadWidenPlan(Movable, Copyable):
    """What the narrow half did, in the terms the widen half needs.

    A plan with `len(out_col) == 0` is the IDENTITY: the widen is then a
    no-op that returns its argument untouched, which is what every declined
    join, every non-INNER join and every caller of this leaf that carries no
    specs sees.

    ⚠ `out_col` IS AN OUTPUT COLUMN INDEX, NOT A NAME. The join output renames
    a colliding build column to `<name>_right`, so a name lookup on the output
    schema would miss precisely the columns most likely to collide. Build
    column `j` is output column `probe_ncols + j` -- an identity the leaf
    already asserts (`schema.num_columns() == probe_ncols + build_ncols`) and
    which this plan is only ever constructed under.
    """

    var out_col: List[Int]
    var src_bytes: List[UInt8]
    var base: List[Int64]
    # Diagnosis, carried so the witness names the LINE and not the verdict.
    var lever_code: UInt8
    var col_names: List[String]
    var col_codes: List[UInt8]
    var col_bytes: List[UInt8]

    def __init__(out self, lever_code: UInt8 = PNL_ADMIT):
        self.out_col = List[Int]()
        self.src_bytes = List[UInt8]()
        self.base = List[Int64]()
        self.lever_code = lever_code
        self.col_names = List[String]()
        self.col_codes = List[UInt8]()
        self.col_bytes = List[UInt8]()

    def copy(self) -> Self:
        var out = Self(self.lever_code)
        out.out_col = self.out_col.copy()
        out.src_bytes = self.src_bytes.copy()
        out.base = self.base.copy()
        out.col_names = self.col_names.copy()
        out.col_codes = self.col_codes.copy()
        out.col_bytes = self.col_bytes.copy()
        return out^

    @always_inline
    def num_widened(self) -> Int:
        return len(self.out_col)

    def witness(self, imm tag: String) -> String:
        """ONE line, printed on BOTH arms, naming the disposition of the lever
        and of every candidate column.

        ⚠ IT PRINTS ON BOTH ARMS DELIBERATELY. A counter living inside
        `if gate_on:` can witness the ON arm and is structurally incapable of
        witnessing the OFF one, so its silence reads as "never reached" -- the
        commonest instrument defect of this kind. `lever=1` IS the OFF
        arm's reading and it is distinguishable from no line at all.

        ⚠ `sep=""` semantics: this builds ONE String rather than relying on
        `print`'s default SPACE separator, which defeats a `grep` for
        `bytes=2` by emitting `bytes= 2`.
        """
        var s = String("[paynarrow-exec] ") + tag
        s += String(" lever=") + String(Int(self.lever_code))
        s += String(" widened=") + String(self.num_widened())
        for i in range(len(self.col_names)):
            s += String(" col=") + self.col_names[i]
            s += String(":code=") + String(Int(self.col_codes[i]))
            s += String(":bytes=") + String(Int(self.col_bytes[i]))
        return s


# =============================================================================
# §2 -- the row-range work item, shared by both dispatches
# =============================================================================


@fieldwise_init
struct _PnWork(Copyable, Movable):
    """One (destination slot x row range) tile.

    `chunk` is the input chunk index for the WIDEN dispatch and is unused
    (always 0) for the NARROW dispatch, which has exactly one input batch.
    `col` indexes the PLAN (widen) or the build batch's columns (narrow)."""

    var slot: Int32
    var chunk: Int32
    var col: Int32
    var row_start: Int
    var row_end: Int


def _tile_rows(total_rows: Int, num_workers: Int) -> Int:
    """Row-tile size: enough tiles to spread over the pool, never below
    `_PN_MIN_TILE_ROWS` (a tile smaller than that is dominated by its own
    task-dispatch cost)."""
    if num_workers < 2:
        return total_rows if total_rows > 0 else 1
    var want = (total_rows + (num_workers * 4) - 1) // (num_workers * 4)
    if want < _PN_MIN_TILE_ROWS:
        want = _PN_MIN_TILE_ROWS
    return want if want > 0 else 1  # cov: unreachable want is at least _PN_MIN_TILE_ROWS here


# =============================================================================
# §3 -- the kernels
# =============================================================================


def _pn_narrow_range(
    imm src: Column[HeapRegion],
    base: Int64,
    target_bytes: UInt8,
    row_start: Int,
    row_end: Int,
    mut dst: OwnedAlignedBuffer,
) raises -> Bool:
    """Write `src[row] - base` as an unsigned `target_bytes` integer into
    `dst[row]`, for rows [row_start, row_end).

    Returns False iff some value fell OUTSIDE `[base, base + 2^(8B) - 1]`.

    ⛔ THE RANGE CHECK IS NOT DEFENSIVE PROGRAMMING, IT IS THE ONLY THING THAT
    MAKES THIS LEVER "WRONG ONLY BY BEING SLOW". The width was proved from
    parquet FOOTER statistics; a writer that emitted a wrong `max`, a footer
    this engine mis-decodes, or a future rule that widens the admission would
    otherwise produce a truncated value that the widen reconstructs as a
    DIFFERENT number -- a wrong answer with a correct row count, a correct
    schema and a clean null bitmap, a shape no value oracle can see. It rides
    a pass that reads every value anyway, and a
    violation DISCARDS the narrowing wholesale rather than raising: the
    original columns are still live at that point, so the fallback is the
    unnarrowed join, which is always correct.
    """
    # SAFETY: module-internal pointer arithmetic. `src._data` is live for the
    # whole call through the `read` borrow; `dst` is the caller's pre-sized
    # destination and this frame writes ONLY elements [row_start, row_end),
    # the disjoint slice the driver's parallelize contract is stated over.
    var off = src._offset
    var sview = src._data.view_ro()
    var s = sview._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    var dview = dst.view_mut()
    if target_bytes == PAYLOAD_NARROW_2B:
        var d = dview._unsafe_ptr().bitcast[Scalar[DType.uint16]]()
        for i in range(row_start, row_end):
            var delta = (s + off + i)[] - base
            if delta < 0 or delta > 65535:
                return False
            (d + i)[] = delta.cast[DType.uint16]()
        return True
    if target_bytes == PAYLOAD_NARROW_1B:
        var d = dview._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
        for i in range(row_start, row_end):
            var delta = (s + off + i)[] - base
            if delta < 0 or delta > 255:
                return False
            (d + i)[] = delta.cast[DType.uint8]()
        return True
    if target_bytes == PAYLOAD_NARROW_4B:
        var d = dview._unsafe_ptr().bitcast[Scalar[DType.uint32]]()
        for i in range(row_start, row_end):
            var delta = (s + off + i)[] - base
            if delta < 0 or delta > 4294967295:
                return False
            (d + i)[] = delta.cast[DType.uint32]()
        return True
    # ⛔ NOT AN `else` THAT GUESSES A WIDTH. An unrecognised target is a
    # REFUSAL, and the caller falls back to the unnarrowed column.
    return False


def _pn_widen_range(
    imm src: Column[HeapRegion],
    base: Int64,
    src_bytes: UInt8,
    row_start: Int,
    row_end: Int,
    mut dst: OwnedAlignedBuffer,
) raises:
    """Write `Int64(src[row]) + base` into `dst[row]` for [row_start, row_end).

    The exact inverse of `_pn_narrow_range`: `base` is only ever added back by
    the code that subtracted it, which is the invariant the whole design rests
    on (a half-applied narrowing is the one wrong-answer shape here)."""
    # SAFETY: as `_pn_narrow_range`. Disjoint destination element range.
    var off = src._offset
    var sview = src._data.view_ro()
    var dview = dst.view_mut()
    var d = dview._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    if src_bytes == PAYLOAD_NARROW_2B:
        var s = sview._unsafe_ptr().bitcast[Scalar[DType.uint16]]()
        for i in range(row_start, row_end):
            (d + i)[] = (s + off + i)[].cast[DType.int64]() + base
        return
    if src_bytes == PAYLOAD_NARROW_1B:
        var s = sview._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
        for i in range(row_start, row_end):
            (d + i)[] = (s + off + i)[].cast[DType.int64]() + base
        return
    if src_bytes == PAYLOAD_NARROW_4B:
        var s = sview._unsafe_ptr().bitcast[Scalar[DType.uint32]]()
        for i in range(row_start, row_end):
            (d + i)[] = (s + off + i)[].cast[DType.int64]() + base
        return
    raise Error(
        "join_payload_narrow_exec: widen asked for source width "
        + String(Int(src_bytes))
        + "; only 1, 2 and 4 are ever narrowed to."
    )


# =============================================================================
# §4 -- the NARROW dispatch (build-side, one batch, N columns)
# =============================================================================


struct _PnNarrowState(KeepAlive, Movable):
    """State for the build-side narrowing fork.

    Wildcard-free: every heap value sits behind `OwnedPointer` and the
    read-only per-slot metadata are direct `List` fields written ONCE by the
    driver before the fork."""

    # OWNED source columns, MOVED out of the build batch. Workers take
    # `src[][col]` BY REF and never mutate it.
    var src: OwnedPointer[Slab[Column[HeapRegion]]]
    # OWNED destination buffers, one per ADMITTED column, pre-sized before the
    # fork. Task `w` writes elements [w.row_start, w.row_end) of `out[][w.slot]`
    # and nothing else.
    var out: OwnedPointer[Slab[OwnedAlignedBuffer]]
    # Per-slot, read-only.
    var bases: List[Int64]
    var widths: List[UInt8]
    var work: List[_PnWork]
    # First-writer-wins violation flag: some value did not fit the proved
    # width. Not an error channel -- the driver DISCARDS the narrowing.
    var bad: OwnedPointer[AtomicI8]
    var err_flag: OwnedPointer[AtomicI8]
    var err_msg: OwnedPointer[String]

    def __init__(
        out self,
        var src: Slab[Column[HeapRegion]],
        var out: Slab[OwnedAlignedBuffer],
        var bases: List[Int64],
        var widths: List[UInt8],
        var work: List[_PnWork],
    ):
        # SAFETY: each `alloc` returns one uninitialised slot, owned by this
        # constructor until the `OwnedPointer` right after it takes it; the
        # `unsafe_write` (through an int8 view for an `AtomicI8`, which holds
        # one int8) initialises it first. From then on that field's
        # `OwnedPointer` owns the slot and frees it when the State drops.
        var sraw = alloc[Slab[Column[HeapRegion]]](1)
        sraw.unsafe_write(src^)
        self.src = OwnedPointer[Slab[Column[HeapRegion]]](
            unsafe_from_raw_pointer=sraw
        )
        var oraw = alloc[Slab[OwnedAlignedBuffer]](1)
        oraw.unsafe_write(out^)
        self.out = OwnedPointer[Slab[OwnedAlignedBuffer]](
            unsafe_from_raw_pointer=oraw
        )
        self.bases = bases^
        self.widths = widths^
        self.work = work^
        var braw = alloc[AtomicI8](1)
        braw.unsafe_bitcast[Scalar[DType.int8]]().unsafe_write(Scalar[DType.int8](0))
        self.bad = OwnedPointer[AtomicI8](
            unsafe_from_raw_pointer=braw
        )
        var eraw = alloc[AtomicI8](1)
        eraw.unsafe_bitcast[Scalar[DType.int8]]().unsafe_write(Scalar[DType.int8](0))
        self.err_flag = OwnedPointer[AtomicI8](
            unsafe_from_raw_pointer=eraw
        )
        var mraw = alloc[String](1)
        mraw.unsafe_write(String(""))
        self.err_msg = OwnedPointer[String](unsafe_from_raw_pointer=mraw)


@fieldwise_init
struct _PnNarrowTask(Segment):
    """POD Segment for `_PnNarrowState` -- one task per (column x row range)."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the caller parameterizes `run_with_state` over
        # (_PnNarrowState, _PnNarrowTask), so the bitcast resolves to the
        # concrete state at the call site.
        var sp = UnsafePointer(to=state).bitcast[_PnNarrowState]()
        if sp[].err_flag[].load() != Int8(0):  # cov: unreachable no narrow task raises: _pn_narrow_range raises nothing
            return  # cov: unreachable see the line above
        try:
            ref w = sp[].work[Int(task_id)]
            var slot = Int(w.slot)
            # SAFETY: two tiles of the same slot receive an aliased `mut` ref
            # to `out[][slot]` (through the bitcast pointer, invisible to the
            # borrow checker) but write DISJOINT element ranges -- the
            # parallel-region disjointness contract stated on the driver.
            ref dbuf = sp[].out[].get_mut_interior(slot)
            var ok = _pn_narrow_range(
                sp[].src[][Int(w.col)],
                sp[].bases[slot],
                sp[].widths[slot],
                w.row_start,
                w.row_end,
                dbuf,
            )
            if not ok:
                var expected = Int8(0)
                _ = sp[].bad[].compare_exchange(expected, Int8(1))
        except e:  # cov: unreachable no narrow task raises: _pn_narrow_range raises nothing
            var expected2 = Int8(0)  # cov: unreachable see the line above
            if sp[].err_flag[].compare_exchange(expected2, Int8(1)):  # cov: unreachable see the line above
                sp[].err_msg[] = String(e)  # cov: unreachable see the line above


struct NarrowedBuild(Movable):
    """`narrow_build_batch`'s result: the batch the join will use (narrowed or
    the original, untouched) and the plan the widen half must execute.

    ⛔ THE BATCH COMES OUT THROUGH `Optional.take()`, NOT `self.batch^`. Moving
    a field out of a returned struct is a PARTIAL MOVE, and Mojo 1.0.0 then
    refuses to destroy the remainder ("destroyed out of the middle of a
    value"). `Optional.take()` is the sanctioned spelling in this tree --
    the pointer rules ban the `UnsafePointer(to=struct.field).take_pointee()`
    workaround by name."""

    var _batch: Optional[RecordBatch]
    var plan: PayloadWidenPlan

    def __init__(out self, var batch: RecordBatch, var plan: PayloadWidenPlan):
        self._batch = Optional[RecordBatch](batch^)
        self.plan = plan^

    def take_batch(mut self) -> RecordBatch:
        """Move the batch out. Exactly one caller, exactly once."""
        return self._batch.take()


def narrow_build_batch[
    disp_o: Origin[mut=True],
](
    var build_batch: RecordBatch,
    imm specs: List[PayloadNarrowSpec],
    probe_ncols: Int,
    lever_precheck: UInt8,
    all_sizes: Bool,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
    num_workers: Int,
) raises -> NarrowedBuild:
    """Narrow the admitted BUILD-side payload columns in place-of-batch.

    Args:
        build_batch: The resident build batch, CONSUMED. Returned unchanged
            (moved through) on every refusal.
        specs: The optimizer's per-column instructions, by column NAME.
        probe_ncols: The join output's probe-side column count -- build column
            `j` becomes output column `probe_ncols + j`.
        lever_precheck: `PNL_ADMIT`, or the refusal the CALLER already proved
            (gate off, non-INNER, count-only, an output schema that is not
            exactly `probe ++ build`). Passed in rather than re-derived so the
            witness carries one disposition and the leaf owns the route facts
            it alone can see.
        all_sizes: Bypass the source-size admission floor (the instrument).
        dispatcher_ptr: Borrowed substrate dispatcher (tight origin).
        cancel_token: Consumed by the dispatch.
        num_workers: Pool width; bounds the tile count.

    Returns:
        A `NarrowedBuild`. `plan.num_widened() == 0` means NOTHING was narrowed
        and `batch` is byte-identical to the input -- the caller then proceeds
        exactly as if this lever did not exist.
    """
    if lever_precheck != PNL_ADMIT:
        _ = cancel_token^
        return NarrowedBuild(build_batch^, PayloadWidenPlan(lever_precheck))
    if len(specs) == 0:
        _ = cancel_token^
        return NarrowedBuild(build_batch^, PayloadWidenPlan(PNL_NO_SPECS))

    var rows = build_batch.num_rows()
    var ncols = build_batch.num_columns()
    var plan = PayloadWidenPlan(PNL_ADMIT)

    # ---- Per-column admission, on METADATA only -----------------------------
    var adm_col = List[Int]()
    var adm_width = List[UInt8]()
    var adm_base = List[Int64]()
    for j in range(ncols):
        var name = build_batch.schema.field_name(j)
        var si = find_narrow_spec(specs, name)
        if si < 0:
            continue
        # Only columns the optimizer NAMED are reported: a witness listing
        # every column of every join would drown the ones under test.
        plan.col_names.append(name.copy())
        ref sp = specs[si]
        ref col = build_batch.column_at(j)
        if col.arrow_type != ArrowType.INT64:
            # The spec was proved against a DECLARED INT64. A batch whose
            # physical column is something else (a dictionary-preserved decode,
            # a promoted width) is a different column than the one proved.
            plan.col_codes.append(PN_NOT_INT64)
            plan.col_bytes.append(UInt8(0))
            continue
        if col._validity:
            # A narrowed column keeps its validity bitmap, but the value under
            # a NULL slot is not covered by [min, max]; `v - base` on it can
            # wrap and the widen would reconstruct a DIFFERENT garbage value.
            # The optimizer already refuses a nullable column; this is the
            # PHYSICAL re-check, because the batch is what arrives.
            plan.col_codes.append(PN_NULLABLE)
            plan.col_bytes.append(UInt8(0))
            continue
        if (
            sp.target_bytes != PAYLOAD_NARROW_1B
            and sp.target_bytes != PAYLOAD_NARROW_2B
            and sp.target_bytes != PAYLOAD_NARROW_4B
        ):
            plan.col_codes.append(PN_BAD_WIDTH)
            plan.col_bytes.append(sp.target_bytes)
            continue
        if Int(sp.target_bytes) >= 8:  # cov: unreachable the rung above admits only 1, 2 and 4
            plan.col_codes.append(PN_NOT_NARROWER)  # cov: unreachable see the line above
            plan.col_bytes.append(sp.target_bytes)  # cov: unreachable see the line above
            continue  # cov: unreachable see the line above
        if (not all_sizes) and rows * 8 < JOIN_PAYLOAD_NARROW_MIN_SRC_BYTES:
            # THE SOURCE-SIZE FLOOR. See the constant's docstring: shape (A)'s
            # only prize is source-side cache residency, and a source already
            # resident has none to win while still paying the widen.
            plan.col_codes.append(PN_SRC_TOO_SMALL)
            plan.col_bytes.append(sp.target_bytes)
            continue
        plan.col_codes.append(PN_ADMIT)
        plan.col_bytes.append(sp.target_bytes)
        adm_col.append(j)
        adm_width.append(sp.target_bytes)
        adm_base.append(sp.base)

    var n_adm = len(adm_col)
    if n_adm == 0 or rows == 0:
        _ = cancel_token^
        plan.lever_code = PNL_NO_COLUMN
        return NarrowedBuild(build_batch^, plan^)

    # ---- Size the destinations and the tiles, BEFORE the fork ---------------
    var out_bufs = Slab[OwnedAlignedBuffer].create(n_adm)
    var bases = List[Int64](capacity=n_adm)
    var widths = List[UInt8](capacity=n_adm)
    for p in range(n_adm):
        var w = Int(adm_width[p])
        var buf = OwnedAlignedBuffer(max(rows * w, 1))
        buf.set_length(Int64(rows * w))
        out_bufs.append(buf^)
        bases.append(adm_base[p])
        widths.append(adm_width[p])

    var tile = _tile_rows(rows, num_workers)
    var work = List[_PnWork]()
    for p in range(n_adm):
        var r = 0
        while r < rows:
            var hi = r + tile
            if hi > rows:
                hi = rows
            work.append(_PnWork(Int32(p), Int32(0), Int32(adm_col[p]), r, hi))
            r = hi
    var n_tasks = len(work)

    # ---- Move the columns out so the workers own a stable slab --------------
    var src_schema = build_batch.schema.copy()
    var src_cols = build_batch.take_columns()
    _ = build_batch^

    var bad = False
    if (
        num_workers < 2
        or rows < _PN_MIN_PARALLEL_ROWS
        or n_tasks < 2  # cov: unreachable with 2+ workers and 65536+ rows, _tile_rows cuts 4+ tiles
    ):
        # SERIAL ARM -- the SAME kernel, so it cannot diverge from the forked
        # one. Reached by every small fixture (and by every unit test), which
        # is why the tests drive both.
        _ = cancel_token^
        for t in range(n_tasks):
            ref wk = work[t]
            var slot = Int(wk.slot)
            ref dbuf = out_bufs.get_mut_interior(slot)
            if not _pn_narrow_range(
                src_cols[Int(wk.col)],
                bases[slot],
                widths[slot],
                wk.row_start,
                wk.row_end,
                dbuf,
            ):
                bad = True
                break
    else:
        # Parallel region: (column x row range) build-side narrowing.
        # Disjointness: task `t` READS `src[][work[t].col]` (read-only, shared)
        #   and WRITES elements [row_start, row_end) of `out[][work[t].slot]`
        #   only. The tiles of one slot PARTITION [0, rows), and different
        #   slots are different buffers, so no task writes a byte another
        #   reads or writes. `bases` / `widths` / `work` are written once by
        #   this driver before the fork and only read after it.
        # Liveness: the State owns both slabs via `OwnedPointer` and the
        #   driver's `var state` slot holds it across `run_with_state`, whose
        #   drain barrier rejoins every worker before this function returns.
        # No-realloc: both slabs are `create(n_adm)` + exactly `n_adm` appends
        #   BEFORE the fork; no task appends, reserves or resizes, and
        #   `get_mut_interior` is length-preserving.
        var state = _PnNarrowState(
            src_cols^, out_bufs^, bases^, widths^, work^
        )
        var task = _PnNarrowTask(Int32(0))
        _ = dispatcher_ptr[].run_with_state[_PnNarrowState, _PnNarrowTask](
            state, task^, n_tasks, cancel_token^, site_id=SITE_CONCAT
        )
        var raised = state.err_flag[].load() != Int8(0)
        var raised_msg = String("")
        if raised:  # cov: unreachable no narrow task raises: _pn_narrow_range raises nothing
            raised_msg = String(state.err_msg[])  # cov: unreachable see the line above
        bad = state.bad[].load() != Int8(0)

        # Move both slabs back out of the State by swapping an empty slab into
        # each `OwnedPointer`'s pointee, so `state^` drops two empty slabs.
        src_cols = Slab[Column[HeapRegion]]()
        swap(src_cols, state.src[])
        out_bufs = Slab[OwnedAlignedBuffer]()
        swap(out_bufs, state.out[])
        _ = state^
        if raised:  # cov: unreachable no narrow task raises: _pn_narrow_range raises nothing
            raise Error("narrow_build_batch: " + raised_msg)  # cov: unreachable see the line above

    if bad:
        # ⛔ A VIOLATION DISCARDS THE WHOLE NARROWING, IT DOES NOT RAISE AND IT
        # DOES NOT NARROW THE OTHER COLUMNS. The original columns are still
        # live and untouched here, so the fallback is the join this leaf would
        # have run without the lever -- always correct, only slower. Raising
        # would convert a stale statistic into a failed query.
        _ = out_bufs^
        plan.out_col = List[Int]()
        plan.src_bytes = List[UInt8]()
        plan.base = List[Int64]()
        plan.lever_code = PNL_RANGE_VIOLATION
        for i in range(len(plan.col_codes)):
            if plan.col_codes[i] == PN_ADMIT:
                plan.col_codes[i] = PN_RANGE_VIOLATION
        return NarrowedBuild(
            RecordBatch.from_typed_columns_slab(src_schema^, src_cols^), plan^
        )

    # ---- Install the narrowed columns + the narrowed schema -----------------
    var sb = SchemaBuilder()
    var narrow_at = List[ArrowType]()
    for p in range(n_adm):
        var w = adm_width[p]
        if w == PAYLOAD_NARROW_1B:
            narrow_at.append(ArrowType.UINT8)
        elif w == PAYLOAD_NARROW_2B:
            narrow_at.append(ArrowType.UINT16)
        else:
            narrow_at.append(ArrowType.UINT32)
    for j in range(ncols):
        var at = src_schema.field_arrow_type(j)
        for p in range(n_adm):
            if adm_col[p] == j:
                at = narrow_at[p]
                break
        sb.add_field(
            Field(src_schema.field_name(j), at, src_schema.field_nullable(j))
        )
    var narrow_schema = sb.build()

    for p in range(n_adm):
        var j = adm_col[p]
        var buf = out_bufs.take_slot_unchecked(p)
        var old = src_cols.replace(
            j,
            Column[HeapRegion](
                arrow_type=narrow_at[p],
                data=buf^,
                offsets=Optional[OwnedAlignedBuffer](None),
                validity=Optional[Bitmap[HeapRegion]](None),
                length=rows,
                null_count=0,
                offset=0,
            ),
        )
        # The WIDE build column drops HERE -- which is half the point: on a
        # 25M-row build this releases 200 MB and leaves 50 MB in its place,
        # and that is the residency the lever is buying.
        _ = old^
        plan.out_col.append(probe_ncols + j)
        plan.src_bytes.append(adm_width[p])
        plan.base.append(adm_base[p])
    out_bufs.set_len_unchecked(0)
    _ = out_bufs^
    _ = src_schema^

    return NarrowedBuild(
        RecordBatch.from_typed_columns_slab(narrow_schema^, src_cols^), plan^
    )
