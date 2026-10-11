# =============================================================================
# subrg_agg_fold — one row group of the sub-row-group aggregate, chunk by chunk
# =============================================================================
#
# `fold_one_rg_subrg` decodes one row group through one column cursor per
# projected column into a worker's fixed buffers, builds each chunk's batch
# in projection order and hands it to the sink (`ScanChunkSink.consume_chunk`):
#
#   * the first group key (the driver) fills its dictionary codes and sets
#     the chunk's row count; every other column fills exactly that many rows
#     (lockstep), and a short fill declines the row group;
#   * each group key stays a dictionary column: a numeric key with the
#     dictionary values at its own width, a STRING key with its byte-backed
#     dictionary (no string array is built on a worker thread);
#   * every other column is resolved to flat INT64 / FLOAT64 values
#     (`subrg_agg_chunk_schema` states the rule the chunk schema follows).
#
# A WHERE predicate is applied per chunk:
#   * a predicate that reads only the one numeric key of a one-column chunk
#     is evaluated once over the row group's dictionary into a keep-table,
#     and each chunk's codes are compacted through it;
#   * an AND / OR tree of `column <cmp> literal` leaves is evaluated over the
#     dictionary-preserved chunk and its survivors gathered from it;
#   * any other predicate on a numeric-key chunk resolves the dictionary
#     columns to flat values and filters them (`batch_filter`);
#   * on a STRING-key chunk the predicate is evaluated with the numeric
#     dictionary columns resolved to flat values (the STRING dictionary is
#     kept); a chunk every row of which passes is folded and
#     a chunk no row of which passes is skipped; a chunk only some rows of
#     which pass declines the row group (filtering would build the string
#     column on the worker).
#
# The verdict says whether the decline came before or after the first chunk
# was handed to the sink. A fold cannot be retracted, so a decline after a
# chunk (DIRTY) must not be followed by a whole-row-group decode of the same
# row group: that would count the prefix twice.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema
from komira_batch_eval.conjunction import evaluate_filter_narrowed
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.byte_view import ByteView
from komira_collections.slab import Slab
from komira_fs.file_system import FileSystem
from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.subrg_column_cursor import ResumableColumnCursor
from komira_parquet_api.metadata import SchemaElement
from komira_plan_expr.expr import Expr

from .batch_filter import filter_batch_by_predicate, numeric_dict_cols_resolved
from .parquet_reader import ParquetReader
from .scan_chunk_sink import ScanChunkSink
from .subrg_agg_plan import CHUNK_ROWS, SubrgAggPlan
from .subrg_columns import build_flat_plain_col, resolve_flat_f64_col, resolve_flat_int64_col
from .subrg_cursor_feed import open_subrg_cursor
from .subrg_filter_gather import (
    build_dict_keep_lut,
    compact_codes_by_lut,
    gather_selected,
    pred_is_dict_select_safe,
    pred_refs_only_column,
    subrg_filter_record,
)


comptime FOLD_OK: Int = 1
"""The row group was folded completely through the cursors."""
comptime FOLD_DECLINED_CLEAN: Int = 0
"""Declined before any chunk reached the sink: a whole-row-group decode of it
is safe."""
comptime FOLD_DECLINED_DIRTY: Int = -1
"""Declined after a chunk reached the sink: the route must be abandoned."""


@always_inline
def _declined(chunk_idx: Int) -> Int:
    return FOLD_DECLINED_DIRTY if chunk_idx > 0 else FOLD_DECLINED_CLEAN


def _fill_to(mut cursor: ResumableColumnCursor, mut vbuf: OwnedAlignedBuffer, n_chunk: Int, codes: Bool) raises -> Int:
    """Fill `vbuf` with `n_chunk` rows of `cursor` (codes or flat values),
    calling the cursor until it has them or stops; the rows filled."""
    var v_total = 0
    while v_total < n_chunk:
        var want = n_chunk - v_total
        var nv: Int
        if codes:
            nv = cursor.fill_next_codes_at(vbuf, want, v_total)
        else:
            nv = cursor.fill_next_flat(vbuf, want, v_total)
        if nv == 0:
            break
        v_total += nv
    return v_total


def add_key_dict_col(
    mut rbb: RecordBatchBuilder,
    kview: ByteView[_],
    n_key: Int,
    var key_dict: List[Int64],
    arrow_type: ArrowType,
) raises:
    """Append a numeric dictionary key column of `n_key` int32 codes copied
    out of `kview`: an INT32 key's dictionary holds int32 values, any other
    key's int64 values. The codes are copied, so the buffer behind `kview` is
    free afterwards.

    Raises:
        If a code lies outside the dictionary.
    """
    if arrow_type == ArrowType.INT32:
        rbb.add_column(Column.from_numeric_dict_codes_view[DType.int32, DType.int32](kview, n_key, key_dict^))
    else:
        rbb.add_column(Column.from_numeric_dict_codes_view[DType.int32, DType.int64](kview, n_key, key_dict^))


def add_key_string_dict_col(
    mut rbb: RecordBatchBuilder,
    kview: ByteView[_],
    n_key: Int,
    str_offsets: List[Int32],
    str_bytes: List[UInt8],
) raises:
    """Append a STRING dictionary key column of `n_key` int32 codes copied out
    of `kview`, over a copy of the row group's byte-backed dictionary
    (`str_offsets` N+1 cumulative, `str_bytes` packed). No string array is
    built."""
    rbb.add_column(Column.from_string_dict_codes_view(kview, n_key, str_offsets.copy(), str_bytes.copy()))


def _key_pos(plan: SubrgAggPlan, ci: Int) -> Int:
    """The position of projection index `ci` in the plan's key list."""
    for k in range(len(plan.key_proj_idx)):
        if plan.key_proj_idx[k] == ci:
            return k
    return 0


def fold_one_rg_subrg[FS: FileSystem, SINK: ScanChunkSink](
    reader: ParquetReader[FS],
    rg_idx: Int,
    plan: SubrgAggPlan,
    chunk_schema: Schema,
    has_filter: Bool,
    filter_pred: Optional[Expr],
    mut ctx: ColumnDecodeContext,
    sink: SINK,
    mut local: SINK.WorkerLocal,
    meta_schema: List[SchemaElement],
) raises -> Int:
    """Fold row group `rg_idx` chunk by chunk into `local`. Returns
    `FOLD_OK`, `FOLD_DECLINED_CLEAN` or `FOLD_DECLINED_DIRTY`. `ctx`'s sub-row-
    group buffers must hold `SUBRG_SLOTS` codes and 8-byte values."""
    var n_cols = len(plan.proj_names)
    var n_keys = len(plan.key_proj_idx)
    ref rg = reader._meta[].row_groups[rg_idx]
    var cursors = Slab[ResumableColumnCursor].create(n_cols)
    for ci in range(n_cols):
        cursors.append(open_subrg_cursor(reader._file, rg, meta_schema, plan.reader_col_idx[ci]))
    for ci in range(n_cols):
        if not cursors[ci].supported():
            return FOLD_DECLINED_CLEAN
    # Every key must be dictionary encoded; a string dictionary only when the
    # plan says so (`is_dict()` is also True for a string dictionary, so the
    # string test comes first).
    for k in range(n_keys):
        ref kc = cursors[plan.key_proj_idx[k]]
        if kc.is_string_dict():
            if not plan.has_string_key:
                return FOLD_DECLINED_CLEAN
        elif not kc.is_dict() or kc.value_is_float():
            return FOLD_DECLINED_CLEAN

    var driver_key_ci = plan.key_proj_idx[0]
    var n_key_total = cursors[driver_key_ci].num_values()

    # Each key's dictionary, copied once per row group.
    var key_dicts = List[List[Int64]]()
    var key_is_string = List[Bool]()
    var key_str_offsets = List[List[Int32]]()
    var key_str_bytes = List[List[UInt8]]()
    for k in range(n_keys):
        ref kc = cursors[plan.key_proj_idx[k]]
        if kc.is_string_dict():
            key_is_string.append(True)
            key_dicts.append(List[Int64]())
            key_str_offsets.append(kc.str_dict_offsets_copy())
            key_str_bytes.append(kc.str_dict_bytes_copy())
        else:
            key_is_string.append(False)
            key_dicts.append(kc.dict_values_copy())
            key_str_offsets.append(List[Int32]())
            key_str_bytes.append(List[UInt8]())

    var dict_select_ok = (
        has_filter
        and filter_pred.__bool__()
        and not plan.has_string_key
        and pred_is_dict_select_safe(filter_pred.value())
    )
    var key_lut_ok = (
        dict_select_ok
        and n_cols == 1
        and n_keys == 1
        and (plan.col_arrow_types[0] == ArrowType.INT64 or plan.col_arrow_types[0] == ArrowType.INT32)
        and pred_refs_only_column(filter_pred.value(), plan.proj_names[0])
    )
    var key_lut = List[UInt8]()
    var key_lut_pass = 0
    if key_lut_ok:
        key_lut = build_dict_keep_lut(key_dicts[0], plan.proj_names[0], plan.col_arrow_types[0], filter_pred.value())
        for e in range(len(key_dicts[0])):
            key_lut_pass += Int(key_lut[e])
    var n_gathered = 0
    var n_skipped = 0
    var n_keylut = 0

    var chunk_idx = 0
    while True:
        ref codes_buf = ctx.subrg_codes_ref()
        var n_key = cursors[driver_key_ci].fill_next_codes(codes_buf, CHUNK_ROWS)
        if n_key == 0:
            break

        # The key keep-table: a dictionary every entry of which passes falls
        # through to the unfiltered fold below.
        if key_lut_ok and key_lut_pass < len(key_dicts[0]):
            if key_lut_pass == 0:
                n_skipped += 1
                chunk_idx += 1
                continue
            ref kbuf = ctx.subrg_value_ref()
            var n_surv = compact_codes_by_lut(codes_buf, n_key, key_lut, kbuf)
            if n_surv == 0:
                n_skipped += 1
                chunk_idx += 1
                continue
            if n_surv > 0:
                n_keylut += 1
                var krbb = RecordBatchBuilder.with_capacity(1)
                add_key_dict_col(
                    krbb, kbuf.view_range_ro(0, n_surv * 4), n_surv, key_dicts[0].copy(), plan.col_arrow_types[0]
                )
                sink.consume_chunk(local, rg_idx, chunk_idx, krbb.build(chunk_schema.copy()))
                chunk_idx += 1
                continue
            # n_surv < 0: a code outside the dictionary; the dictionary
            # column below refuses the chunk by name.

        var rbb = RecordBatchBuilder.with_capacity(n_cols)
        for ci in range(n_cols):
            if plan.is_key_proj(ci):
                var kpos = _key_pos(plan, ci)
                if ci == driver_key_ci:
                    var kview = codes_buf.view_range_ro(0, n_key * 4)
                    if key_is_string[kpos]:
                        add_key_string_dict_col(rbb, kview, n_key, key_str_offsets[kpos], key_str_bytes[kpos])
                    else:
                        add_key_dict_col(rbb, kview, n_key, key_dicts[kpos].copy(), plan.col_arrow_types[ci])
                else:
                    # A later key fills the value buffer (the driver's codes
                    # stay in the codes buffer until the driver is built).
                    ref kbuf = ctx.subrg_value_ref()
                    if _fill_to(cursors[ci], kbuf, n_key, True) != n_key:
                        return _declined(chunk_idx)
                    var kview = kbuf.view_range_ro(0, n_key * 4)
                    if key_is_string[kpos]:
                        add_key_string_dict_col(rbb, kview, n_key, key_str_offsets[kpos], key_str_bytes[kpos])
                    else:
                        add_key_dict_col(rbb, kview, n_key, key_dicts[kpos].copy(), plan.col_arrow_types[ci])
            else:
                ref vbuf = ctx.subrg_value_ref()
                var is_dict = cursors[ci].is_dict()
                # A short fill would leave rows the builders pad with entry 0
                # or 0, which the fold would count: decline instead.
                var v_total = _fill_to(cursors[ci], vbuf, n_key, is_dict)
                if v_total != n_key:
                    return _declined(chunk_idx)
                if is_dict and cursors[ci].value_is_float():
                    rbb.add_column(resolve_flat_f64_col(vbuf, n_key, v_total, cursors[ci].dict_values_f64_copy()))
                elif is_dict:
                    rbb.add_column(resolve_flat_int64_col(vbuf, n_key, v_total, cursors[ci].dict_values_copy()))
                else:
                    rbb.add_column(build_flat_plain_col(vbuf, n_key, v_total, cursors[ci].value_ptype()))

        var batch = rbb.build(chunk_schema.copy())
        if has_filter and filter_pred:
            var n_rows = batch.num_rows()
            if dict_select_ok:
                # The selection over the dictionary-preserved chunk is the
                # answer for this predicate shape.
                var sel = evaluate_filter_narrowed(batch, filter_pred.value())
                if sel.length() == n_rows:
                    sink.consume_chunk(local, rg_idx, chunk_idx, batch^)
                elif sel.length() == 0:
                    n_skipped += 1
                    _ = batch^
                else:
                    n_gathered += 1
                    var survivors = gather_selected(batch, sel)
                    _ = batch^
                    sink.consume_chunk(local, rg_idx, chunk_idx, survivors^)
            elif plan.has_string_key:
                # The selection is computed with the numeric keys resolved to
                # flat values (the evaluator is not dictionary-aware for
                # them); the chunk handed on keeps its dictionaries.
                var sel = evaluate_filter_narrowed(numeric_dict_cols_resolved(batch), filter_pred.value())
                if sel.length() == n_rows:
                    sink.consume_chunk(local, rg_idx, chunk_idx, batch^)
                elif sel.length() == 0:
                    n_skipped += 1
                    _ = batch^
                else:
                    return _declined(chunk_idx)
            else:
                sink.consume_chunk(local, rg_idx, chunk_idx, filter_batch_by_predicate(batch^, filter_pred.value()))
        else:
            sink.consume_chunk(local, rg_idx, chunk_idx, batch^)
        chunk_idx += 1

    # Completeness: every key emitted the row group's every row (this also
    # covers a row group whose driver produced no chunk at all).
    for k in range(n_keys):
        if cursors[plan.key_proj_idx[k]].rows_emitted() != n_key_total:
            return _declined(chunk_idx)
    subrg_filter_record(n_gathered, n_skipped, n_keylut)
    return FOLD_OK
