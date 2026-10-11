# =============================================================================
# ⭐ CD-SCAN (2026-09-25, cbq10 / cbq11) — UNIFY every batch's STRING dictionary
#   BEFORE the concat, so a dictionary column concatenates as INT32 codes
# =============================================================================
#
# `concat_record_batches_column_parallel` joins the per-row-group batches a
# parquet collect produces. A parquet dictionary is per COLUMN CHUNK, so a
# collect that keeps dictionaries (`materialize_parquet_collect(preserve_dict=
# True)`, the grouped COUNT(DISTINCT) resident route) hands it one PRIVATE
# dictionary per batch. The concat's DICTIONARY arm was a PAIR-WISE fold
# (`_concat_slow_column_pairwise` -> `_concat_columns`): every step copies the
# ACCUMULATED codes again, O(N^2) in the batch count — ~9 GB of copies for
# cbq10's 814 row groups — and it runs as ONE task.
#
# WHAT THIS DOES INSTEAD, per string-dictionary column:
#   1. (parallel, T tasks over contiguous BATCH ranges) each task interns its
#      batches' dictionary entries into a private `DictInterner`, in
#      (batch, entry) order, and records each batch's code -> local ordinal;
#   2. (serial, the driver) the tasks' interners are merged IN TASK ORDER into
#      one: task 0's interner is the start (seeded from batch 0 with
#      `seed_append`, duplicates preserved), each later task's entries are
#      `find_or_insert`ed in their mint order;
#   3. (parallel, same tasks) every batch's codes are rewritten through the
#      composed map (code -> local -> global) into a fresh INT32 column;
# then the ordinary concat runs (all-fixed-width now, so it TILES across the
# pool), and `rewrap_unified_dict_columns` re-labels the concatenated INT32
# codes as ONE DICTIONARY column carrying the merged dictionary.
#
# ★ THE MERGED DICTIONARY IS THE PAIR-WISE FOLD'S, BYTE FOR BYTE. The fold
# seeds from the first batch's dictionary (`seed_append`, so a repeated entry
# keeps its ordinal) and then `find_or_insert`s every later entry in (batch,
# entry) order: the merged order is FIRST-SEEN over that sequence. Steps 1-2
# produce the same order by the argument CDP-ROWDICT's header makes for rows:
# the merge meets task t's local entries in their first-seen order within t's
# batch range, and every entry of task t precedes every entry of task t+1 in
# the sequence. `test_concat_dict_unify_equals_pairwise_fold` holds it.
#
# Two things the fold did that this does NOT, both defects of the fold:
#   * its identical-dictionary fast path dropped the VALIDITY bitmap;
#   * it read codes from the buffer START, ignoring a sliced column's `_offset`.
#
# ⛔ SCOPE. Only STRING dictionaries with Int32 codes, in a set of batches that
# all carry the column as such (a ZERO-row batch may carry anything). A column
# that MIXES a non-empty dictionary batch with a non-empty plain STRING batch
# (a parquet chunk that fell back to PLAIN pages) is DENSIFIED instead — every
# dictionary batch becomes STRING — so the concat sees one layout, as the
# `preserve_dict=False` decode would have produced. Numeric dictionaries,
# Int64 codes, a batch with a selection mask, or fewer than two batches leave
# the input untouched and the old arms run exactly as before.
#
# Safety
# ------
# * The batches are MOVED INTO the dispatch State (OwnedPointer) and swapped
#   back out after the barrier; workers only read them.
# * Workers write disjoint pre-sized slots (`Slab.__setitem__` on live slots).
# * No wildcard-origin fields; every `run_with_state` carries the
#   PARALLELIZE-BOUNDARY block.
# =============================================================================

from komira_atomic_alias import AtomicI8, AtomicI64
from std.builtin.swap import swap
from std.collections.optional import Optional
from std.ffi import _Global
from std.memory import alloc, OwnedPointer, Pointer, UnsafePointer
from std.time import perf_counter_ns

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.dict_interner import DictInterner, dict_merge_probe_add
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_buffer.shared_aligned_buffer import bridge_oab_to_sab
from komira_arrow.string_array import StringArray
from komira_buffer.byte_view import ByteView
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_async_api.worker_pool_traits import KeepAlive, Segment

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.sched_trace import SITE_CONCAT


# Batches per task below which another task is not worth a fork slot.
comptime _UNIFY_MIN_BATCHES_PER_TASK: Int = 8

comptime _UNIFY_MODE_INTERN: Int32 = 0
comptime _UNIFY_MODE_REMAP: Int32 = 1


# =============================================================================
# Route witness
# =============================================================================


def _init_unify_counter() -> OwnedPointer[AtomicI64]:
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _UNIFIED_COLS = _Global[
    "komira_concat_dict_unified_columns", _init_unify_counter,
]
comptime _DENSIFIED_COLS = _Global[
    "komira_concat_dict_densified_columns", _init_unify_counter,
]


def concat_dict_unified_count() raises -> Int:
    """Dictionary columns this module unified, process-wide."""
    # SAFETY: §6 FFI carve-out — `get_or_create_ptr` targets KGEN-runtime static
    # storage (process-lifetime); the wildcard is the stdlib `_Global` API's own
    # return type, confined to these helpers.
    var g = _UNIFIED_COLS.get_or_create_ptr()
    return Int(g[][].load())


def concat_dict_densified_count() raises -> Int:
    """Mixed dictionary/STRING columns this module densified, process-wide."""
    # SAFETY: §6 FFI carve-out (see `concat_dict_unified_count`).
    var g = _DENSIFIED_COLS.get_or_create_ptr()
    return Int(g[][].load())


def reset_concat_dict_unify_counters() raises:
    """Reset both counters to 0 (test setup)."""
    # SAFETY: §6 FFI carve-out (see `concat_dict_unified_count`).
    var g = _UNIFIED_COLS.get_or_create_ptr()
    g[][].store(Scalar[DType.int64](0))
    var h = _DENSIFIED_COLS.get_or_create_ptr()
    h[][].store(Scalar[DType.int64](0))


def _note(densified: Bool) raises:
    # SAFETY: §6 FFI carve-out (see `concat_dict_unified_count`).
    if densified:
        var h = _DENSIFIED_COLS.get_or_create_ptr()
        _ = h[][].fetch_add(Int64(1))
    else:
        var g = _UNIFIED_COLS.get_or_create_ptr()
        _ = g[][].fetch_add(Int64(1))


# =============================================================================
# The plan the rewrap consumes
# =============================================================================


struct DictUnifyPlan(Movable):
    """Which output columns to re-label as DICTIONARY, with what dictionary.
    Empty (`is_active() == False`) when nothing was unified."""

    var cols: List[Int]
    var fields: List[Field]
    var dict_offsets: List[List[Int32]]
    var dict_bytes: List[List[UInt8]]

    def __init__(out self):
        self.cols = List[Int]()
        self.fields = List[Field]()
        self.dict_offsets = List[List[Int32]]()
        self.dict_bytes = List[List[UInt8]]()

    def is_active(self) -> Bool:
        return len(self.cols) > 0


# =============================================================================
# Column classification
# =============================================================================

comptime _K_EMPTY: Int = 0  # zero rows: carries no layout constraint
comptime _K_SDICT: Int = 1  # STRING dictionary, Int32 codes
comptime _K_STRING: Int = 2  # plain STRING
comptime _K_OTHER: Int = 3  # anything else: leave the column alone


def _classify(c: Column[HeapRegion]) -> Int:
    if c.arrow_type == ArrowType.DICTIONARY:
        if c.is_string_dict() and c._dict_index_byte_width == 4:
            return _K_SDICT
        return _K_OTHER
    if c._length == 0:
        return _K_EMPTY
    if c.arrow_type == ArrowType.STRING:
        return _K_STRING
    return _K_OTHER


# =============================================================================
# Dispatch state + task
# =============================================================================


def _owned_li(var v: List[Int]) -> OwnedPointer[List[Int]]:
    var raw = alloc[List[Int]](1)
    raw.unsafe_write(v^)
    return OwnedPointer[List[Int]](unsafe_from_raw_pointer=raw)


def _owned_lli32(var v: List[List[Int32]]) -> OwnedPointer[List[List[Int32]]]:
    var raw = alloc[List[List[Int32]]](1)
    raw.unsafe_write(v^)
    return OwnedPointer[List[List[Int32]]](unsafe_from_raw_pointer=raw)


struct _UnifyState(KeepAlive, Movable):
    """Per-column dispatch state, shared by both passes.

    Disjointness:
      * MODE_INTERN — task `t` reads only its batches `[task_lo[t],
        task_lo[t+1])` and writes only slot `t` of `local` and the
        `local_remap` rows of its own batches.
      * MODE_REMAP — task `t` reads its batches and `task_map[t]`, and writes
        only the `out_cols` slots of its own batches.

    Liveness: the State lives on the driver stack across both `run_with_state`
    calls, whose fork-join barrier returns only after every worker finished.

    No-realloc: `local`, `local_remap`, `out_cols` and `task_map` are pre-sized
    before the dispatch that writes them and never change length inside one.
    """

    var batches: OwnedPointer[Slab[RecordBatch]]
    var local: OwnedPointer[Slab[DictInterner]]
    var local_remap: OwnedPointer[List[List[Int32]]]
    var task_map: OwnedPointer[List[List[Int32]]]
    var out_cols: OwnedPointer[Slab[Column[HeapRegion]]]
    var task_lo: OwnedPointer[List[Int]]
    var err_flag: OwnedPointer[AtomicI8]
    var err_msg: OwnedPointer[String]
    var col_idx: Int
    var seed_batch: Int

    def __init__(
        out self,
        var batches: Slab[RecordBatch],
        var task_lo: List[Int],
        col_idx: Int,
        seed_batch: Int,
    ):
        var nb = len(batches)
        var nt = len(task_lo) - 1
        var braw = alloc[Slab[RecordBatch]](1)
        braw.unsafe_write(batches^)
        self.batches = OwnedPointer[Slab[RecordBatch]](unsafe_from_raw_pointer=braw)
        var loc = Slab[DictInterner].create(nt)
        for _ in range(nt):
            loc.append(DictInterner())
        var lraw = alloc[Slab[DictInterner]](1)
        lraw.unsafe_write(loc^)
        self.local = OwnedPointer[Slab[DictInterner]](unsafe_from_raw_pointer=lraw)
        var lr = List[List[Int32]](capacity=nb)
        for _ in range(nb):
            lr.append(List[Int32]())
        self.local_remap = _owned_lli32(lr^)
        self.task_map = _owned_lli32(List[List[Int32]]())
        var oc = Slab[Column[HeapRegion]].create(nb)
        for _ in range(nb):
            oc.append(Column[HeapRegion]())
        var oraw = alloc[Slab[Column[HeapRegion]]](1)
        oraw.unsafe_write(oc^)
        self.out_cols = OwnedPointer[Slab[Column[HeapRegion]]](
            unsafe_from_raw_pointer=oraw
        )
        self.task_lo = _owned_li(task_lo^)
        var fraw = alloc[AtomicI8](1)
        fraw.unsafe_bitcast[Scalar[DType.int8]]().unsafe_write(Scalar[DType.int8](0))
        self.err_flag = OwnedPointer[AtomicI8](unsafe_from_raw_pointer=fraw)
        var smsg = alloc[String](1)
        smsg.unsafe_write(String(""))
        self.err_msg = OwnedPointer[String](unsafe_from_raw_pointer=smsg)
        self.col_idx = col_idx
        self.seed_batch = seed_batch


@fieldwise_init
struct _UnifyTask(Segment):
    """POD Segment for `_UnifyState`. `mode` selects the pass."""

    var mode: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY (PARALLELIZE-BOUNDARY):
        #   * Disjointness: task `t` owns batches [task_lo[t], task_lo[t+1]),
        #     slot `t` of `local`, and those batches' `local_remap` rows and
        #     `out_cols` slots; `batches` and `task_map` are only READ.
        #   * Liveness: State is on the driver stack across the fork-join
        #     barrier.
        #   * No-realloc: every written container was pre-sized before this
        #     dispatch.
        var sp = UnsafePointer(to=state).bitcast[_UnifyState]()
        try:
            if sp[].err_flag[].load() != Int8(0):
                return
            if self.mode == _UNIFY_MODE_REMAP:
                _remap_task(sp[], Int(task_id))
            else:
                _intern_task(sp[], Int(task_id))
        except e:
            var expected = Int8(0)
            if sp[].err_flag[].compare_exchange(expected, Int8(1)):
                sp[].err_msg[] = String(e)
            return


def _intern_task(mut st: _UnifyState, t: Int) raises:
    """Intern task `t`'s batches' dictionary entries in (batch, entry) order."""
    ref lo_hi = st.task_lo[]
    var b_lo = lo_hi[t]
    var b_hi = lo_hi[t + 1]
    var ci = st.col_idx
    ref interner = st.local[][t]
    ref batches = st.batches[]
    for b in range(b_lo, b_hi):
        ref c = batches[b].column_at(ci)
        if c.arrow_type != ArrowType.DICTIONARY:
            continue
        var d_size = c._dict_size
        var remap = List[Int32](capacity=d_size)
        var offs_view = c._offsets.value().view_ro()
        var offs = offs_view._unsafe_ptr().bitcast[Int32]()
        ref dd = c._dict_data.value()
        var seed = b == st.seed_batch
        for d in range(d_size):
            # SAFETY: `offs` holds d_size + 1 Int32 entries (a STRING
            # dictionary's value offsets), pinned by `offs_view`.
            var s = Int((offs + d)[])
            var n = Int((offs + d + 1)[]) - s
            if seed:
                # The seed batch keeps every entry at its own ordinal, a
                # repeated value included — exactly the fold's seed.
                remap.append(interner.seed_append(dd.view_ro().sub(s, n)))
            else:
                remap.append(interner.find_or_insert(dd.view_ro().sub(s, n)))
        _ = offs_view^
        st.local_remap[][b] = remap^


def _remap_task(mut st: _UnifyState, t: Int) raises:
    """Rewrite task `t`'s batches' codes to GLOBAL ids as INT32 columns."""
    ref lo_hi = st.task_lo[]
    var b_lo = lo_hi[t]
    var b_hi = lo_hi[t + 1]
    var ci = st.col_idx
    ref tmap = st.task_map[][t]
    ref batches = st.batches[]
    for b in range(b_lo, b_hi):
        ref c = batches[b].column_at(ci)
        var n = c._length
        if c.arrow_type != ArrowType.DICTIONARY:
            # A zero-row batch that carries some other layout.
            st.out_cols[][b] = _empty_int32()
            continue
        ref lrm = st.local_remap[][b]
        var d_size = len(lrm)
        var gmap = List[Int32](capacity=d_size)
        for d in range(d_size):
            gmap.append(tmap[Int(lrm[d])])
        var buf = OwnedAlignedBuffer(max(n * 4, 1))
        buf.set_length(Int64(n * 4))
        var out_view = buf.view_mut()
        var out = out_view._unsafe_ptr().bitcast[Int32]()
        var in_view = c._data.view_ro()
        var codes = in_view._unsafe_ptr().bitcast[Int32]() + c._offset
        var gptr = gmap.unsafe_ptr()
        var has_nulls = c._null_count > 0 and Bool(c._validity)
        if not has_nulls:
            for r in range(n):
                # SAFETY: `r` < n == the column's window length; `codes` is
                # advanced to `_offset` and pinned by `in_view`; `out` holds n.
                var code = Int((codes + r)[])
                if code < 0 or code >= d_size:
                    raise Error(
                        "concat_dict_unify: a dictionary code lies outside its"
                        " batch's dictionary (size " + String(d_size) + ")"
                    )
                (out + r)[] = (gptr + code)[]
        else:
            ref vb = c._validity.value()
            for r in range(n):
                # SAFETY: as above. A NULL row's code is never dereferenced —
                # it may be anything — and is written as 0.
                if not vb.test(c._offset + r):
                    (out + r)[] = Int32(0)
                    continue
                var code = Int((codes + r)[])
                if code < 0 or code >= d_size:
                    raise Error(
                        "concat_dict_unify: a dictionary code lies outside its"
                        " batch's dictionary (size " + String(d_size) + ")"
                    )
                (out + r)[] = (gptr + code)[]
        _ = in_view^
        _ = out_view^
        st.out_cols[][b] = Column[HeapRegion](
            arrow_type=ArrowType.INT32,
            data=buf^,
            offsets=Optional[OwnedAlignedBuffer](None),
            validity=_window_validity(c),
            length=n,
            null_count=c._null_count,
            offset=0,
        )


def _empty_int32() -> Column[HeapRegion]:
    var buf = OwnedAlignedBuffer(1)
    buf.set_length(Int64(0))
    return Column[HeapRegion](
        arrow_type=ArrowType.INT32,
        data=buf^,
        offsets=Optional[OwnedAlignedBuffer](None),
        validity=Optional[Bitmap[HeapRegion]](None),
        length=0,
        null_count=0,
        offset=0,
    )


def _window_validity(c: Column[HeapRegion]) -> Optional[Bitmap[HeapRegion]]:
    """`c`'s validity for its window `[_offset, _offset + _length)`, rebased
    to bit 0. None when the column carries no bitmap."""
    if not c._validity:
        return None
    ref vb = c._validity.value()
    if c._offset == 0:
        return Optional(vb.share())
    var n = c._length
    var bm = Bitmap.create(n)
    var nb = (n + 7) >> 3
    if nb > 0:
        bm.buffer.view_range_mut(0, nb).fill(0xFF)
    bm.buffer.set_length(nb)
    for r in range(n):
        if not vb.test(c._offset + r):
            bm.clear(r)
    return Optional(bm^)


# =============================================================================
# Densify (the MIXED case): a STRING dictionary column -> a plain STRING column
# =============================================================================


def _densify(c: Column[HeapRegion]) raises -> Column[HeapRegion]:
    """Resolve every row of a STRING dictionary column to its bytes. A NULL
    row becomes a zero-length value with its validity bit clear (its code is
    never dereferenced) — the layout `_dict_to_string_array` + its null
    expansion produce on the `preserve_dict=False` decode."""
    var n = c._length
    var d_size = c._dict_size
    var offs_view = c._offsets.value().view_ro()
    var offs = offs_view._unsafe_ptr().bitcast[Int32]()
    var dd_view = c._dict_data.value().view_ro()
    var dd = dd_view._unsafe_ptr()
    var in_view = c._data.view_ro()
    var codes = in_view._unsafe_ptr().bitcast[Int32]() + c._offset
    var has_nulls = c._null_count > 0 and Bool(c._validity)
    var total = 0
    for r in range(n):
        if has_nulls and not c._validity.value().test(c._offset + r):
            continue
        var code = Int((codes + r)[])
        if code < 0 or code >= d_size:
            raise Error(
                "concat_dict_unify: a dictionary code lies outside its"
                " batch's dictionary (size " + String(d_size) + ")"
            )
        total += Int((offs + code + 1)[]) - Int((offs + code)[])
    var out_offs = OwnedAlignedBuffer((n + 1) * 4)
    out_offs.set_length(Int64((n + 1) * 4))
    var oo_view = out_offs.view_mut()
    var oo = oo_view._unsafe_ptr().bitcast[Int32]()
    var out_data = OwnedAlignedBuffer(max(total, 1))
    out_data.set_length(Int64(total))
    var od_view = out_data.view_mut()
    var od = od_view._unsafe_ptr()
    var pos = 0
    (oo + 0)[] = Int32(0)
    for r in range(n):
        if has_nulls and not c._validity.value().test(c._offset + r):
            (oo + r + 1)[] = Int32(pos)
            continue
        var code = Int((codes + r)[])
        var s = Int((offs + code)[])
        var e = Int((offs + code + 1)[])
        for i in range(e - s):
            (od + pos + i)[] = (dd + s + i)[]
        pos += e - s
        (oo + r + 1)[] = Int32(pos)
    _ = oo_view^
    _ = od_view^
    _ = offs_view^
    _ = dd_view^
    _ = in_view^
    return Column[HeapRegion](
        arrow_type=ArrowType.STRING,
        data=out_data^,
        offsets=Optional[OwnedAlignedBuffer](out_offs^),
        validity=_window_validity(c),
        length=n,
        null_count=c._null_count,
        offset=0,
    )


def densify_string_dict_columns(var batch: RecordBatch) raises -> RecordBatch:
    """`batch` with every STRING-dictionary column resolved to a plain STRING
    column (and its schema field to STRING). Numeric dictionaries and every
    other column are left untouched; a batch with no string dictionary is
    returned as is. The fallback for an arm that cannot read DICTIONARY keys
    (`distinct_node_exec._cd_dict_batch_for_route`)."""
    var out = batch^
    for ci in range(out.num_columns()):
        if not out.column_at(ci).is_string_dict():
            continue
        var dense = _densify(out.column_at(ci))
        var fld = out.schema.field_at(ci)
        out = _replace_column(
            out^, ci, dense^, Field(fld.name, ArrowType.STRING, fld.nullable)
        )
    return out^


# =============================================================================
# Batch surgery
# =============================================================================


def _schema_with_field(b: RecordBatch, ci: Int, var field: Field) raises -> Schema:
    """`b`'s schema with field `ci` replaced by `field`."""
    var sb = SchemaBuilder()
    for j in range(b.num_columns()):
        if j == ci:
            sb.add_field(field.copy())
        else:
            sb.add_field(b.schema.field_at(j))
    return sb.build()


def _replace_column_with_schema(
    var b: RecordBatch, ci: Int, var col: Column[HeapRegion], var schema: Schema
) raises -> RecordBatch:
    """`b` with column `ci` replaced by `col`, stamped with `schema` (built
    ONCE per column by the caller — `field_at` reconstruction per batch was
    the cost here); every other column is moved across unchanged."""
    var nc = b.num_columns()
    var cols = b.take_columns()
    _ = cols.replace(ci, col^)
    var rbb = RecordBatchBuilder.with_capacity(nc)
    for j in range(nc):
        rbb.add_column(cols.take_slot_unchecked(j))
    cols.set_len_unchecked(0)
    return rbb.build(schema^)


def _replace_column(
    var b: RecordBatch, ci: Int, var col: Column[HeapRegion], var field: Field
) raises -> RecordBatch:
    """`b` with column `ci` replaced by `col` and its schema field by `field`;
    every other column is moved across unchanged."""
    var schema = _schema_with_field(b, ci, field^)
    return _replace_column_with_schema(b^, ci, col^, schema^)


# =============================================================================
# Entry points
# =============================================================================


def unify_string_dict_columns(
    mut batches: Slab[RecordBatch],
    mut dispatcher: LocalDispatcher[NoopSink],
    enabled: Bool = True,
    trace: Bool = False,
) raises -> DictUnifyPlan:
    """Unify (or, for a mixed column, densify) every STRING-dictionary column
    of `batches` IN PLACE so the concat can treat it as INT32 codes. Returns
    the plan `rewrap_unified_dict_columns` needs; inactive when nothing was
    unified (a densified column needs no rewrap: it is STRING throughout).

    Args:
        batches: The batches to unify in place.
        dispatcher: The dispatcher whose pool runs the unify fork.
        enabled: DEFAULT ON. False returns an inactive plan, which restores the
            pair-wise fold: the byte-equivalence oracle this module's test
            compares against.
        trace: Print the unify phase timings.
    """
    var plan = DictUnifyPlan()
    var nb = len(batches)
    if nb < 2 or not enabled:
        return plan^
    var schema_idx = -1
    for i in range(nb):
        if batches[i].has_selection_mask():
            return plan^
        if schema_idx < 0 and batches[i].num_rows() > 0:
            schema_idx = i
    if schema_idx < 0:
        return plan^
    var nc = batches[schema_idx].num_columns()
    for i in range(nb):
        if batches[i].num_columns() != nc:
            return plan^
    var _trace = trace

    for ci in range(nc):
        # Classify the column across every batch.
        var n_sdict = 0
        var n_string = 0
        var n_other = 0
        var seed = -1
        for i in range(nb):
            var k = _classify(batches[i].column_at(ci))
            if k == _K_SDICT:
                n_sdict += 1
                if seed < 0:
                    seed = i
            elif k == _K_STRING:
                n_string += 1
            elif k == _K_OTHER:
                n_other += 1
        if n_sdict == 0 or n_other > 0:
            continue
        var fld = batches[schema_idx].schema.field_at(ci)
        if n_string > 0:
            # MIXED: densify every dictionary batch; the concat then sees STRING.
            var sschema = _schema_with_field(
                batches[schema_idx], ci,
                Field(fld.name, ArrowType.STRING, fld.nullable),
            )
            for i in range(nb):
                if batches[i].column_at(ci).arrow_type == ArrowType.DICTIONARY:
                    var dense = _densify(batches[i].column_at(ci))
                    var bi = batches.replace(i, RecordBatch())
                    batches[i] = _replace_column_with_schema(
                        bi^, ci, dense^, sschema.copy()
                    )
            _note(True)
            continue

        var _t0 = Int(perf_counter_ns()) if _trace else 0
        # Task ranges over BATCHES.
        var workers = dispatcher.worker_count()
        var T = nb // _UNIFY_MIN_BATCHES_PER_TASK
        if T > workers:
            T = workers
        if T < 1:
            T = 1
        var task_lo = List[Int](capacity=T + 1)
        task_lo.append(0)
        for t in range(1, T):
            task_lo.append((nb * t) // T)
        task_lo.append(nb)

        var moved = Slab[RecordBatch]()
        swap(moved, batches)
        var state = _UnifyState(moved^, task_lo^, ci, seed)

        # ---- pass 1: local interning per batch range ----
        # PARALLELIZE-BOUNDARY: see `_UnifyTask.execute`.
        var back1 = dispatcher.run_with_state[_UnifyState, _UnifyTask](
            state, _UnifyTask(_UNIFY_MODE_INTERN), T,
            CancellationToken.never(), site_id=SITE_CONCAT,
        )
        _ = back1^
        if state.err_flag[].load() != Int8(0):
            swap(state.batches[], batches)
            raise Error(String(state.err_msg[]))
        var _t1 = Int(perf_counter_ns()) if _trace else 0

        # ---- the merge: serial, in TASK order ----
        # Task 0's interner starts the global one (it holds the seed batch,
        # which is the first dictionary batch, hence in task 0's range or,
        # when task 0's batches carry no dictionary, the first task that
        # has one — every earlier task interned nothing).
        var global_i = DictInterner()
        var tmaps = List[List[Int32]](capacity=T)
        var probes = 0
        var started = False
        for t in range(T):
            var li_size = state.local[][t].size()
            var m = List[Int32](capacity=li_size)
            if not started and li_size > 0:
                # Adopt this task's interner wholesale: identity map.
                for j in range(li_size):
                    m.append(Int32(j))
                global_i = state.local[].replace(t, DictInterner())
                started = True
            else:
                ref li = state.local[][t]
                ref lb = li.bytes()
                ref lo = li.offsets()
                var lp = lb.unsafe_ptr()
                for j in range(li_size):
                    var s = Int(lo[j])
                    var e = Int(lo[j + 1])
                    # SAFETY: [s, e) is entry j's span inside the task's
                    # arena `lb`, which is not touched while the global
                    # interner (a different List) grows.
                    m.append(global_i.find_or_insert(ByteView(lp + s, e - s)))
                probes += li.probes()
            tmaps.append(m^)
        probes += global_i.probes()
        dict_merge_probe_add(probes)
        state.task_map[] = tmaps^
        var _t2 = Int(perf_counter_ns()) if _trace else 0

        # ---- pass 2: codes -> global ids, as INT32 columns ----
        # PARALLELIZE-BOUNDARY: see `_UnifyTask.execute`.
        var back2 = dispatcher.run_with_state[_UnifyState, _UnifyTask](
            state, _UnifyTask(_UNIFY_MODE_REMAP), T,
            CancellationToken.never(), site_id=SITE_CONCAT,
        )
        _ = back2^
        swap(state.batches[], batches)
        if state.err_flag[].load() != Int8(0):
            raise Error(String(state.err_msg[]))

        # The INT32 codes go into each batch IN PLACE — a column slot swap,
        # no batch rebuild. The batch SCHEMA keeps its DICTIONARY field: the
        # concat routes every kernel on the COLUMN's arrow_type and reads the
        # input schema only to CAPTURE the output fields, and
        # `rewrap_unified_dict_columns` turns the concatenated INT32 column
        # back into the DICTIONARY that field describes. (Rebuilding 814
        # batches through `RecordBatchBuilder.build` + a Schema copy each cost
        # 5-7 ms of serial driver time on cbq10 — the benchmark host probe, CONCATDICT
        # remap_ms.)
        for i in range(nb):
            batches[i]._columns[ci] = state.out_cols[].replace(
                i, Column[HeapRegion]()
            )
        plan.cols.append(ci)
        plan.fields.append(fld^)
        plan.dict_offsets.append(global_i.offsets().copy())
        plan.dict_bytes.append(global_i.bytes().copy())
        _note(False)
        if _trace:
            var _t3 = Int(perf_counter_ns())
            print(
                "CONCATDICT col=", ci, " batches=", nb, " T=", T,
                " merged=", global_i.size(),
                " intern_ms=", Float64(_t1 - _t0) / 1.0e6,
                " merge_ms=", Float64(_t2 - _t1) / 1.0e6,
                " remap_ms=", Float64(_t3 - _t2) / 1.0e6,
                sep="",
            )
        _ = state^
    return plan^


def rewrap_unified_dict_columns(
    var batch: RecordBatch, var plan: DictUnifyPlan, restore_fields: Bool
) raises -> RecordBatch:
    """Re-label each unified column's concatenated INT32 codes as ONE
    DICTIONARY column carrying the merged dictionary (no copy of the codes).
    `restore_fields` puts the original DICTIONARY field back into the schema
    (False when the caller stamped an authoritative schema of its own)."""
    if not plan.is_active():
        return batch^
    var nc = batch.num_columns()
    var out = batch^
    for p in range(len(plan.cols)):
        var ci = plan.cols[p]
        if ci >= nc:
            continue
        ref codes_col = out.column_at(ci)
        if codes_col.arrow_type != ArrowType.INT32:
            raise Error(
                "concat_dict_unify: a unified column came back from the concat"
                " as " + String(codes_col.arrow_type) + ", not INT32 codes"
            )
        var dcol = codes_col.share()
        dcol.arrow_type = ArrowType.DICTIONARY
        var n_entries = len(plan.dict_offsets[p]) - 1
        var ob = OwnedAlignedBuffer((n_entries + 1) * 4)
        ob.copy_from_int32_list(plan.dict_offsets[p])
        ob.set_length(Int64((n_entries + 1) * 4))
        dcol._offsets = Optional(bridge_oab_to_sab[HeapRegion](ob^))
        var nbytes = len(plan.dict_bytes[p])
        var db = OwnedAlignedBuffer(max(nbytes, 1))
        db.copy_from_bytes_list(plan.dict_bytes[p])
        db.set_length(Int64(nbytes))
        dcol._set_dict_data_from_oab(db^)
        dcol._dict_size = n_entries
        dcol._dict_index_byte_width = 4
        var field: Field
        if restore_fields:
            field = plan.fields[p].copy()
        else:
            field = out.schema.field_at(ci)
        out = _replace_column(out^, ci, dcol^, field^)
    return out^
