# =============================================================================
# agg_count_distinct_parallel -- the grouped COUNT(DISTINCT) driver over one
# resident batch, hash-partitioned across the dispatcher's workers
# =============================================================================
#
# Shape served: `SELECT k1.., COUNT(DISTINCT v).. [, SUM / COUNT / MIN / MAX /
# AVG ..] FROM t GROUP BY k1..` over one `RecordBatch`, with INT32 / INT64,
# STRING / LARGE_STRING or string-DICTIONARY group keys (any number, NULLs
# allowed) and INT32 / INT64 / FLOAT64 aggregate inputs.
#
# Steps:
#   1. Encode every string key to dense dict ids numbered in FIRST-SEEN row
#      order (`agg_count_distinct_strenc`, `agg_cd_dictkey_encode`), so a
#      DICTIONARY key and the plain STRING form of the same rows give the
#      same groups in the same order.
#   2. Size each worker's group table from a GROUP bound
#      (`agg_cd_group_ht_sizing`) and, when every aggregate is
#      COUNT(DISTINCT), sample for HEAVY groups (`agg_cd_heavy_split`).
#   3. Dispatch the OWNER pass, then the AGG pass (`cd_parallel_state`; its
#      header states the correctness invariant).
#   4. Merge: the groups are disjoint across workers, so the merge is a
#      concatenation into a (worker, gid) index in (worker 0's gid order,
#      then each later worker's slot order); a heavy group's partials are
#      folded by FULL key into the first one met.
#   5. Emit the aggregate columns, then, when a `TOPN(k)` hint is admitted
#      (`agg_cd_group_topk`), select the k surviving groups, then emit the
#      group keys of the emitted groups only.
#
# Output row order is that merge order; a GROUP BY without ORDER BY promises
# none. Values are DuckDB's: a NULL value is not a distinct value, an all-NULL
# group counts 0, a NULL key is one group that reads back NULL, and the fixed
# aggregates follow `cd_parallel_emit`.
# =============================================================================

from std.math import min
from std.memory import UnsafePointer

from komira_agg_api.agg_column_ptrs import (
    AGG_KIND_I32,
    AGG_KIND_I64,
    TypedColumnPtrs,
    ValidityLanes,
)
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_arrow.varlen_width_guard import offset_width_bytes_or_raise
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.sched_trace import SITE_COUNT_DISTINCT
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_column_kernels.compiler_helpers import resolve_col_index
from komira_counters.keyeq_census import KEYEQ_AGGCD_PARALLEL
from komira_counters.strdrain_counter import (
    strdrain_note_cdp_builder,
    strdrain_note_cdp_call,
    strdrain_note_owner,
    strdrain_note_site,
)
from komira_physical_plan.physical_plan import AggSinkData
from komira_plan_expr.agg_expr import AGG_COUNT_DISTINCT

from komira_op_agg_distinct.agg_cd_dictkey_encode import (
    encode_dict_key_first_seen,
)
from komira_op_agg_distinct.agg_cd_group_ht_sizing import (
    cd_group_ht_initial_cap,
    cd_group_ht_note,
    cd_groups_upper_bound,
)
from komira_op_agg_distinct.agg_cd_group_topk import (
    CdGroupTopKHint,
    cd_group_topk_admits,
    cd_group_topk_gids,
    cd_group_topk_index_column,
    cd_group_topk_index_field,
    cd_group_topk_select,
)
from komira_op_agg_distinct.agg_cd_heavy_split import (
    CD_HEAVY_SAMPLE_ROWS,
    cd_heavy_note,
    cd_heavy_sample_row,
    cd_split_groups,
    cd_worker_scan_note,
)
from komira_op_agg_distinct.agg_cd_key_emit import cd_emit_string_key_column
from komira_op_agg_distinct.agg_count_distinct_strenc import (
    _assign_dict_ids_from_hashes,
    _encode_string_key_parallel,
    _should_use_parallel_strenc,
)
from komira_op_agg_distinct.cd_parallel_emit import (
    CDFixedCell,
    cd_fixed_cell_identity,
    cd_fixed_column,
    cd_int_key_column,
    cd_stamp_nulls,
)
from komira_op_agg_distinct.cd_parallel_state import (
    _CDP_PASS_AGG,
    _CDP_PASS_OWNER,
    _CDParallelState,
    _CDParallelTask,
    _PARALLEL_CD_MAX_K,
    _PARALLEL_CD_MIN_ROWS,
    _PARALLEL_CD_MIN_ROWS_PER_WORKER,
    _PerWorkerCDState,
    _cd_group_hash_at,
)


@always_inline
def _data_ptr[
    T: DType, o: Origin
](col: Column[HeapRegion]) -> UnsafePointer[Scalar[T], o]:
    """`col`'s value buffer as a `Scalar[T]` pointer with the batch's concrete
    origin `o`.

    # SAFETY: the buffer belongs to the batch that `o` names, which the caller
    # borrows for as long as the pointer lives. A key read through the other
    # width (a STRING key, or an INT32 key's INT64 slot) gets a pointer that is
    # never dereferenced: the per-key `key_is_string` / `key_is_i32` flags
    # select the lane that is read.
    """
    return (
        col._data.view_ro()._unsafe_ptr().bitcast[Scalar[T]]()
        .unsafe_mut_cast[o.mut]().unsafe_origin_cast[o]()
    )


def _should_use_parallel_count_distinct(num_rows: Int, worker_count: Int) -> Bool:
    """True when the parallel driver is worth starting: more than one worker
    and at least `_PARALLEL_CD_MIN_ROWS` rows."""
    return worker_count > 1 and num_rows >= _PARALLEL_CD_MIN_ROWS


def _cd_worker_count(num_rows: Int, worker_count: Int) -> Int:
    """K: the dispatcher's workers, at most one per
    `_PARALLEL_CD_MIN_ROWS_PER_WORKER` rows and at most `_PARALLEL_CD_MAX_K`,
    at least 1."""
    var by_rows = num_rows // _PARALLEL_CD_MIN_ROWS_PER_WORKER
    var k = min(worker_count, max(by_rows, 1))
    return max(min(k, _PARALLEL_CD_MAX_K), 1)


def _encode_string_key[
    OffsetType: DType
](
    col: Column[HeapRegion],
    mut dispatcher: LocalDispatcher[NoopSink],
    num_rows: Int,
    mut rev_bytes: List[UInt8],
    mut rev_starts: List[Int],
    mut rev_lens: List[Int],
    mut encoded: List[Int],
) raises -> Bool:
    """Dict ids in first-seen order for one STRING / LARGE_STRING key column,
    read at the column's own offset. Returns True when the reverse spans index
    the column's value buffer, False when they index `rev_bytes`."""
    var data_view = col._data.view_ro()
    var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
    var offs_view = col._offsets.value().view_ro()
    var offs_ptr = offs_view._unsafe_ptr().bitcast[Scalar[OffsetType]]() + col._offset
    if _should_use_parallel_strenc(num_rows, dispatcher.worker_count()):
        return _encode_string_key_parallel(
            dispatcher,
            CancellationToken.never(),
            data_ptr,
            offs_ptr,
            num_rows,
            encoded,
            rev_bytes,
            rev_starts,
            rev_lens,
        )
    # The serial arm: the same FNV-1a row hash as the parallel pre-pass, then
    # the shared first-seen id assignment.
    comptime FNV_BASIS = Int64(-3750763034362895579)
    comptime FNV_PRIME = Int64(1099511628211)
    var hashes = List[Int64](length=num_rows, fill=Int64(0))
    for row in range(num_rows):
        var start = Int((offs_ptr + row)[])
        var str_len = Int((offs_ptr + row + 1)[]) - start
        var h = FNV_BASIS
        for b in range(str_len):
            h = (h ^ Int64((data_ptr + start + b)[])) * FNV_PRIME
        hashes[row] = h ^ (Int64(str_len) * FNV_PRIME)
    _assign_dict_ids_from_hashes[OffsetType](
        hashes,
        data_ptr,
        offs_ptr,
        num_rows,
        KEYEQ_AGGCD_PARALLEL,
        encoded,
        rev_bytes,
        rev_starts,
        rev_lens,
    )
    return False


def _execute_count_distinct_agg_parallel(
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    batch: RecordBatch,
    agg_data: AggSinkData,
    num_keys: Int,
    num_aggs: Int,
    num_rows: Int,
    var topk_hint: Optional[CdGroupTopKHint] = None,
) raises -> RecordBatch:
    """The grouped COUNT(DISTINCT) aggregate of `batch` (module header).

    Args:
        dispatcher: The caller's dispatcher, borrowed for the dispatches.
        cancel_token: Consumed by the AGG pass's `run_with_state`.
        batch: The input; borrowed for the whole call.
        agg_data: Group keys, aggregates and output schema.
        num_keys: Group-by keys (at most 62).
        num_aggs: Aggregates.
        num_rows: `batch.num_rows()`.
        topk_hint: The `TOPN(k)` above this aggregate, if the plan carries
            one. It changes cost only; `None` emits every group.
    """
    if num_keys > 62:
        raise Error(
            "grouped COUNT(DISTINCT) driver: " + String(num_keys)
            + " group keys; at most 62 are supported"
        )
    # A COUNT(DISTINCT) value is read through the INT32 / INT64 / FLOAT64
    # lanes of `TypedColumnPtrs`; any other type would be read at the wrong
    # width, so it is refused before anything runs.
    for a in range(num_aggs):
        if agg_data.agg_exprs[a].func != AGG_COUNT_DISTINCT:
            continue
        if not agg_data.agg_exprs[a].child:
            continue
        var vi = resolve_col_index(agg_data.agg_exprs[a].child.value(), batch.schema)
        var vt = batch.column_at(vi).arrow_type
        if vt != ArrowType.INT32 and vt != ArrowType.INT64 and vt != ArrowType.FLOAT64:
            raise Error(
                "grouped COUNT(DISTINCT) driver: value column '"
                + batch.schema.field_at(vi).name + "' has type " + String(vt)
                + "; only INT32, INT64 and FLOAT64 are supported"
            )
    var key_col_indices = List[Int]()
    var key_types = List[ArrowType]()
    for k in range(num_keys):
        var ki = resolve_col_index(agg_data.group_by_exprs[k], batch.schema)
        key_col_indices.append(ki)
        key_types.append(batch.column_at(ki).arrow_type)

    # ---- 1. string keys -> first-seen dict ids ----
    var key_is_string = List[Bool]()
    var any_string_key = False
    var key_rev_bytes = List[List[UInt8]]()
    var key_rev_starts = List[List[Int]]()
    var key_rev_lens = List[List[Int]]()
    var key_str_encoded = List[List[Int]]()
    var key_rev_on_src = List[Bool]()
    for k in range(num_keys):
        var at = key_types[k]
        var is_str = (
            at == ArrowType.STRING
            or at == ArrowType.LARGE_STRING
            or at == ArrowType.DICTIONARY
        )
        if not is_str and at != ArrowType.INT32 and at != ArrowType.INT64:
            raise Error(
                "grouped COUNT(DISTINCT) driver: group key type "
                + String(at.type_id) + " is not supported"
            )
        key_is_string.append(is_str)
        any_string_key = any_string_key or is_str
        key_rev_on_src.append(False)
        key_rev_bytes.append(List[UInt8]())
        key_rev_starts.append(List[Int]())
        key_rev_lens.append(List[Int]())
        key_str_encoded.append(List[Int]())
        if not is_str:
            continue
        ref col = batch.column_at(key_col_indices[k])
        if at == ArrowType.DICTIONARY:
            if col.is_numeric_dict():
                raise Error(
                    "grouped COUNT(DISTINCT) driver: a NUMERIC dictionary key"
                    " is not supported"
                )
            encode_dict_key_first_seen(
                dispatcher,
                col,
                num_rows,
                key_str_encoded[k],
                key_rev_bytes[k],
                key_rev_starts[k],
                key_rev_lens[k],
            )
        elif offset_width_bytes_or_raise("grouped COUNT(DISTINCT) key", at) == 8:
            key_rev_on_src[k] = _encode_string_key[DType.int64](
                col, dispatcher, num_rows, key_rev_bytes[k], key_rev_starts[k],
                key_rev_lens[k], key_str_encoded[k],
            )
        else:
            key_rev_on_src[k] = _encode_string_key[DType.int32](
                col, dispatcher, num_rows, key_rev_bytes[k], key_rev_starts[k],
                key_rev_lens[k], key_str_encoded[k],
            )

    # ---- value lanes and integer key pointers ----
    comptime bo = origin_of(batch)
    var val_ptrs = TypedColumnPtrs[bo].from_batch_padded(
        batch, agg_data.agg_exprs, num_aggs
    )
    var is_cd = List[Bool]()
    var funcs = List[UInt8]()
    var all_cd = num_aggs >= 1
    for a in range(num_aggs):
        var f = agg_data.agg_exprs[a].func
        funcs.append(f)
        is_cd.append(f == AGG_COUNT_DISTINCT)
        all_cd = all_cd and f == AGG_COUNT_DISTINCT
    var key_ptrs_i64 = List[UnsafePointer[Scalar[DType.int64], bo]]()
    var key_ptrs_i32 = List[UnsafePointer[Scalar[DType.int32], bo]]()
    var key_is_i32 = List[Bool]()
    var key_offsets = List[Int]()
    for k in range(num_keys):
        ref kp = batch.column_at(key_col_indices[k])
        key_offsets.append(kp._offset)
        key_is_i32.append(not key_is_string[k] and kp.arrow_type == ArrowType.INT32)
        # SAFETY: see `_data_ptr`; both widths are taken for every key and
        # only the lane its `key_is_i32` / `key_is_string` flags name is read,
        # inside the two dispatches below.
        key_ptrs_i32.append(_data_ptr[DType.int32, bo](kp))
        key_ptrs_i64.append(_data_ptr[DType.int64, bo](kp))
    var key_valid = ValidityLanes[bo].from_batch_columns(batch, key_col_indices)
    var keys_nullable = key_valid.any_nullable()

    # ---- 2. K, the group-table capacity, heavy admission ----
    var k = _cd_worker_count(num_rows, dispatcher.worker_count())
    var dict_sizes = List[Int](capacity=num_keys)
    for kk in range(num_keys):
        dict_sizes.append(len(key_rev_starts[kk]) if key_is_string[kk] else -1)
    var ht_cap = cd_group_ht_initial_cap(cd_groups_upper_bound(dict_sizes, num_rows), k)
    # Heavy split only when every aggregate is COUNT(DISTINCT) (an integer,
    # order-free partial that folds exactly), the ownership mask fits one Int
    # (<= 62 aggregates), and there is a key and more than one worker.
    var heavy_admit = all_cd and num_aggs <= 62 and num_keys >= 1 and k >= 2
    var owner = List[UInt8]()
    if num_rows > 0:
        owner.resize(unsafe_uninit_length=num_rows)
    var worker_states = Slab[_PerWorkerCDState](k)
    var per_worker_rows = (num_rows + k - 1) // k
    for _ in range(k):
        var ws = _PerWorkerCDState()
        ws.init(num_keys, num_aggs, ht_cap, cd_rows_hint=per_worker_rows)
        worker_states.append(ws^)

    var state = _CDParallelState[bo](
        worker_states^,
        num_rows,
        key_str_encoded^,
        key_is_string.copy(),
        key_is_i32^,
        key_offsets^,
        key_ptrs_i32^,
        key_ptrs_i64^,
        key_valid^,
        val_ptrs^,
        is_cd^,
        funcs.copy(),
        owner^,
        num_keys=num_keys,
        num_aggs=num_aggs,
        num_workers=k,
    )
    if heavy_admit:
        var n_sample = min(num_rows, CD_HEAVY_SAMPLE_ROWS)
        var sample = List[Int](capacity=n_sample)
        for i in range(n_sample):
            sample.append(
                _cd_group_hash_at(state, cd_heavy_sample_row(i, n_sample, num_rows))
            )
        state.heavy_hashes[] = cd_split_groups(sample, k)
        state.n_heavy = len(state.heavy_hashes[])
    var n_heavy = state.n_heavy
    var heavy_hashes = state.heavy_hashes[].copy()

    # ---- 3. the two dispatches over one state ----
    # PARALLELIZE-BOUNDARY: the state's docstring (`cd_parallel_state`) states
    # disjointness, liveness and no-realloc for both passes.
    state.pass_id = _CDP_PASS_OWNER
    var otask_back = dispatcher.run_with_state[
        _CDParallelState[bo], _CDParallelTask[bo]
    ](
        state,
        _CDParallelTask[bo](Int32(0)),
        k,
        cancel_token.clone(),
        site_id=SITE_COUNT_DISTINCT,
    )
    _ = otask_back^
    if state.err_flag[].load() != Int8(0):
        raise Error(String(state.err_msg[]))
    state.pass_id = _CDP_PASS_AGG
    var task_back = dispatcher.run_with_state[
        _CDParallelState[bo], _CDParallelTask[bo]
    ](
        state,
        _CDParallelTask[bo](Int32(0)),
        k,
        cancel_token^,
        site_id=SITE_COUNT_DISTINCT,
    )
    _ = task_back^
    if state.err_flag[].load() != Int8(0):
        raise Error(String(state.err_msg[]))

    ref ws_slab = state.worker_states[]
    var slots_total = 0
    var resizes_total = 0
    var own_max = 0
    var own_sum = 0
    var scan_sum = 0
    for w in range(k):
        ref wsx = ws_slab.get_mut_interior(w)
        slots_total += wsx.ht_slots_alloc
        resizes_total += wsx.ht_resizes
        own_sum += wsx.wk_rows
        scan_sum += wsx.wk_scanned
        if wsx.wk_rows > own_max:
            own_max = wsx.wk_rows
    cd_group_ht_note(slots_total, resizes_total)

    # ---- 4. merge: a (worker, gid) index, heavy partials folded ----
    var mg_w = List[Int]()
    var mg_gid = List[Int]()
    var hf_w = List[Int]()
    var hf_gid = List[Int]()
    var hf_h = List[Int]()
    var heavy_merged = 0
    var w0_hash = List[Int]()
    if n_heavy > 0:
        w0_hash = _gid_hashes(ws_slab.get_mut_interior(0))
    for w in range(k):
        ref src = ws_slab.get_mut_interior(w)
        # Worker 0 in gid order (its groups ARE the identity prefix), every
        # later worker in slot order.
        var n_walk = src.num_groups if w == 0 else src.ht_cap
        for i in range(n_walk):
            var sg = i
            var sh = 0
            if w == 0:
                if n_heavy > 0:
                    sh = w0_hash[sg]
            else:
                sg = Int(src.ht_gids[i])
                if sg == -1:
                    continue
                sh = Int(src.ht_keys[i])
            if n_heavy > 0 and _is_heavy(heavy_hashes, sh):
                var found = -1
                for fi in range(len(hf_h)):
                    if hf_h[fi] == sh and _same_group(
                        ws_slab.get_mut_interior(hf_w[fi]), hf_gid[fi], src, sg,
                        num_keys, keys_nullable,
                    ):
                        found = fi
                        break
                if found >= 0:
                    ref first = ws_slab.get_mut_interior(hf_w[found])
                    for a in range(num_aggs):
                        first.cd_counts[a][hf_gid[found]] += src.cd_counts[a][sg]
                    heavy_merged += 1
                    continue
                hf_w.append(w)
                hf_gid.append(sg)
                hf_h.append(sh)
            mg_w.append(w)
            mg_gid.append(sg)
    cd_heavy_note(n_heavy, heavy_merged, own_max, own_sum)
    cd_worker_scan_note(scan_sum)

    # ---- 5. aggregate columns, top-k selection, key columns ----
    var num_groups = len(mg_w)
    if num_keys == 0 and num_groups == 0:
        # An ungrouped aggregate has one row even over no input.
        mg_w.append(0)
        mg_gid.append(-1)
        num_groups = 1
    ref out_schema = agg_data.output_schema
    var agg_nullable = List[Bool](length=num_aggs, fill=False)
    var agg_cols = List[Column[HeapRegion]]()
    for a in range(num_aggs):
        if state.is_cd[][a]:
            var arr = PrimitiveArray[DType.int64].allocate(num_groups)
            for g in range(num_groups):
                var c = 0
                if mg_gid[g] >= 0:
                    c = ws_slab.get_mut_interior(mg_w[g]).cd_counts[a][mg_gid[g]]
                arr.set(g, Int64(c))
            agg_cols.append(Column.from_primitive[DType.int64](arr^))
            continue
        var cells = List[CDFixedCell](capacity=num_groups)
        for g in range(num_groups):
            if mg_gid[g] < 0:
                cells.append(cd_fixed_cell_identity())
            else:
                cells.append(ws_slab.get_mut_interior(mg_w[g]).fx[a][mg_gid[g]])
        var any_null = False
        agg_cols.append(
            cd_fixed_column(
                cells,
                funcs[a],
                out_schema.field_arrow_type(num_keys + a),
                state.val_ptrs[].kind_at(a) == AGG_KIND_I32
                or state.val_ptrs[].kind_at(a) == AGG_KIND_I64,
                "integer column of aggregate " + String(a),
                any_null,
            )
        )
        agg_nullable[a] = any_null

    var topk_admit = cd_group_topk_admits(
        out_schema, num_keys, num_groups, any_string_key, topk_hint
    )
    var emit_rows = List[Int]()
    var topk_fired = False
    if topk_admit:
        var pre_b = RecordBatchBuilder.with_capacity(num_aggs + 1)
        var pre_sb = SchemaBuilder()
        for a in range(num_aggs):
            pre_sb.add_field(_agg_field(out_schema, num_keys, a, agg_nullable))
            pre_b.add_column(agg_cols[a].share())
        pre_sb.add_field(cd_group_topk_index_field())
        pre_b.add_column(cd_group_topk_index_column(num_groups))
        var sel = cd_group_topk_select(
            pre_b.build(pre_sb.build()), topk_hint.value().copy()
        )
        emit_rows = cd_group_topk_gids(sel)
        var gathered = List[Column[HeapRegion]](capacity=num_aggs)
        for a in range(num_aggs):
            gathered.append(sel.column_at(a).share())
        agg_cols = gathered^
        topk_fired = True
    var n_emit = len(emit_rows) if topk_fired else num_groups

    var builder = RecordBatchBuilder.with_capacity(num_keys + num_aggs)
    var sb = SchemaBuilder()
    for ki in range(num_keys):
        # Each emitted group's key value and NULL flag, from its owning worker.
        var kvals = List[Int](capacity=num_groups)
        for g in range(num_groups):
            kvals.append(ws_slab.get_mut_interior(mg_w[g]).group_key_arrays[ki][mg_gid[g]])
        var key_col: Column[HeapRegion]
        if key_is_string[ki]:
            strdrain_note_cdp_call()
            if key_rev_on_src[ki]:
                # SAFETY (lifetime): the spans index `batch`'s own value
                # buffer, which this function borrows for its whole body.
                key_col = cd_emit_string_key_column(
                    batch.column_at(key_col_indices[ki])._data.view_ro().into_span(),
                    kvals, key_rev_starts[ki], key_rev_lens[ki], emit_rows,
                    topk_fired, num_groups, k > 1,
                )
            else:
                key_col = cd_emit_string_key_column(
                    Span(key_rev_bytes[ki]), kvals, key_rev_starts[ki],
                    key_rev_lens[ki], emit_rows, topk_fired, num_groups, k > 1,
                )
            strdrain_note_site(6, n_emit)
            strdrain_note_owner(3, n_emit)
            strdrain_note_cdp_builder(n_emit)
        else:
            key_col = cd_int_key_column(
                kvals, emit_rows, topk_fired, num_groups, key_types[ki] == ArrowType.INT32
            )
        var kfield = out_schema.field_at(ki)
        if keys_nullable:
            var nulls = List[Bool](capacity=n_emit)
            for i in range(n_emit):
                var g = emit_rows[i] if topk_fired else i
                var m = ws_slab.get_mut_interior(mg_w[g]).group_null_masks[mg_gid[g]]
                nulls.append(((m >> ki) & 1) == 1)
            cd_stamp_nulls(key_col, nulls)
            if key_col._null_count > 0:
                kfield.nullable = True
        sb.add_field(kfield)
        builder.add_column(key_col^)
    for a in range(num_aggs):
        sb.add_field(_agg_field(out_schema, num_keys, a, agg_nullable))
        builder.add_column(agg_cols[a].share())
    var result = builder.build(sb.build())
    _ = batch  # keepalive: the key and value pointers borrow it
    _ = state^
    return result^


def _gid_hashes(ws: _PerWorkerCDState) -> List[Int]:
    """`[gid]`: the composite hash the worker stored for each of its groups."""
    var out = List[Int](length=ws.num_groups, fill=0)
    for s in range(ws.ht_cap):
        var g = Int(ws.ht_gids[s])
        if g != -1:
            out[g] = Int(ws.ht_keys[s])
    return out^


@always_inline
def _is_heavy(heavy: List[Int], h: Int) -> Bool:
    for i in range(len(heavy)):
        if heavy[i] == h:
            return True
    return False


def _same_group(
    a: _PerWorkerCDState,
    ga: Int,
    b: _PerWorkerCDState,
    gb: Int,
    num_keys: Int,
    nullable: Bool,
) -> Bool:
    """Whether two workers' groups have the same FULL key (values and NULL
    mask), never judged by hash alone: a light group whose hash collides with a
    heavy one is split too, and folds only with itself."""
    if nullable and a.group_null_masks[ga] != b.group_null_masks[gb]:
        return False
    for k in range(num_keys):
        if a.group_key_arrays[k][ga] != b.group_key_arrays[k][gb]:
            return False
    return True


def _agg_field(
    schema: Schema, num_keys: Int, a: Int, nullable: List[Bool]
) raises -> Field:
    """Aggregate `a`'s output field, marked nullable when its column holds a
    NULL (a schema saying NOT NULL over a column with NULLs is wrong)."""
    var f = schema.field_at(num_keys + a)
    if nullable[a]:
        f.nullable = True
    return f^
