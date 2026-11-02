# =============================================================================
# join_probe -- the join probe over two whole batches: every join type, every
# single-key strategy, for a physical plan's join probe (`MorselOp`).
# =============================================================================
#
# `execute_join_probe` executes what the operator says (keys, join type,
# physical algorithm, residual, output columns) over one probe batch and the
# completed build batch. It rewrites nothing; the choices it makes at run time
# change how the rows are found, never which rows come out:
#
#   * which arm runs the join, in this order:
#       1. a residual predicate: `execute_residual_join_probe` (it runs one
#          equi key or none, and refuses more);
#       2. CROSS: every pair of rows;
#       3. a key pair that is not one INT64-stored column on each side (two or
#          more keys, or a FLOAT64, INT32, STRING or dictionary key): the
#          composite-key join `execute_multi_key_join_probe` (INNER, LEFT,
#          SEMI, ANTI; RIGHT and FULL raise), whose float keys follow the float
#          model (NaN equals NaN, -0.0 equals +0.0); an INT32 or INT64 key
#          paired with a FLOAT64 key is cast to FLOAT64 and compares as one,
#          as DuckDB casts it to DOUBLE, and a STRING key paired with a
#          numeric key raises;
#       4. `JOIN_ALGO_SORT_MERGE` for INNER, LEFT, RIGHT and FULL: the
#          sort-merge join (SEMI and ANTI take the key set whatever the
#          algorithm says);
#       5. otherwise the single-INT64-key hash kernels below.
#   * INNER: when the build side has more than twice the probe side's rows,
#     the hash table is built on the probe side and the build side scans it;
#     then a perfect-hash table (dense unique build keys), a radix-partitioned
#     table (large build sides, unless the scan side is at least twice the
#     table and the table at most 1,000,000 rows), or the chained table; the
#     parallel probes above the engine's row gate; the fused single-pass or
#     chunked kernels only when every output column is one they can carry
#     (`komira_op_fused_kernels.join_fused_route`), else the per-column gather.
#     A projection that keeps at most three quarters of the columns probes
#     first and gathers the kept columns after.
#   * A NULL key matches nothing on any arm. The scan side's NULL mask is built
#     once, before the INNER arms, and every INNER arm takes it.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_async_api.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from komira_plan_ir.logical_plan import (
    JOIN_INNER, JOIN_LEFT, JOIN_RIGHT, JOIN_FULL, JOIN_SEMI, JOIN_ANTI,
    JOIN_CROSS, JOIN_ALGO_SORT_MERGE,
)
from komira_physical_plan.physical_plan import MorselOp
from komira_column_kernels.compiler_helpers import (
    copy_batch,
    gather_batch,
    project_batch_by_names,
)
from komira_join_assembly.compiler_join_assembly import (
    assemble_join_result_dispatch,
    assemble_join_result_projected_dispatch,
)

from komira_op_join_build.join import HashJoinBuilder
from komira_op_join_build.join_perfect_hash import PerfectHashJoin
from komira_op_join_build.join_probe_null_mask import ProbeNullMask
from komira_op_join_build.join_sort_merge import cross_join_indices
from komira_op_fused_kernels.join_chunked_gather import (
    assemble_inner_join_chunked,
)
from komira_op_fused_kernels.join_fused_gather import (
    assemble_inner_join_fused,
    assemble_inner_join_fused_projected,
)
from komira_op_fused_kernels.join_fused_route import (
    fused_join_cannot_carry_batches,
    fused_join_cannot_carry_output,
)
from komira_op_fused_kernels.parallel_gate import should_parallelize
from komira_op_fused_kernels.parallel_inner_probe import (
    parallel_inner_join_probe_into,
    parallel_perfect_inner_probe_into,
)

from .join_output_schema import (
    build_join_output_schema,
    build_join_output_schema_outer,
    project_semi_anti_result,
)
from .join_probe_multi_key import execute_multi_key_join_probe
from .join_probe_sort_merge import (
    execute_sort_merge_join_probe,
    execute_sort_merge_join_outer_probe,
)
from .nested_loop_join import execute_residual_join_probe
from .radix_join import RadixPartitionedHashJoin, should_use_radix_join
from .semi_join import SemiJoinHashSet


comptime _CHUNKED_MIN_SCAN_ROWS: Int = 50_000
"""Above this many scan rows a serial unprojected INNER join takes the
chunked kernel rather than the single-pass fused one."""

comptime _HIGH_FANOUT_CHAIN: Int = 4
"""An average chain at least this long takes the chunked kernel (or, when a
column needs the gather, collects the pairs first): a many-to-many join whose
pairs would not fit as two flat lists."""

comptime _RADIX_SKIP_TABLE_ROWS: Int = 1_000_000
"""A table at most this large is probed directly, not radix-partitioned, when
the scan side has at least twice its rows."""


def _int64_stored(at: ArrowType) -> Bool:
    """True iff a column of type `at` reads as INT64 values: INT64 itself and
    the temporal types stored as 64-bit integers."""
    return (
        at == ArrowType.INT64
        or at == ArrowType.DATE64
        or at == ArrowType.TIME64_US
        or at == ArrowType.TIME64_NS
        or at.is_duration()
        or at == ArrowType.INTERVAL_DAY_TIME
        or at.is_timestamp()
    )


def takes_composite_key_path(
    probe_batch: RecordBatch, build_batch: RecordBatch, op: MorselOp
) raises -> Bool:
    """True iff `execute_join_probe` sends this join to the composite-key
    join: two or more key pairs, or one pair that is not INT64-stored on both
    sides (there an integer key paired with a FLOAT64 key compares as
    FLOAT64). A key name that is not a column raises."""
    if len(op.probe_left_keys) != 1:
        return True
    var li = probe_batch.schema.column_index(op.probe_left_keys[0])
    var ri = build_batch.schema.column_index(op.probe_right_keys[0])
    return not (
        _int64_stored(probe_batch.schema.field_arrow_type(li))
        and _int64_stored(build_batch.schema.field_arrow_type(ri))
    )


def _assemble(
    mut dispatcher: LocalDispatcher[NoopSink],
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    var left_indices: List[Int],
    var right_indices: List[Int],
    out_schema: Schema,
    left_nullable: Bool = False,
    right_nullable: Bool = False,
) raises -> RecordBatch:
    """Every column of both sides at the index pairs, gathered over the
    dispatcher."""
    return assemble_join_result_dispatch[
        True, LocalDispatcher[NoopSink], origin_of(dispatcher)
    ](
        probe_batch,
        build_batch,
        left_indices^,
        right_indices^,
        out_schema,
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(dispatcher)]](
            Pointer(to=dispatcher)
        ),
        left_nullable=left_nullable,
        right_nullable=right_nullable,
    )


def _assemble_projected(
    mut dispatcher: LocalDispatcher[NoopSink],
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    var left_indices: List[Int],
    var right_indices: List[Int],
    output_cols: List[String],
    left_nullable: Bool = False,
    right_nullable: Bool = False,
) raises -> RecordBatch:
    """The `output_cols` columns at the index pairs, gathered over the
    dispatcher."""
    return assemble_join_result_projected_dispatch[
        True, LocalDispatcher[NoopSink], origin_of(dispatcher)
    ](
        probe_batch,
        build_batch,
        left_indices^,
        right_indices^,
        output_cols,
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(dispatcher)]](
            Pointer(to=dispatcher)
        ),
        left_nullable=left_nullable,
        right_nullable=right_nullable,
    )


def _assemble_for(
    mut dispatcher: LocalDispatcher[NoopSink],
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    var left_indices: List[Int],
    var right_indices: List[Int],
    op: MorselOp,
    out_schema: Schema,
    left_nullable: Bool = False,
    right_nullable: Bool = False,
) raises -> RecordBatch:
    """`_assemble_projected` when the operator projects, else `_assemble`."""
    if op.probe_output_cols:
        return _assemble_projected(
            dispatcher, probe_batch, build_batch, left_indices^,
            right_indices^, op.probe_output_cols.value(),
            left_nullable, right_nullable,
        )
    return _assemble(
        dispatcher, probe_batch, build_batch, left_indices^, right_indices^,
        out_schema, left_nullable, right_nullable,
    )


def execute_join_probe(
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    probe_batch: RecordBatch,
    op: MorselOp,
    build_batch: RecordBatch,
) raises -> RecordBatch:
    """Execute a join probe operator over one probe batch and the completed
    build side.

    The probe keys are `op.probe_left_keys`, the build keys
    `op.probe_right_keys`; `op.probe_join_type` is INNER, LEFT, RIGHT, FULL,
    SEMI, ANTI or CROSS. INNER, LEFT, RIGHT, FULL and CROSS emit probe columns
    then build columns (a build name that collides gets `_right`), or just
    `op.probe_output_cols`; SEMI and ANTI emit the kept probe rows, projected
    to `op.probe_output_cols` when set. The arm that runs is the header's.

    Args:
        dispatcher: Caller-owned dispatcher for the parallel probes and
            gathers.
        cancel_token: Caller-supplied token; cloned for each parallel call.
        probe_batch: The probe (left) side.
        op: The join probe operator.
        build_batch: The completed build (right) side.

    Returns:
        The joined batch.

    Raises:
        On a join the arms refuse: RIGHT or FULL over composite keys, more than
        one equi key with a residual, RIGHT or FULL with a residual, a STRING
        key paired with a numeric key.
    """
    var join_type = op.probe_join_type

    # The residual first: no other arm reads it, so an arm that ran first
    # would drop the predicate and emit the pairs it rejects.
    if op.probe_residual:
        return execute_residual_join_probe(
            probe_batch, build_batch, op, op.probe_residual.value(),
        )

    if join_type != JOIN_CROSS and takes_composite_key_path(
        probe_batch, build_batch, op
    ):
        if join_type == JOIN_RIGHT or join_type == JOIN_FULL:
            raise Error(
                "execute_join_probe: a RIGHT or FULL join over composite or"
                " non-INT64 keys is not supported (INNER, LEFT, SEMI and ANTI"
                " are). Workaround: the equivalent LEFT with sides swapped."
            )
        return execute_multi_key_join_probe(
            dispatcher, cancel_token.clone(), probe_batch, op, build_batch,
        )

    var num_probe_rows = probe_batch.num_rows()
    var num_build_rows = build_batch.num_rows()

    # Empty inputs. LEFT, ANTI and FULL keep their probe rows over an empty
    # build side, and RIGHT and FULL their build rows over an empty probe side;
    # every other join of an empty side is empty.
    if num_build_rows == 0 and join_type != JOIN_LEFT \
       and join_type != JOIN_ANTI and join_type != JOIN_FULL \
       and join_type != JOIN_RIGHT:
        return RecordBatch()
    if num_probe_rows == 0 and join_type != JOIN_RIGHT \
       and join_type != JOIN_FULL:
        return RecordBatch()

    if join_type == JOIN_CROSS:
        var ci = cross_join_indices(num_probe_rows, num_build_rows)
        var out_schema = build_join_output_schema(
            probe_batch.schema, build_batch.schema
        )
        return _assemble_for(
            dispatcher, probe_batch, build_batch, ci[0].copy(), ci[1].copy(),
            op, out_schema,
        )

    var right_key_idx = build_batch.schema.column_index(op.probe_right_keys[0])
    var right_key_arr = build_batch.column_at(right_key_idx).as_primitive[
        DType.int64
    ]()
    var left_key_idx = probe_batch.schema.column_index(op.probe_left_keys[0])
    var left_key_arr = probe_batch.column_at(left_key_idx).as_primitive[
        DType.int64
    ]()

    # The algorithm changes how pairs are found, never which: SEMI and ANTI
    # are not sort-merge shapes and take the key set below.
    if op.probe_algo == JOIN_ALGO_SORT_MERGE and join_type != JOIN_SEMI \
       and join_type != JOIN_ANTI:
        if join_type == JOIN_LEFT or join_type == JOIN_RIGHT \
           or join_type == JOIN_FULL:
            return execute_sort_merge_join_outer_probe(
                probe_batch, build_batch, left_key_arr, right_key_arr,
                join_type, op.probe_output_cols,
            )
        return execute_sort_merge_join_probe(
            probe_batch, build_batch, left_key_arr, right_key_arr,
            op.probe_output_cols,
        )

    if join_type == JOIN_SEMI:
        var semi_ht = SemiJoinHashSet(
            right_key_arr, dispatcher, cancel_token.clone()
        )
        var probe_indices = List[Int](capacity=min(num_probe_rows, semi_ht._count))
        semi_ht.probe_semi_parallel(
            dispatcher, cancel_token.clone(), left_key_arr, probe_indices,
        )
        var semi_result = gather_batch(probe_batch, probe_indices)
        if op.probe_output_cols:
            return project_semi_anti_result(
                semi_result^, op.probe_output_cols.value()
            )
        return semi_result^

    if join_type == JOIN_ANTI:
        var anti_result: RecordBatch
        if num_build_rows == 0:
            anti_result = copy_batch(probe_batch)
        else:
            var anti_ht = SemiJoinHashSet(
                right_key_arr, dispatcher, cancel_token.clone()
            )
            anti_result = gather_batch(
                probe_batch, anti_ht.probe_anti(left_key_arr)
            )
        if op.probe_output_cols:
            return project_semi_anti_result(
                anti_result^, op.probe_output_cols.value()
            )
        return anti_result^

    if join_type == JOIN_RIGHT or join_type == JOIN_FULL:
        return _execute_right_or_full(
            dispatcher, probe_batch, build_batch, left_key_arr,
            right_key_arr, join_type,
        )

    if join_type == JOIN_LEFT:
        return _execute_left(
            dispatcher, probe_batch, build_batch, left_key_arr,
            right_key_arr, op,
        )

    if join_type != JOIN_INNER:
        raise Error(
            "execute_join_probe: unknown join_type=" + String(Int(join_type))
        )
    return _execute_inner(
        dispatcher, cancel_token^, probe_batch, build_batch, left_key_arr,
        right_key_arr, op,
    )


def _execute_right_or_full(
    mut dispatcher: LocalDispatcher[NoopSink],
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    left_key_arr: PrimitiveArray[DType.int64],
    right_key_arr: PrimitiveArray[DType.int64],
    join_type: UInt8,
) raises -> RecordBatch:
    """RIGHT (every build row; matched pairs and unmatched build rows with a
    NULL probe side) or FULL (also every unmatched probe row with a NULL build
    side). The output is every column of both sides, the probe side nullable,
    and for FULL the build side too."""
    var full = join_type == JOIN_FULL
    var out_schema = build_join_output_schema_outer(
        probe_batch.schema, build_batch.schema,
        left_nullable=True, right_nullable=full,
    )
    var num_probe_rows = probe_batch.num_rows()
    var num_build_rows = build_batch.num_rows()
    var probe_indices = List[Int]()
    var build_indices = List[Int]()
    if num_build_rows == 0 or num_probe_rows == 0:
        # One side empty: every row of the side the join keeps, NULL-filled.
        if num_build_rows == 0 and full:
            for i in range(num_probe_rows):
                probe_indices.append(i)
                build_indices.append(-1)
        if num_probe_rows == 0:
            for i in range(num_build_rows):
                probe_indices.append(-1)
                build_indices.append(i)
    else:
        var join_builder = HashJoinBuilder.build(right_key_arr)
        var pairs = join_builder.probe_full(
            left_key_arr
        ) if full else join_builder.probe_right(left_key_arr)
        build_indices = pairs[0].copy()
        probe_indices = pairs[1].copy()
    return _assemble(
        dispatcher, probe_batch, build_batch, probe_indices^, build_indices^,
        out_schema, left_nullable=True, right_nullable=full,
    )


def _execute_left(
    mut dispatcher: LocalDispatcher[NoopSink],
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    left_key_arr: PrimitiveArray[DType.int64],
    right_key_arr: PrimitiveArray[DType.int64],
    op: MorselOp,
) raises -> RecordBatch:
    """LEFT: every probe row, an unmatched one with a NULL build side. A
    radix-partitioned table above its build-row threshold, else the chained
    table."""
    var num_probe_rows = probe_batch.num_rows()
    var num_build_rows = build_batch.num_rows()
    var out_schema = build_join_output_schema(
        probe_batch.schema, build_batch.schema
    )
    var build_indices = List[Int](capacity=num_probe_rows)
    var probe_indices = List[Int](capacity=num_probe_rows)
    if num_build_rows == 0:
        for i in range(num_probe_rows):
            build_indices.append(-1)
            probe_indices.append(i)
    elif should_use_radix_join(num_build_rows):
        var radix_join = RadixPartitionedHashJoin.build(right_key_arr)
        radix_join.probe_left_into(left_key_arr, build_indices, probe_indices)
    else:
        var join_builder = HashJoinBuilder.build(right_key_arr)
        join_builder.probe_left_into(left_key_arr, build_indices, probe_indices)
    return _assemble_for(
        dispatcher, probe_batch, build_batch, probe_indices^, build_indices^,
        op, out_schema, right_nullable=True,
    )


def _project_to(var batch: RecordBatch, op: MorselOp) raises -> RecordBatch:
    """`batch`, a join output over every column, cut to the operator's
    projection when it has one (columns are shared, not copied)."""
    if op.probe_output_cols:
        return project_batch_by_names(batch, op.probe_output_cols.value())
    return batch^


def _inner_output(
    mut dispatcher: LocalDispatcher[NoopSink],
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    var probe_indices: List[Int],
    var build_indices: List[Int],
    op: MorselOp,
    out_schema: Schema,
    late_mat: Bool,
) raises -> RecordBatch:
    """The INNER output at the pairs: just the projected columns under late
    materialization, else every column, then the projection if any."""
    if late_mat:
        return _assemble_projected(
            dispatcher, probe_batch, build_batch, probe_indices^,
            build_indices^, op.probe_output_cols.value(),
        )
    return _project_to(
        _assemble(
            dispatcher, probe_batch, build_batch, probe_indices^,
            build_indices^, out_schema,
        ),
        op,
    )


def _execute_inner(
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    left_key_arr: PrimitiveArray[DType.int64],
    right_key_arr: PrimitiveArray[DType.int64],
    op: MorselOp,
) raises -> RecordBatch:
    """INNER over one INT64 key, both sides non-empty; the arms are the
    header's. Every arm returns the same rows."""
    var num_probe_rows = probe_batch.num_rows()
    var num_build_rows = build_batch.num_rows()
    # The table goes on the smaller side when the build side has more than
    # twice the probe side's rows; the output columns stay probe then build.
    var flipped = num_build_rows > 2 * num_probe_rows and num_probe_rows > 0
    var ht_rows = num_probe_rows if flipped else num_build_rows
    var scan_rows = num_build_rows if flipped else num_probe_rows
    var radix_ok = should_use_radix_join(ht_rows) and not (
        scan_rows >= 2 * ht_rows and ht_rows <= _RADIX_SKIP_TABLE_ROWS
    )
    var late_mat = False
    if op.probe_output_cols:
        var total = probe_batch.num_columns() + build_batch.num_columns()
        late_mat = len(op.probe_output_cols.value()) * 4 <= total * 3
    var out_schema = build_join_output_schema(
        probe_batch.schema, build_batch.schema
    )
    # The scan side's NULL mask, built once for every arm below: the scan
    # side is the build side when the table went on the probe side.
    var scan_key_nulls = ProbeNullMask(
        right_key_arr, scan_rows
    ) if flipped else ProbeNullMask(left_key_arr, scan_rows)

    if not flipped:
        var perfect = PerfectHashJoin.try_build(right_key_arr)
        if perfect:
            var build_indices = List[Int](capacity=num_probe_rows)
            var probe_indices = List[Int](capacity=num_probe_rows)
            if should_parallelize(num_probe_rows, dispatcher.worker_count()):
                parallel_perfect_inner_probe_into(
                    dispatcher, cancel_token.clone(), perfect.value(),
                    left_key_arr, num_probe_rows, build_indices,
                    probe_indices, scan_key_nulls^,
                )
            else:
                perfect.value().probe_inner_into(
                    left_key_arr, build_indices, probe_indices
                )
            return _inner_output(
                dispatcher, probe_batch, build_batch, probe_indices^,
                build_indices^, op, out_schema, late_mat,
            )

    if radix_ok:
        var ht_out = List[Int](capacity=scan_rows)
        var scan_out = List[Int](capacity=scan_rows)
        if flipped:
            var radix_join = RadixPartitionedHashJoin.build(left_key_arr)
            radix_join.probe_inner_into(right_key_arr, ht_out, scan_out)
            return _inner_output(
                dispatcher, probe_batch, build_batch, ht_out^, scan_out^, op,
                out_schema, late_mat,
            )
        var radix_join = RadixPartitionedHashJoin.build(right_key_arr)
        radix_join.probe_inner_into(left_key_arr, ht_out, scan_out)
        return _inner_output(
            dispatcher, probe_batch, build_batch, scan_out^, ht_out^, op,
            out_schema, late_mat,
        )

    if late_mat:
        return _execute_inner_late_mat(
            dispatcher, cancel_token^, probe_batch, build_batch,
            left_key_arr, right_key_arr, op, flipped, scan_key_nulls^,
        )

    var cannot_carry = fused_join_cannot_carry_batches(probe_batch, build_batch)
    if flipped:
        var join_builder = HashJoinBuilder.build(left_key_arr)
        var left_indices = List[Int](capacity=scan_rows)
        var right_indices = List[Int](capacity=scan_rows)
        if should_parallelize(scan_rows, dispatcher.worker_count()):
            parallel_inner_join_probe_into(
                dispatcher, cancel_token.clone(), join_builder, right_key_arr,
                scan_rows, left_indices, right_indices, scan_key_nulls^,
            )
        else:
            join_builder.probe_inner_into(
                right_key_arr, left_indices, right_indices
            )
        return _inner_output(
            dispatcher, probe_batch, build_batch, left_indices^,
            right_indices^, op, out_schema, False,
        )

    var join_builder = HashJoinBuilder.build(right_key_arr)
    # PERF-CRITICAL: a many-to-many join (an average chain of four or more)
    # takes the chunked kernel, which probes and gathers in bounded chunks,
    # instead of collecting every pair into two flat lists first.
    var high_fanout = join_builder.avg_chain_length() >= _HIGH_FANOUT_CHAIN
    var batch: RecordBatch
    if high_fanout and not cannot_carry:
        batch = assemble_inner_join_chunked(
            probe_batch, build_batch, join_builder, left_key_arr, out_schema,
            scan_key_nulls,
        )
    elif (
        should_parallelize(scan_rows, dispatcher.worker_count())
        and not high_fanout
    ):
        var build_indices = List[Int](capacity=scan_rows)
        var probe_indices = List[Int](capacity=scan_rows)
        parallel_inner_join_probe_into(
            dispatcher, cancel_token.clone(), join_builder, left_key_arr,
            scan_rows, build_indices, probe_indices, scan_key_nulls^,
        )
        batch = _assemble(
            dispatcher, probe_batch, build_batch, probe_indices^,
            build_indices^, out_schema,
        )
    elif scan_rows > _CHUNKED_MIN_SCAN_ROWS and not cannot_carry \
         and not high_fanout:
        batch = assemble_inner_join_chunked(
            probe_batch, build_batch, join_builder, left_key_arr, out_schema,
            scan_key_nulls,
        )
    elif cannot_carry:
        # A column the fused kernels cannot carry (a NULL, or no fixed width):
        # collect the pairs, then the per-column gather.
        var build_indices = List[Int](capacity=scan_rows)
        var probe_indices = List[Int](capacity=scan_rows)
        join_builder.probe_inner_into(left_key_arr, build_indices, probe_indices)
        batch = _assemble(
            dispatcher, probe_batch, build_batch, probe_indices^,
            build_indices^, out_schema,
        )
    else:
        batch = assemble_inner_join_fused(
            probe_batch, build_batch, join_builder, left_key_arr, out_schema,
            scan_key_nulls,
        )
    return _project_to(batch^, op)


def _execute_inner_late_mat(
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    left_key_arr: PrimitiveArray[DType.int64],
    right_key_arr: PrimitiveArray[DType.int64],
    op: MorselOp,
    flipped: Bool,
    var scan_key_nulls: ProbeNullMask,
) raises -> RecordBatch:
    """INNER on the chained table with a narrow projection: the single-pass
    fused kernel writes just the projected columns when it can carry them and
    the probe is serial; otherwise probe (in parallel above the row gate),
    then gather the projected columns."""
    var cols = op.probe_output_cols.value().copy()
    var scan_rows = build_batch.num_rows() if flipped else probe_batch.num_rows()
    if not should_parallelize(
        scan_rows, dispatcher.worker_count()
    ) and not fused_join_cannot_carry_output(probe_batch, build_batch, cols):
        if flipped:
            var jb = HashJoinBuilder.build(left_key_arr)
            return assemble_inner_join_fused_projected(
                build_batch, probe_batch, jb, right_key_arr, cols,
                probe_batch, build_batch, False, scan_key_nulls,
            )
        var jb = HashJoinBuilder.build(right_key_arr)
        return assemble_inner_join_fused_projected(
            probe_batch, build_batch, jb, left_key_arr, cols,
            probe_batch, build_batch, True, scan_key_nulls,
        )

    var ht_side = List[Int](capacity=scan_rows)
    var scan_side = List[Int](capacity=scan_rows)
    if flipped:
        var jb = HashJoinBuilder.build(left_key_arr)
        if should_parallelize(scan_rows, dispatcher.worker_count()):
            parallel_inner_join_probe_into(
                dispatcher, cancel_token^, jb, right_key_arr, scan_rows,
                ht_side, scan_side, scan_key_nulls^,
            )
        else:
            jb.probe_inner_into(right_key_arr, ht_side, scan_side)
        return _assemble_projected(
            dispatcher, probe_batch, build_batch, ht_side^, scan_side^, cols,
        )
    var jb = HashJoinBuilder.build(right_key_arr)
    if should_parallelize(scan_rows, dispatcher.worker_count()):
        parallel_inner_join_probe_into(
            dispatcher, cancel_token^, jb, left_key_arr, scan_rows,
            ht_side, scan_side, scan_key_nulls^,
        )
    else:
        jb.probe_inner_into(left_key_arr, ht_side, scan_side)
    return _assemble_projected(
        dispatcher, probe_batch, build_batch, scan_side^, ht_side^, cols,
    )
