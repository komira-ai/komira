# =============================================================================
# cd_stream_consume.mojo — the grouped row loop of `WorkerCDState`
# =============================================================================
#
# `WorkerCDState.consume_batch[has_fixed]` (`streaming_agg_count_distinct`)
# forwards here: `_cd_consume_grouped` resolves each row's group id, appends
# each COUNT(DISTINCT) value to its cell and, on the `has_fixed`
# instantiation, records the gids the passenger lane folds against;
# `_cd_fx_fold_batch` is that column-major fold. The two live in their own
# module only to keep each file under 1,000 lines; the mechanisms are
# described in `streaming_agg_count_distinct`'s header.
#
# Both functions are package-internal: they are called only from
# `streaming_agg_count_distinct`, and the leading underscore of
# `_cd_fx_fold_batch` marks that. It takes lists of column pointers with
# concrete origins, so it is not part of the package's API and nothing outside
# the package may call it.
# =============================================================================

from std.memory import UnsafePointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch
from komira_udf.float_quotient_order import (
    float_quotient_gt_f64,
    float_quotient_lt_f64,
)
from komira_plan_expr.agg_expr import (
    AGG_COUNT, AGG_MAX, AGG_MEAN, AGG_MIN, AGG_SUM,
)
from komira_agg_api.agg_column_ptrs import ValidityLanes
from komira_agg_api.cd_distinct_key import (
    CDK_RAW_I64,
    cd_distinct_key_channel,
    cd_distinct_keys_for_column,
)

from komira_op_agg_distinct.streaming_agg_count_distinct import (
    FXC_F32,
    FXC_F64,
    FXC_I32,
    FXC_I64,
    FXC_NONE,
    FixedAggCell,
    WorkerCDState,
    _CD_CELL_BUFFERING,
    _CD_CELL_SETS,
    _CD_GROUPED_PROMOTE_MIN_VALUES,
    _cd_value_partition_i64,
    _fx_identity,
)


def _cd_consume_grouped[
    has_fixed: Bool
](
    mut st: WorkerCDState,
    batch: RecordBatch,
    key_col_idx: Int,
    val_col_indices: List[Int],
    imm fx_col_indices: List[Int],
) raises:
    """The body of `WorkerCDState.consume_batch[has_fixed]` (see there)."""
    var num_rows = batch.num_rows()
    if num_rows == 0:
        return
    st.stat_batches += 1

    ref key_col = batch.column_at(key_col_idx)
    # An origin-tied `view_ro()._unsafe_ptr().bitcast[...]()` read.
    # `key_view` is bound on the function frame; NLL keeps the borrow alive
    # through the per-row loop body and the trailing `_ = batch` keepalive.
    var key_view = key_col._data.view_ro()
    var key_ptr = key_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    var key_off = key_col._offset

    # Pre-extract value column pointers
    # Parent-origin anchoring: value pointers borrow from `batch`.
    comptime bo = origin_of(batch)
    var val_ptrs = List[UnsafePointer[Scalar[DType.int64], bo]]()
    var val_offs = List[Int]()
    for a in range(st.num_aggs):
        var vi = val_col_indices[a]
        ref vp = batch.column_at(vi)
        # Two-step cast: origin_of(vp._data) is a sub-origin of `bo` (vp
        # lives inside batch); the widening tail
        # `unsafe_mut_cast[bo.mut]().unsafe_origin_cast[bo]()` is what lets
        # the pointer be stored in a `List[UnsafePointer[..., bo]]`.
        # SAFETY: vp._data is owned by batch; pointer outlives this scope.
        val_ptrs.append(
            vp._data.view_ro()
                ._unsafe_ptr()
                .bitcast[Scalar[DType.int64]]()
                .unsafe_mut_cast[bo.mut]()
                .unsafe_origin_cast[bo]()
        )
        val_offs.append(vp._offset)

    # ★ THE VALIDITY CHANNEL.
    # The block above extracts a VALUES pointer per agg lane and nothing
    # else; an Arrow column's validity bitmap had no way into this loop,
    # so every NULL row's data word was appended to its group's cell as if
    # it were a value and `count(DISTINCT c) ... GROUP BY k` came back one
    # too high for any group holding a NULL. `ValidityLanes` is the same
    # borrow shape as the value pointers — one lane per agg slot, same
    # parent batch, same named origin — and it is built from the SAME
    # `val_col_indices`, so the two channels cannot describe different
    # columns.
    var vlanes = ValidityLanes[bo].from_batch_columns(
        batch, val_col_indices
    )

    # Per-batch counters live in locals (registers) and are folded into the
    # state ONCE at the end, so the structural instrumentation costs the
    # inner loop an add on a local, not a field write per row.
    var n_appended = 0
    var n_set_inserted = 0
    # ★ CD-DENSE-GID's hit counter lives here for the SAME reason: the
    # dense hit is the branch EVERY row of a dense-domain query takes, and
    # `st.stat_gid_dense += 1` there is a load-add-store to a hot line on
    # the per-row critical path. The cold arms (`_dense_assign`,
    # `_gid_for_key_slow`) keep writing the field directly — each runs once
    # per NEW key or on a fallback row that is already paying a Dict probe.
    var n_gid_dense_hit = 0
    # ⭐ CD-ADJDEDUP — the gate, hoisted to a local, and its counter.
    var adj_on = st.adj_dedup_on
    var n_adj_skipped = 0
    # ⭐ CD-LASTKEY — the gate, the one-entry memo (per batch: a batch is
    # one morsel, and the memo is only ever a cache of `group_map`), and
    # its hit counter. See the CD-LASTKEY block above `FixedAggCell`.
    var lk_on = st.lastkey_on
    var lk_live = False
    var lk_key = 0
    var lk_gid = -1
    var n_lastkey_hit = 0

    # ★ CD-TYPE-WIDTH (2026-09-11) — the same 8-byte-stride defect, on the
    # KEY and on the VALUES. `key_ptr` above is a bitcast to
    # `Scalar[DType.int64]`, but `_build_cd_agg_sink_data` and
    # `detect_count_distinct_agg_shape` BOTH admit an INT32 group key — so
    # an int32 key column was read two-elements-at-a-time and rows landed in
    # groups that do not exist. Classify once, materialise the narrow
    # channel at its own width, leave the int64 path on the pointer.
    var key_ch = cd_distinct_key_channel(
        batch.column_arrow_type(key_col_idx)
    )
    var key_narrow = List[Int64]()
    if key_ch != CDK_RAW_I64:
        key_narrow = cd_distinct_keys_for_column(batch, key_col_idx)

    # ★ CD-KEY-NULL (2026-09-13) — THE KEY VALIDITY CHANNEL. `key_ptr` above
    # is a raw data-buffer borrow and carries no validity at all, exactly as
    # the VALUE pointers did before AGG-CD-NULL. Same channel, same borrow
    # shape, same parent batch — one lane, built from the SAME
    # `key_col_idx`, so the two cannot describe different columns. A
    # non-nullable key column produces an ABSENT lane and `is_null_at` is a
    # constant False, so the null-free hot loop is unchanged.
    var key_idx_lane = List[Int]()
    key_idx_lane.append(key_col_idx)
    var klanes = ValidityLanes[bo].from_batch_columns(batch, key_idx_lane)

    var val_chans = List[UInt8]()
    var val_keys = List[List[Int64]]()
    for a in range(st.num_aggs):
        var ch = cd_distinct_key_channel(
            batch.column_arrow_type(val_col_indices[a])
        )
        val_chans.append(ch)
        if ch == CDK_RAW_I64:
            val_keys.append(List[Int64]())
        else:
            val_keys.append(
                cd_distinct_keys_for_column(batch, val_col_indices[a])
            )

    # ⭐⭐ MIXEDFUSE — the fixed lane's PER-BATCH setup. Everything that can
    # be decided once per morsel is decided here: the input channel, the
    # data pointer, the offset, the validity lane. The row loop below then
    # does one switch on an already-classified UInt8 and a scalar update.
    #
    # ⛔ A COLUMN'S TYPE IS CLASSIFIED HERE AND NOWHERE ELSE, AND AN
    # UNCLASSIFIABLE ONE RAISES. The sink's envelope admits exactly INT32 /
    # INT64 / FLOAT32 / FLOAT64 fixed inputs, so reaching the `else` means
    # the decoded batch disagrees with the schema the envelope validated —
    # a real defect, not a shape to fall back from, and the one thing worse
    # than raising here is reading a narrow column at an 8-byte stride (the
    # CD-TYPE-WIDTH defect, on the fixed lane).
    var n_fixed = st.num_fixed
    # Declared on BOTH instantiations because a `comptime if` block scopes
    # its `var`s; on `has_fixed=False` they are empty, allocation-free and
    # never read, so the optimiser deletes them.
    var fx_chan = List[UInt8]()
    var fx_ptrs = List[UnsafePointer[Scalar[DType.int64], bo]]()
    var fx_offs = List[Int]()
    var fxlanes = ValidityLanes[bo]()
    # The per-row gid, recorded for `_cd_fx_fold_batch`, and the fold shape
    # (`fxcol_on`: column-major per batch; False: the per-row fold), read
    # ONCE per batch on the passenger instantiation only.
    var fx_gids = List[Int32]()
    var fxcol = True
    comptime if not has_fixed:
        # ⛔ THE ALL-CD INSTANTIATION HAS NO PASSENGER LANE, so an ARMED
        # state here would grow groups whose fixed cells are never created
        # or folded, and answer its fixed aggregates with nothing. Refuse,
        # before any row is consumed.
        if n_fixed != 0:
            raise Error(
                "WorkerCDState.consume_batch: a state armed with fixed"
                " aggregates was fed through the all-COUNT(DISTINCT)"
                " instantiation (has_fixed=False), which has no passenger"
                " lane."
            )
    comptime if has_fixed:
        st.stat_fx_batches += 1
        if len(fx_col_indices) != n_fixed:
            raise Error(
                "WorkerCDState.consume_batch: the fixed-column list does"
                " not cover every armed fixed slot."
            )
        # ⚠ A bare COUNT(*) HAS NO INPUT COLUMN, and neither a pointer nor a
        # validity lane can be built for index -1. It borrows the KEY column's
        # index as a placeholder that is never read: `FXC_NONE` short-circuits
        # before either channel is consulted.
        var fx_safe_idx = List[Int]()
        for f in range(n_fixed):
            var ci = fx_col_indices[f]
            if ci < 0:
                fx_chan.append(FXC_NONE)
                fx_safe_idx.append(key_col_idx)
            else:
                var fat = batch.column_arrow_type(ci)
                if fat == ArrowType.INT64:
                    fx_chan.append(FXC_I64)
                elif fat == ArrowType.INT32:
                    fx_chan.append(FXC_I32)
                elif fat == ArrowType.FLOAT64:
                    fx_chan.append(FXC_F64)
                elif fat == ArrowType.FLOAT32:
                    fx_chan.append(FXC_F32)
                else:
                    raise Error(
                        "WorkerCDState.consume_batch: a fixed aggregate input"
                        " column is outside the INT32/INT64/FLOAT32/FLOAT64"
                        " envelope the sink admitted."
                    )
                fx_safe_idx.append(ci)
            var fci = fx_safe_idx[f]
            ref fvp = batch.column_at(fci)
            # SAFETY: `fvp._data` is owned by `batch`; the pointer is used only
            # inside this call, and `_ = batch` at the bottom keeps the parent
            # alive across the loop. Same two-step cast + named-origin
            # storage the CD value lanes above use, for the same reason (a
            # `List[UnsafePointer[..., bo]]` needs the widened tail).
            fx_ptrs.append(
                fvp._data.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.int64]]()
                    .unsafe_mut_cast[bo.mut]()
                    .unsafe_origin_cast[bo]()
            )
            fx_offs.append(fvp._offset)
        fxlanes = ValidityLanes[bo].from_batch_columns(batch, fx_safe_idx)
        fxcol = st.fxcol_on
        if fxcol:
            fx_gids.reserve(num_rows)
        # The cell space must cover every group that ALREADY exists (a state
        # reused across morsels has groups from earlier batches). `_append_group`
        # keeps it in lockstep from here on.
        for f in range(n_fixed):
            while len(st.fx_cells[f]) < len(st.group_keys):
                st.fx_cells[f].append(_fx_identity())

    for row in range(num_rows):
        var gid: Int
        if klanes.is_null_at(0, row):
            # ★ CD-KEY-NULL — ONE group for every NULL key, and it never
            # enters `group_map`: the key's data word is meaningless and
            # hashing it is the defect.
            if st.null_gid < 0:
                # `group_keys[null_gid]` is a PLACEHOLDER that is never read
                # as a key — `group_key_null` is what the finalize reads.
                # `_append_group` holds the four-array lockstep.
                st.null_gid = st._append_group[has_fixed](0, True)
            gid = st.null_gid
        else:
            var key: Int
            if key_ch == CDK_RAW_I64:
                key = Int((key_ptr + key_off + row)[])
            else:
                key = Int(key_narrow[row])
            # ★ CD-DENSE-GID (2026-09-17) — THE WHOLE POINT OF THIS FILE'S
            # HOT LOOP. One subtract, one UNSIGNED range test (which is why
            # a negative key, a window straddling zero and a window that
            # wraps past Int64.MAX are all handled by the same compare and
            # none of them can overflow), one L1 load. What it replaces is
            # a two-round mulx hash fold plus TWO SwissTable group walks —
            # a large per-row cost on a small dense int64 key domain.
            var du = (Int64(key) - Int64(st.dense_lo)).cast[
                DType.uint64
            ]()
            # ⚠ `dense_gid_off` IS DELIBERATELY NOT TESTED HERE, AND THE
            # OMISSION IS LOAD-BEARING RATHER THAN AN OVERSIGHT. With the
            # A/B arm selected, `_gid_for_key_slow` never seeds the window,
            # so `dense_idx` stays EMPTY and this compare is already False
            # for every row — the OFF arm is byte-for-byte the old Dict
            # route AND the shipped arm pays no per-row branch for the
            # existence of a lever. (Consequence, stated so nobody relies on
            # the opposite: flipping the field after rows have been consumed
            # does not take effect. It is read once, at construction.)
            if du < UInt64(len(st.dense_idx)):
                var slot = st.dense_idx[Int(du)]
                if slot != Int32(0):
                    gid = Int(slot) - 1
                    n_gid_dense_hit += 1
                else:
                    gid = st._dense_assign[has_fixed](Int(du), key)
            elif lk_live and key == lk_key:
                # ⭐ CD-LASTKEY — the out-of-window key equals the previous
                # out-of-window row's key: its gid is already known. Only
                # rows OUTSIDE the window reach this test, so the dense hit
                # path above pays nothing for it.
                gid = lk_gid
                n_lastkey_hit += 1
            else:
                gid = st._gid_for_key_slow[has_fixed](key)
                if lk_on:
                    lk_key = key
                    lk_gid = gid
                    lk_live = True

        for a in range(st.num_aggs):
            # ★ AGG-CD-NULL — THE NULL SKIP. A NULL row still RESOLVED its
            # group above (a NULL value does not stop its row belonging to
            # a group), so an all-NULL group still exists and still emits;
            # only the value store is skipped, and its cell then dedups to
            # 0 — DuckDB's answer, and NOT NULL.
            if vlanes.is_null_at(a, row):
                continue
            # The deref is Scalar[DType.int64] == Int64 — no Int()
            # round-trip; `cd_bufs` is Int64-typed so the buffers move
            # straight into `radix_distinct_count_grouped` at finalize.
            # A NARROW lane reads its pre-materialised key instead (see the
            # CD-TYPE-WIDTH block above); the int64 lane is unchanged.
            var v: Int64
            if val_chans[a] == CDK_RAW_I64:
                v = (val_ptrs[a] + val_offs[a] + row)[]
            else:
                v = val_keys[a][row]
            if st.cd_gmode[a][gid] == _CD_CELL_SETS:
                # Promoted cell: dedup on scan. `_cd_value_partition_i64`
                # is a pure function of `v`, so equal values always reach
                # the same partition set and the partitions stay disjoint.
                _ = st.cd_gsets[a][gid][
                    _cd_value_partition_i64(v)
                ].insert(v)
                n_set_inserted += 1
            else:
                ref cell = st.cd_bufs[a][gid]
                var cl = len(cell)
                # ⭐ CD-ADJDEDUP — a value equal to its cell's tail is
                # already in this group's multiset; appending it again
                # changes no distinct count. See the block above
                # `FixedAggCell`. `adj_on` is a per-batch local, so the
                # branch is loop-invariant and predicted.
                if adj_on and cl > 0 and cell[cl - 1] == v:
                    n_adj_skipped += 1
                    continue
                cell.append(v)
                n_appended += 1
                if (
                    st.cd_gmode[a][gid] == _CD_CELL_BUFFERING
                    and cl + 1 >= _CD_GROUPED_PROMOTE_MIN_VALUES
                ):
                    st._promote_cell(a, gid)

        # ⭐⭐ MIXEDFUSE — THE PASSENGER LANE RECORDS THE GID; IT FOLDS
        # BELOW, COLUMN-MAJOR. `gid` above cost a dense
        # window hit (or a Dict probe); the fold rides it for free.
        # Compiled OUT of the all-CD instantiation (`has_fixed=False`).
        #
        comptime if has_fixed:
            if fxcol:
                fx_gids.append(Int32(gid))
            else:
                # With `fxcol_on = False` this per-row fold runs instead: NULL
                # inputs are SKIPPED; `n` counts CONTRIBUTING rows; `n == 1`
                # SEEDS MIN/MAX; SUM and MEAN share one accumulator and MEAN
                # divides at emit — `agg_mixed_cd_fold`'s semantics, which is
                # this lane's ORACLE.
                for f in range(n_fixed):
                    ref cell = st.fx_cells[f][gid]
                    var ch = fx_chan[f]
                    if ch == FXC_NONE:
                        # A bare COUNT(*) counts EVERY row of the group.
                        cell.n += Int64(1)
                        continue
                    if fxlanes.is_null_at(f, row):
                        continue
                    cell.n += Int64(1)
                    var afn = st.fx_func[f]
                    if afn == AGG_COUNT:
                        continue
                    if st.fx_is_int[f]:
                        var iv: Int64
                        if ch == FXC_I64:
                            iv = (fx_ptrs[f] + fx_offs[f] + row)[]
                        else:
                            iv = Int64(
                                (
                                    fx_ptrs[f].bitcast[Scalar[DType.int32]]()
                                    + fx_offs[f]
                                    + row
                                )[]
                            )
                        if afn == AGG_SUM or afn == AGG_MEAN:
                            cell.i_acc += iv
                        elif afn == AGG_MIN:
                            if cell.n == Int64(1) or iv < cell.i_acc:
                                cell.i_acc = iv
                        else:
                            if cell.n == Int64(1) or iv > cell.i_acc:
                                cell.i_acc = iv
                    else:
                        var fv: Float64
                        if ch == FXC_F64:
                            fv = (
                                fx_ptrs[f].bitcast[Scalar[DType.float64]]()
                                + fx_offs[f]
                                + row
                            )[]
                        else:
                            fv = Float64(
                                (
                                    fx_ptrs[f].bitcast[Scalar[DType.float32]]()
                                    + fx_offs[f]
                                    + row
                                )[]
                            )
                        if afn == AGG_SUM or afn == AGG_MEAN:
                            cell.f_acc += fv
                        elif afn == AGG_MIN:
                            # QUOTIENT ORDER, NOT a bare `<` / `>`: IEEE compares false against
                            # a NaN, so `max{0.1, NaN}` would answer 0.1, while the reference
                            # answer is NaN (NaN sorts above +inf). Every float MIN/MAX in this
                            # file compares through `float_quotient_lt_f64` / `_gt_f64` for that
                            # reason.
                            if cell.n == Int64(1) or float_quotient_lt_f64(fv, cell.f_acc):
                                cell.f_acc = fv
                        else:
                            # Quotient order, as above.
                            if cell.n == Int64(1) or float_quotient_gt_f64(fv, cell.f_acc):
                                cell.f_acc = fv

    # ⭐⭐ THE PASSENGER FOLD, ONE FIXED AGGREGATE AT A TIME OVER THE WHOLE
    # BATCH. See `_cd_fx_fold_batch`.
    comptime if has_fixed:
        if fxcol:
            if len(st.group_keys) > Int(Int32.MAX):
                raise Error(
                    "WorkerCDState.consume_batch: more groups than the"
                    " passenger lane's Int32 gid vector can carry."
                )
            _cd_fx_fold_batch[bo](
                st, fx_gids, fx_chan, fx_ptrs, fx_offs, fxlanes
            )

    _ = fxlanes  # MIXEDFUSE: the fixed validity borrow, kept live to here
    st.stat_appends += n_appended
    st.stat_set_inserts += n_set_inserted
    st.stat_gid_dense += n_gid_dense_hit
    st.stat_adj_skipped += n_adj_skipped
    # A memo hit resolved a Dict-arm row without probing: it counts toward
    # `stat_gid_dict` so `stat_gid_dense + stat_gid_dict` still partitions
    # the non-NULL key rows, and toward its own witness.
    st.stat_gid_dict += n_lastkey_hit
    st.stat_gid_lastkey += n_lastkey_hit

    _ = klanes  # CD-KEY-NULL: the key validity borrow, kept live to here
    _ = batch  # keepalive



def _cd_fx_fold_batch[bo: Origin](
    mut st: WorkerCDState,
    imm gids: List[Int32],
    imm fx_chan: List[UInt8],
    imm fx_ptrs: List[UnsafePointer[Scalar[DType.int64], bo]],
    imm fx_offs: List[Int],
    imm fxlanes: ValidityLanes[bo],
) raises:
    """⭐⭐ Fold every fixed aggregate over
    one batch, ONE AGGREGATE AT A TIME, against the gids the CD row loop
    resolved (`gids[row]`).

    WHY COLUMN-MAJOR. The lane used to fold inside the CD row loop, so
    every row paid, per fixed aggregate, the channel / function / int-lane
    lookups, a validity probe and a two-level `fx_cells[f][gid]` index — an
    interpreter step per (row, aggregate): on a mixed query that was the
    bulk of `consume_batch`'s extra cost over the all-CD one (37.7% vs
    30.2% of samples; +14.2G instructions per query).
    Here every per-aggregate decision is taken ONCE per batch and the inner
    loop is a gid load, a value load and one cell update.

    The mixed query runs faster and executes fewer instructions; the
    all-COUNT(DISTINCT) control, which does not contain this code, is
    unchanged. Results are identical.

    ⛔ THE SEMANTICS ARE UNCHANGED, LINE FOR LINE, AND SO IS EVERY BIT OF
    EVERY ANSWER. Each cell still sees its rows in ascending row order —
    the per-row loop visited a cell's rows in that order too, and a cell
    belongs to exactly one aggregate — so even a FLOAT64 SUM adds the same
    values in the same sequence. NULL inputs are skipped; `n` counts
    CONTRIBUTING rows; a bare COUNT(*) (`FXC_NONE`) counts every row and
    never consults a validity lane (its lane borrows the KEY column as a
    placeholder); `n == 1` seeds MIN/MAX; SUM and MEAN share one
    accumulator. `agg_mixed_cd_fold` is still this lane's oracle."""
    var num_rows = len(gids)
    # SAFETY: `gp` borrows `gids`' buffer, which is not mutated here.
    var gp = gids.unsafe_ptr()
    for f in range(len(fx_chan)):
        var ch = fx_chan[f]
        var afn = st.fx_func[f]
        var is_int = st.fx_is_int[f]
        var nullable = ch != FXC_NONE and fxlanes.lane_is_nullable(f)
        # SAFETY: `cp` borrows `st.fx_cells[f]`'s buffer. Every gid in
        # `gids` was created by `_append_group` during the row loop that
        # precedes this call, and `_append_group` grows `fx_cells[f]` in
        # lockstep (plus the per-batch top-up in `consume_batch`), so every
        # `cp[g]` is in bounds. Nothing below appends to `fx_cells[f]`, so
        # the buffer cannot move under `cp`.
        var cp = st.fx_cells[f].unsafe_ptr()
        if ch == FXC_NONE:
            for row in range(num_rows):
                cp[Int(gp[row])].n += Int64(1)
            continue
        if afn == AGG_COUNT:
            for row in range(num_rows):
                if nullable and fxlanes.is_null_at(f, row):
                    continue
                cp[Int(gp[row])].n += Int64(1)
            continue
        var is_sum = afn == AGG_SUM or afn == AGG_MEAN
        var is_min = afn == AGG_MIN
        if is_int:
            # SAFETY: `p64`/`p32` borrow the batch's value buffer (origin
            # `bo`), live for the whole of `consume_batch`; `fx_offs[f]` is
            # the column's slice start, applied at the column's own width,
            # exactly as the per-row read did.
            var p64 = fx_ptrs[f] + fx_offs[f]
            var p32 = fx_ptrs[f].bitcast[Scalar[DType.int32]]() + fx_offs[f]
            var wide = ch == FXC_I64
            for row in range(num_rows):
                if nullable and fxlanes.is_null_at(f, row):
                    continue
                var iv: Int64
                if wide:
                    iv = p64[row]
                else:
                    iv = Int64(p32[row])
                ref cell = cp[Int(gp[row])]
                cell.n += Int64(1)
                if is_sum:
                    cell.i_acc += iv
                elif is_min:
                    if cell.n == Int64(1) or iv < cell.i_acc:
                        cell.i_acc = iv
                else:
                    if cell.n == Int64(1) or iv > cell.i_acc:
                        cell.i_acc = iv
        else:
            # SAFETY: as the integral arm, at FLOAT64 / FLOAT32 width.
            var q64 = fx_ptrs[f].bitcast[Scalar[DType.float64]]() + fx_offs[f]
            var q32 = fx_ptrs[f].bitcast[Scalar[DType.float32]]() + fx_offs[f]
            var wide_f = ch == FXC_F64
            for row in range(num_rows):
                if nullable and fxlanes.is_null_at(f, row):
                    continue
                var fv: Float64
                if wide_f:
                    fv = q64[row]
                else:
                    fv = Float64(q32[row])
                ref fcell = cp[Int(gp[row])]
                fcell.n += Int64(1)
                if is_sum:
                    fcell.f_acc += fv
                elif is_min:
                    # Quotient order, as above.
                    if fcell.n == Int64(1) or float_quotient_lt_f64(fv, fcell.f_acc):
                        fcell.f_acc = fv
                else:
                    # Quotient order, as above.
                    if fcell.n == Int64(1) or float_quotient_gt_f64(fv, fcell.f_acc):
                        fcell.f_acc = fv

