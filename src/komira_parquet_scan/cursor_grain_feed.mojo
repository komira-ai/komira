# =============================================================================
# cursor_grain_feed — decode a claimed row group one grain at a time
# =============================================================================
#
# Three granularities meet in a Parquet scan: the ROW GROUP (I/O and
# statistics pruning), the PAGE (decompression) and the GRAIN (decode and
# compute, which should fit the cache). The whole-row-group route decodes a
# claimed row group into full-column buffers and only then slices morsels, so
# every buffer between decompression and the consumer is row-group sized.
#
# Here a worker still claims a whole row group, but opens one column cursor
# per projected column at row 0 and produces ONE grain-sized batch per
# `next_morsel` call (`cursor_grain_next`), keeping the cursors live between
# calls until the row group is done. The cursor decompresses one page at a
# time. There is no seek: every cursor walks forward, so a row group costs
# exactly its N values at any grain (unlike splitting it into row ranges,
# where each range must skip to its start).
#
# A grain is filled and consumed inside one iteration of the driver's pull
# loop; the per-worker fill buffers are fixed and reused.
#
# The grain (`cursor_grain_rows`): the smaller of the caller's morsel size and
# half the L3 cache split across the workers (each holding one live grain,
# with a 2.5x live-set multiplier), clamped to [1,024, 65,536] rows and
# rounded down to a power of two. The L3 size comes from the caller's host
# profile, so equal profiles give equal grains.
#
# A flat column's grain can be decoded straight into a buffer the column then
# takes over (`grain_decode_move`); dictionary columns are resolved.
#
# Gate: `cursor_grain_enabled`, default OFF, set with
# `set_cursor_grain_enabled`. Counters (always on): row groups opened on the
# cursor route, grains emitted, row groups declined to the whole-row-group
# decode, and the rows and calls of each decode route, from which
# `whole_observed_grain` / `grain_observed_grain` give the grain each route
# actually ran at. `cursor_grain_trace_dump` prints them when
# `set_cursor_grain_trace_enabled(True)`.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc

from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_engine_runtime.hardware import DEFAULT_L3_BYTES
from komira_fs.file_system import FileSystem
from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.subrg_column_cursor import ResumableColumnCursor, SUBRG_MAX_RUN
from komira_parquet_api.metadata import RowGroup, SchemaElement
from komira_parquet_api.types import FieldRepetitionType, ParquetType

from .cursor_grain_split_emit import (
    cursor_grain_nosplit_grains,
    cursor_grain_observed_emit,
    cursor_grain_split_enabled,
    cursor_grain_split_grains,
)
from .grain_decode_move import (
    grain_decode_move_enabled,
    grain_move_trace_dump,
    incr_grain_dict_resolve,
    incr_grain_flat_copy,
    incr_grain_flat_move,
)
from .parquet_reader import ParquetReader
from .subrg_columns import build_one_scan_col
from .subrg_cursor_feed import open_subrg_cursor
from .subrg_scan_executor import SubrgScanPlan
from .subrg_split_decode import resolved_arrow_type


comptime CURSOR_GRAIN_MIN_ROWS: Int = 1024
comptime CURSOR_GRAIN_MAX_ROWS: Int = 65536
# The live set per grain row is about 2.5 rows' bytes (the fixed buffers and
# the built column).
comptime CURSOR_GRAIN_LIVE_MULT_NUM: Int = 5
comptime CURSOR_GRAIN_LIVE_MULT_DEN: Int = 2


@always_inline
def _ptype_width(ptype: ParquetType) -> Int:
    if ptype == ParquetType.INT64 or ptype == ParquetType.DOUBLE:
        return 8
    return 4


def cursor_grain_rows(row_width_bytes: Int, num_workers: Int, policy_rows_hint: Int, l3_cache_bytes: Int) -> Int:
    """The decode grain in rows: `min(policy_rows_hint, ((L3 / 2) /
    num_workers) / (row_width * 2.5))`, clamped to [`CURSOR_GRAIN_MIN_ROWS`,
    `CURSOR_GRAIN_MAX_ROWS`] and rounded down to a power of two.
    `row_width_bytes` sums the projected columns only; a non-positive
    `policy_rows_hint` sets no bound and a non-positive `l3_cache_bytes`
    stands for `DEFAULT_L3_BYTES`."""
    var row_w = row_width_bytes if row_width_bytes > 0 else 1
    var nw = num_workers if num_workers > 0 else 1
    var l3 = l3_cache_bytes if l3_cache_bytes > 0 else DEFAULT_L3_BYTES
    var per_worker_budget = (l3 // 2) // nw
    var rows = (per_worker_budget * CURSOR_GRAIN_LIVE_MULT_DEN) // (row_w * CURSOR_GRAIN_LIVE_MULT_NUM)
    if policy_rows_hint > 0 and policy_rows_hint < rows:
        rows = policy_rows_hint
    rows = max(min(rows, CURSOR_GRAIN_MAX_ROWS), CURSOR_GRAIN_MIN_ROWS)
    var po2 = CURSOR_GRAIN_MIN_ROWS
    while po2 * 2 <= rows:
        po2 *= 2
    return po2


struct CursorGrainRg(Movable, Deinitable):
    """One worker's live decode state for one row group, kept across
    `next_morsel` calls. It owns its cursors (which own their chunk bytes)
    and the row group's dictionaries, decoded once and borrowed by every
    grain.

    Fields:
        claimed_rg: the source's flat row group index (for the morsel ids).
        grain_idx: grains emitted so far.
        rows_done / rows_total: progress; `rows_total == -1` is inactive.
    """

    var cursors: Slab[ResumableColumnCursor]
    var dict_i: List[List[Int64]]
    var dict_f: List[List[Float64]]
    var claimed_rg: Int
    var grain_idx: Int
    var rows_done: Int
    var rows_total: Int

    def __init__(out self):
        """The inactive state."""
        self.cursors = Slab[ResumableColumnCursor]()
        self.dict_i = List[List[Int64]]()
        self.dict_f = List[List[Float64]]()
        self.claimed_rg = -1
        self.grain_idx = 0
        self.rows_done = 0
        self.rows_total = -1

    @always_inline
    def active(self) -> Bool:
        """A row group is open and not done."""
        return self.rows_total >= 0 and self.rows_done < self.rows_total

    def deactivate(mut self) -> None:
        """Drop the cursors and dictionaries (a worker never holds two row
        groups' chunks)."""
        self.cursors = Slab[ResumableColumnCursor]()
        self.dict_i = List[List[Int64]]()
        self.dict_f = List[List[Float64]]()
        self.claimed_rg = -1
        self.grain_idx = 0
        self.rows_done = 0
        self.rows_total = -1


def _chunk_has_no_null(rg: RowGroup, schema: List[SchemaElement], col_idx: Int) -> Bool:
    """Column `col_idx` of `rg` is REQUIRED, or its statistics say it holds
    no null."""
    if col_idx < 0 or col_idx >= len(rg.columns) or col_idx + 1 >= len(schema):
        return False
    ref elem = schema[col_idx + 1]
    if elem.repetition_type and elem.repetition_type.value() == FieldRepetitionType.REQUIRED:
        return True
    ref md = rg.columns[col_idx].meta_data
    if not md.statistics:
        return False
    ref stats = md.statistics.value()
    return Bool(stats.null_count) and stats.null_count.value() == 0


def cursor_grain_open[FS: FileSystem](
    reader: ParquetReader[FS],
    rg_idx: Int,
    claimed_rg: Int,
    plan: SubrgScanPlan,
    meta_schema: List[SchemaElement],
    mut st: CursorGrainRg,
) raises -> Bool:
    """Open the cursors of row group `rg_idx` at row 0 into `st`. False
    (with `st` inactive) when a column may hold a null, is refused, is a
    string dictionary, or does not hold every row of the row group: the
    caller decodes that row group whole. All of it is checked here, before
    any grain is emitted, because a short fill after the first grain could
    not be declined."""
    st.deactivate()
    var n_cols = len(plan.proj_names)
    if n_cols == 0 or rg_idx < 0 or rg_idx >= len(reader._meta[].row_groups):
        return False
    ref rg = reader._meta[].row_groups[rg_idx]
    var rg_rows = Int(rg.num_rows)
    if rg_rows <= 0:
        return False
    # A null in a later page is met only mid-row-group, after grains are
    # out, where nothing can be declined: a column that may hold a null is
    # refused here, from its statistics.
    for ci in range(n_cols):
        if not _chunk_has_no_null(rg, meta_schema, plan.reader_col_idx[ci]):
            return False
    var cursors = Slab[ResumableColumnCursor].create(n_cols)
    for ci in range(n_cols):
        cursors.append(open_subrg_cursor(reader._file, rg, meta_schema, plan.reader_col_idx[ci]))
    for ci in range(n_cols):
        if not cursors[ci].supported() or cursors[ci].num_values() != rg_rows or cursors[ci].is_string_dict():
            return False
    var dict_i = List[List[Int64]]()
    var dict_f = List[List[Float64]]()
    for ci in range(n_cols):
        if cursors[ci].is_dict() and cursors[ci].value_is_float():
            dict_i.append(List[Int64]())
            dict_f.append(cursors[ci].dict_values_f64_copy())
        elif cursors[ci].is_dict():
            dict_i.append(cursors[ci].dict_values_copy())
            dict_f.append(List[Float64]())
        else:
            dict_i.append(List[Int64]())
            dict_f.append(List[Float64]())
    st.cursors = cursors^
    st.dict_i = dict_i^
    st.dict_f = dict_f^
    st.claimed_rg = claimed_rg
    st.rows_total = rg_rows
    incr_cursor_grain_rg()
    return True


def _build_flat_col_moved(var vbuf: OwnedAlignedBuffer, n_rows: Int, ptype: ParquetType) raises -> Column[HeapRegion]:
    """A flat grain column over the buffer the cursor filled (it must hold
    exactly `n_rows` values): the bytes and fields the copy arm would build,
    without the copy."""
    vbuf.set_length(Int64(n_rows * _ptype_width(ptype)))
    return Column[HeapRegion](
        arrow_type=resolved_arrow_type(ptype),
        data=SharedAlignedBuffer.from_owned(vbuf^),
        offsets=Optional[SharedAlignedBuffer[HeapRegion]](None),
        validity=None,
        length=n_rows,
        null_count=0,
        offset=0,
    )


def _grain_short_fill_error(st: CursorGrainRg, ci: Int, v_total: Int, n_grain: Int) -> Error:
    """A column filled short after its row group passed the completeness
    check at open: a cursor defect, raised rather than emitted (an earlier
    grain of the row group is already out)."""
    return Error(
        "cursor grain: column " + String(ci) + " filled " + String(v_total) + " of " + String(n_grain)
        + " rows at row group " + String(st.claimed_rg) + " grain " + String(st.grain_idx)
    )


def _fill_lockstep(mut cur: ResumableColumnCursor, mut buf: OwnedAlignedBuffer, n: Int, codes: Bool) raises -> Int:
    var v_total = 0
    while v_total < n:
        var nv: Int
        if codes:
            nv = cur.fill_next_codes_at(buf, n - v_total, v_total)
        else:
            nv = cur.fill_next_flat(buf, n - v_total, v_total)
        if nv == 0:
            break
        v_total += nv
    return v_total


def cursor_grain_next(
    mut st: CursorGrainRg,
    plan: SubrgScanPlan,
    chunk_schema: Schema,
    mut ctx: ColumnDecodeContext,
    grain_rows: Int,
) raises -> Optional[RecordBatch]:
    """The next grain of the open row group, or None once it is done (which
    also deactivates `st`). The first column's fill sets the grain's rows and
    every other column fills to the same count. A flat column takes the move
    arm when `grain_decode_move_enabled()`; every other column is decoded into
    the worker's fixed buffers and built by copy or dictionary resolve. Both
    arms give the same grains and the same bytes.

    Raises:
        If a column fills short (see `_grain_short_fill_error`).
    """
    if not st.active():
        st.deactivate()
        return None
    var n_cols = len(plan.proj_names)
    var move_on = grain_decode_move_enabled()
    var need_bytes = (grain_rows + SUBRG_MAX_RUN) * 8
    ctx.ensure_subrg_codes(need_bytes)
    ctx.ensure_subrg_value(need_bytes)
    var want = min(grain_rows, st.rows_total - st.rows_done)
    var drv_is_dict = st.cursors[0].is_dict()
    var drv_ptype = st.cursors[0].value_ptype()
    var drv_move = move_on and not drv_is_dict
    var n_grain: Int
    var drv_buf = Optional[OwnedAlignedBuffer](None)
    if drv_move:
        var b = OwnedAlignedBuffer(want * _ptype_width(drv_ptype))
        n_grain = st.cursors[0].fill_next_flat(b, want, 0)
        drv_buf = Optional(b^)
    elif drv_is_dict:
        n_grain = st.cursors[0].fill_next_codes(ctx.subrg_codes_ref(), want)
    else:
        n_grain = st.cursors[0].fill_next_flat(ctx.subrg_codes_ref(), want, 0)
    if n_grain == 0:
        # The driver stopped before the row group's last row: a cursor defect
        # (the row group passed the checks at open), raised rather than read
        # as the end of the row group.
        raise _grain_short_fill_error(st, 0, 0, want)
    var rbb = RecordBatchBuilder.with_capacity(n_cols)
    if drv_move:
        incr_grain_flat_move(n_grain * _ptype_width(drv_ptype))
        rbb.add_column(_build_flat_col_moved(drv_buf.take(), n_grain, drv_ptype))
    else:
        _note_copy_arm_col(drv_is_dict, n_grain, drv_ptype)
        rbb.add_column(
            build_one_scan_col(
                ctx.subrg_codes_ref(), n_grain, n_grain, drv_is_dict, st.cursors[0].value_is_float(), drv_ptype,
                st.dict_i[0], st.dict_f[0],
            )
        )
    for ci in range(1, n_cols):
        var is_dict = st.cursors[ci].is_dict()
        var ptype = st.cursors[ci].value_ptype()
        if move_on and not is_dict:
            var vb = OwnedAlignedBuffer(n_grain * _ptype_width(ptype))
            var v_moved = _fill_lockstep(st.cursors[ci], vb, n_grain, False)
            if v_moved != n_grain:
                raise _grain_short_fill_error(st, ci, v_moved, n_grain)
            incr_grain_flat_move(n_grain * _ptype_width(ptype))
            rbb.add_column(_build_flat_col_moved(vb^, n_grain, ptype))
            continue
        var v_total = _fill_lockstep(st.cursors[ci], ctx.subrg_value_ref(), n_grain, is_dict)
        if v_total != n_grain:
            raise _grain_short_fill_error(st, ci, v_total, n_grain)
        _note_copy_arm_col(is_dict, n_grain, ptype)
        rbb.add_column(
            build_one_scan_col(
                ctx.subrg_value_ref(), n_grain, v_total, is_dict, st.cursors[ci].value_is_float(), ptype,
                st.dict_i[ci], st.dict_f[ci],
            )
        )
    st.rows_done += n_grain
    st.grain_idx += 1
    incr_cursor_grain_emit()
    note_grain_decode(n_grain)
    var batch = rbb.build(chunk_schema.copy())
    if st.rows_done >= st.rows_total:
        st.deactivate()
    return Optional(batch^)


def _note_copy_arm_col(is_dict: Bool, n_rows: Int, ptype: ParquetType) raises:
    """Count one column built by copy (flat) or dictionary resolve."""
    var payload = n_rows * _ptype_width(ptype)
    if is_dict:
        incr_grain_dict_resolve(payload)
    else:
        incr_grain_flat_copy(payload)


# -----------------------------------------------------------------------------
# Gate and counters
# -----------------------------------------------------------------------------


def _init_cursor_grain_slot() -> OwnedPointer[AtomicI64]:
    """`_Global` init function: one zeroed counter per process."""
    var raw = alloc[AtomicI64](1)
    # SAFETY: `raw` is the one fresh allocation above; the scalar is written
    # in place before `OwnedPointer` takes ownership, and `raw` never leaves
    # this function.
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _C_CG_RG = _Global["komira_parquet_cursor_grain_rg", _init_cursor_grain_slot]
comptime _C_CG_EMIT = _Global["komira_parquet_cursor_grain_emit", _init_cursor_grain_slot]
comptime _C_CG_DECLINE = _Global["komira_parquet_cursor_grain_decline", _init_cursor_grain_slot]
comptime _C_WHOLE_ROWS = _Global["komira_parquet_decode_whole_rows", _init_cursor_grain_slot]
comptime _C_WHOLE_CALLS = _Global["komira_parquet_decode_whole_calls", _init_cursor_grain_slot]
comptime _C_GRAIN_ROWS = _Global["komira_parquet_decode_grain_rows", _init_cursor_grain_slot]
comptime _C_GRAIN_CALLS = _Global["komira_parquet_decode_grain_calls", _init_cursor_grain_slot]
comptime _G_CG_GATE = _Global["komira_parquet_gate_cursor_grain", _init_cursor_grain_slot]
comptime _G_CG_TRACE = _Global["komira_parquet_gate_cursor_grain_trace", _init_cursor_grain_slot]

comptime _GATE_ON: Int64 = 1
comptime _GATE_OFF: Int64 = 2


@always_inline
def incr_cursor_grain_rg() raises:
    """One row group whose columns all opened on the cursor route."""
    _ = _C_CG_RG.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_cursor_grain_emit() raises:
    """One grain emitted from live cursors."""
    _ = _C_CG_EMIT.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_cursor_grain_decline() raises:
    """One row group that fell back to the whole-row-group decode."""
    _ = _C_CG_DECLINE.get_or_create_ptr()[][].fetch_add(Int64(1))


def cursor_grain_rg_count() raises -> Int:
    """Row groups opened on the cursor route."""
    return Int(_C_CG_RG.get_or_create_ptr()[][].load())


def cursor_grain_emit_count() raises -> Int:
    """Grains emitted."""
    return Int(_C_CG_EMIT.get_or_create_ptr()[][].load())


def cursor_grain_decline_count() raises -> Int:
    """Row groups declined to the whole-row-group decode."""
    return Int(_C_CG_DECLINE.get_or_create_ptr()[][].load())


@always_inline
def note_whole_rg_decode(rows: Int) raises:
    """One whole-row-group decode of `rows` rows (every whole-row-group decode
    site of the morsel source calls this)."""
    _ = _C_WHOLE_ROWS.get_or_create_ptr()[][].fetch_add(Int64(rows))
    _ = _C_WHOLE_CALLS.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def note_grain_decode(rows: Int) raises:
    """One cursor grain of `rows` rows."""
    _ = _C_GRAIN_ROWS.get_or_create_ptr()[][].fetch_add(Int64(rows))
    _ = _C_GRAIN_CALLS.get_or_create_ptr()[][].fetch_add(Int64(1))


def whole_observed_grain() raises -> Int:
    """Rows per whole-row-group decode (0 when there was none)."""
    var calls = whole_decode_calls()
    return Int(_C_WHOLE_ROWS.get_or_create_ptr()[][].load()) // calls if calls > 0 else 0


def grain_observed_grain() raises -> Int:
    """Rows per cursor grain (0 when there was none)."""
    var calls = grain_decode_calls()
    return Int(_C_GRAIN_ROWS.get_or_create_ptr()[][].load()) // calls if calls > 0 else 0


def whole_decode_calls() raises -> Int:
    """Whole-row-group decodes."""
    return Int(_C_WHOLE_CALLS.get_or_create_ptr()[][].load())


def grain_decode_calls() raises -> Int:
    """Cursor grains."""
    return Int(_C_GRAIN_CALLS.get_or_create_ptr()[][].load())


def reset_cursor_grain_counts() raises:
    """Zero the counters (a test's setup)."""
    _C_CG_RG.get_or_create_ptr()[][].store(Int64(0))
    _C_CG_EMIT.get_or_create_ptr()[][].store(Int64(0))
    _C_CG_DECLINE.get_or_create_ptr()[][].store(Int64(0))
    _C_WHOLE_ROWS.get_or_create_ptr()[][].store(Int64(0))
    _C_WHOLE_CALLS.get_or_create_ptr()[][].store(Int64(0))
    _C_GRAIN_ROWS.get_or_create_ptr()[][].store(Int64(0))
    _C_GRAIN_CALLS.get_or_create_ptr()[][].store(Int64(0))


@always_inline
def cursor_grain_enabled() raises -> Bool:
    """The cursor-grain gate, default OFF."""
    return _G_CG_GATE.get_or_create_ptr()[][].load() == _GATE_ON


def set_cursor_grain_enabled(on: Bool) raises:
    """Turn the cursor-grain route on or off for the process."""
    _G_CG_GATE.get_or_create_ptr()[][].store(_GATE_ON if on else _GATE_OFF)


@always_inline
def cursor_grain_trace_enabled() raises -> Bool:
    """The trace print gate, default OFF."""
    return _G_CG_TRACE.get_or_create_ptr()[][].load() == _GATE_ON


def set_cursor_grain_trace_enabled(on: Bool) raises:
    """Turn the trace print on or off for the process."""
    _G_CG_TRACE.get_or_create_ptr()[][].store(_GATE_ON if on else _GATE_OFF)


def cursor_grain_trace_dump(site: StaticString) raises:
    """Print the `[grain-move]` line (under its own gate), then, when the
    trace is on, the decode grain of each route, the emitted grain and the
    split, open and decline counts. `cursor_grain=0` with the gate on means
    the route never fired."""
    grain_move_trace_dump(site)
    if not cursor_grain_trace_enabled():
        return
    print(
        "[cursor-grain] at=", site,
        " whole_grain=", whole_observed_grain(),
        " (calls=", whole_decode_calls(), ")",
        " cursor_grain=", grain_observed_grain(),
        " (calls=", grain_decode_calls(), ")",
        " emit_grain=", cursor_grain_observed_emit(),
        " split=", cursor_grain_split_grains(),
        " nosplit=", cursor_grain_nosplit_grains(),
        " rg=", cursor_grain_rg_count(),
        " emit=", cursor_grain_emit_count(),
        " decline=", cursor_grain_decline_count(),
        " | gate=", cursor_grain_enabled(),
        " split_gate=", cursor_grain_split_enabled(),
        sep="",
    )
