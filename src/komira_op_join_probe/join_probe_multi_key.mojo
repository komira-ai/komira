# =============================================================================
# join_probe_multi_key -- the composite-key join probe OPERATOR: one probe
# batch against a completed build batch, for a physical plan's join probe
# (`komira_physical_plan.MorselOp`) with two or more key pairs.
# =============================================================================
#
# It executes what the operator says (keys, join type, output columns) and
# rewrites nothing. The one choice it makes at run time is which side of an
# INNER join to index: the smaller, when the build side has more than twice the
# probe side's rows; INNER's output is the same either way.
# =============================================================================
from std.collections import Set

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.primitive_array import PrimitiveArray

from komira_plan_ir.logical_plan import (
    JOIN_INNER, JOIN_LEFT, JOIN_SEMI, JOIN_ANTI,
)
from komira_column_kernels.compiler_helpers import (
    copy_batch, gather_batch, project_batch_by_names,
)
from komira_join_assembly.compiler_join_assembly import (
    assemble_join_result,
    assemble_join_result_projected,
    assemble_join_result_dispatch,
    assemble_join_result_projected_dispatch,
)
from komira_physical_plan.physical_plan import MorselOp

from komira_async_api.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from .join_multi_key import (
    MultiKeyColumns,
)
from .join_key_extract import (
    extract_join_key_columns_typed,
    join_key_pairs_as_float64,
)
from .join_multi_key_builder import MultiKeyHashJoinBuilder
from .join_multi_key_filter import multi_key_probe_semi, multi_key_probe_anti
from .join_multi_key_parallel import (
    parallel_multi_key_inner_probe_into,
    _ENABLE_MULTI_KEY_PARALLEL_PROBE,
    _MK_PARALLEL_THRESHOLD,
)


def should_flip_multi_key_inner_join(
    num_build_rows: Int, num_probe_rows: Int
) -> Bool:
    """Predicate: should the multi-key INNER join flip its build side?

    Args:
        num_build_rows: Row count of the build side (right semantic).
        num_probe_rows: Row count of the probe side (left semantic).

    Returns:
        True iff the runtime flip should engage; False otherwise.
    """
    return num_build_rows > 2 * num_probe_rows and num_probe_rows > 0


def _mk_build_join_output_schema(
    left_schema: Schema, right_schema: Schema
) raises -> Schema:
    """Build inner-join output schema (left + right with `_right` on collision)."""
    var sb = SchemaBuilder()
    var left_names = Set[String]()
    for i in range(left_schema.num_columns()):
        left_names.add(left_schema.field_name(i))
        sb.add_field(left_schema.field_at(i))
    for i in range(right_schema.num_columns()):
        var rname = right_schema.field_name(i)
        var rf = right_schema.field_at(i)
        if rname in left_names:
            rf.name = rname + "_right"
        sb.add_field(rf^)
    return sb.build()


def _mk_project_semi_anti(
    var batch: RecordBatch, output_cols: List[String],
) raises -> RecordBatch:
    """Project a semi/anti join result to the requested column subset."""
    if len(output_cols) == 0:
        return RecordBatch.count_only(batch.num_rows())
    var names = List[String]()
    for i in range(len(output_cols)):
        var name = output_cols[i]
        var found = False
        for c in range(batch.schema.num_columns()):
            if batch.schema.field_name(c) == name:
                found = True
                break
        if found:
            names.append(name)
    if len(names) == batch.schema.num_columns():
        return batch^
    return project_batch_by_names(batch, names)


def execute_multi_key_join_probe(
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    probe_batch: RecordBatch,
    op: MorselOp,
    build_batch: RecordBatch,
) raises -> RecordBatch:
    """Execute a multi-key (N >= 2) join probe operator over one probe batch
    and the completed build side.

    The probe keys are `op.probe_left_keys`, the build keys
    `op.probe_right_keys`; `op.probe_join_type` selects INNER, LEFT, SEMI or
    ANTI (anything else raises). SEMI and ANTI return the kept probe rows,
    projected to `op.probe_output_cols` when set; INNER and LEFT assemble probe
    columns then build columns (a build name that collides gets `_right`), or
    just `op.probe_output_cols`. An INNER join whose build side has more than
    twice the probe side's rows builds on the probe side instead; the output
    is the same rows. INNER probes in parallel at or above
    `_MK_PARALLEL_THRESHOLD` probe rows.

    Args:
        dispatcher: Caller-owned LocalDispatcher reference. Forwarded
            to `probe_inner_into` for the parallel inner-probe path.
        cancel_token: Caller-supplied CancellationToken (consumed at
            the inner-probe call site).
        probe_batch: the probe-side batch (borrowed).
        op: join operator carrying probe_left_keys / probe_right_keys
            (len >= 2) and probe_join_type.
        build_batch: the completed build side (borrowed).

    Returns:
        The joined result batch.

    Raises:
        On a STRING key paired with a numeric key
        (`join_key_pairs_as_float64`), or a join type other than INNER, LEFT,
        SEMI or ANTI.
    """
    var num_probe_rows = probe_batch.num_rows()
    var num_build_rows = build_batch.num_rows()
    var join_type = op.probe_join_type

    # A pair of an integer key and a FLOAT64 key compares as FLOAT64 on both
    # sides (DuckDB's common type); a STRING against a number raises here.
    var as_float64 = join_key_pairs_as_float64(
        probe_batch, op.probe_left_keys, build_batch, op.probe_right_keys
    )

    if num_build_rows == 0 and join_type != JOIN_LEFT and join_type != JOIN_ANTI:
        return RecordBatch()
    if num_probe_rows == 0:
        return RecordBatch()

    var build_keys = extract_join_key_columns_typed[
        True, LocalDispatcher[NoopSink], origin_of(dispatcher)
    ](
        build_batch, op.probe_right_keys,
        Optional[
            Pointer[LocalDispatcher[NoopSink], origin_of(dispatcher)]
        ](Pointer(to=dispatcher)),
        as_float64,
    )
    var probe_keys = extract_join_key_columns_typed[
        True, LocalDispatcher[NoopSink], origin_of(dispatcher)
    ](
        probe_batch, op.probe_left_keys,
        Optional[
            Pointer[LocalDispatcher[NoopSink], origin_of(dispatcher)]
        ](Pointer(to=dispatcher)),
        as_float64,
    )

    if join_type == JOIN_SEMI:
        var semi_result: RecordBatch
        if num_build_rows == 0:
            semi_result = RecordBatch()
        else:
            var builder = MultiKeyHashJoinBuilder.build(build_keys^)
            var probe_indices = multi_key_probe_semi(builder, probe_keys)
            semi_result = gather_batch(probe_batch, probe_indices)
        if op.probe_output_cols:
            return _mk_project_semi_anti(semi_result^, op.probe_output_cols.value())
        return semi_result^

    if join_type == JOIN_ANTI:
        var anti_result: RecordBatch
        if num_build_rows == 0:
            anti_result = copy_batch(probe_batch)
        else:
            var builder = MultiKeyHashJoinBuilder.build(build_keys^)
            var probe_indices = multi_key_probe_anti(builder, probe_keys)
            anti_result = gather_batch(probe_batch, probe_indices)
        if op.probe_output_cols:
            return _mk_project_semi_anti(anti_result^, op.probe_output_cols.value())
        return anti_result^

    if join_type == JOIN_LEFT:
        var out_schema = _mk_build_join_output_schema(
            probe_batch.schema, build_batch.schema
        )
        if num_build_rows == 0:
            var dummy = List[Int](capacity=num_probe_rows)
            var pidx = List[Int](capacity=num_probe_rows)
            for i in range(num_probe_rows):
                dummy.append(-1)
                pidx.append(i)
            if op.probe_output_cols:
                return assemble_join_result_projected_dispatch[
                    True, LocalDispatcher[NoopSink], origin_of(dispatcher)
                ](
                    probe_batch, build_batch, pidx, dummy,
                    op.probe_output_cols.value(),
                    Optional[
                        Pointer[
                            LocalDispatcher[NoopSink], origin_of(dispatcher)
                        ]
                    ](Pointer(to=dispatcher)),
                    right_nullable=True,
                )
            return assemble_join_result_dispatch[
                True, LocalDispatcher[NoopSink], origin_of(dispatcher)
            ](
                probe_batch, build_batch, pidx, dummy, out_schema,
                Optional[
                    Pointer[LocalDispatcher[NoopSink], origin_of(dispatcher)]
                ](Pointer(to=dispatcher)),
                right_nullable=True,
            )
        var builder = MultiKeyHashJoinBuilder.build(build_keys^)
        var build_indices = List[Int](capacity=num_probe_rows)
        var probe_indices = List[Int](capacity=num_probe_rows)
        builder.probe_left_into(probe_keys, build_indices, probe_indices)
        if op.probe_output_cols:
            return assemble_join_result_projected_dispatch[
                True, LocalDispatcher[NoopSink], origin_of(dispatcher)
            ](
                probe_batch, build_batch, probe_indices^, build_indices^,
                op.probe_output_cols.value(),
                Optional[
                    Pointer[LocalDispatcher[NoopSink], origin_of(dispatcher)]
                ](Pointer(to=dispatcher)),
                right_nullable=True,
            )
        return assemble_join_result_dispatch[
            True, LocalDispatcher[NoopSink], origin_of(dispatcher)
        ](
            probe_batch, build_batch, probe_indices^, build_indices^, out_schema,
            Optional[
                Pointer[LocalDispatcher[NoopSink], origin_of(dispatcher)]
            ](Pointer(to=dispatcher)),
            right_nullable=True,
        )

    if join_type == JOIN_INNER:
        var flipped = should_flip_multi_key_inner_join(
            num_build_rows, num_probe_rows
        )
        var out_schema = _mk_build_join_output_schema(
            probe_batch.schema, build_batch.schema
        )
        if flipped:
            var builder = MultiKeyHashJoinBuilder.build(probe_keys^)
            var ht_indices = List[Int](capacity=num_build_rows)
            var scan_indices = List[Int](capacity=num_build_rows)
            comptime if _ENABLE_MULTI_KEY_PARALLEL_PROBE:
                if num_build_rows >= _MK_PARALLEL_THRESHOLD:
                    parallel_multi_key_inner_probe_into(
                        dispatcher, cancel_token^, builder,
                        build_keys, ht_indices, scan_indices,
                    )
                else:
                    builder.probe_inner_into(
                        build_keys, ht_indices, scan_indices,
                    )
            else:
                builder.probe_inner_into(
                    build_keys, ht_indices, scan_indices,
                )
            if op.probe_output_cols:
                var _r = assemble_join_result_projected_dispatch[
                    True, LocalDispatcher[NoopSink], origin_of(dispatcher)
                ](
                    probe_batch, build_batch,
                    ht_indices^, scan_indices^,
                    op.probe_output_cols.value(),
                    Optional[
                        Pointer[
                            LocalDispatcher[NoopSink], origin_of(dispatcher)
                        ]
                    ](Pointer(to=dispatcher)),
                )
                return _r^
            var _r2 = assemble_join_result_dispatch[
                True, LocalDispatcher[NoopSink], origin_of(dispatcher)
            ](
                probe_batch, build_batch,
                ht_indices^, scan_indices^, out_schema,
                Optional[
                    Pointer[LocalDispatcher[NoopSink], origin_of(dispatcher)]
                ](Pointer(to=dispatcher)),
            )
            return _r2^

        var builder = MultiKeyHashJoinBuilder.build(build_keys^)
        var ht_indices = List[Int](capacity=num_probe_rows)
        var scan_indices = List[Int](capacity=num_probe_rows)
        comptime if _ENABLE_MULTI_KEY_PARALLEL_PROBE:
            if num_probe_rows >= _MK_PARALLEL_THRESHOLD:
                parallel_multi_key_inner_probe_into(
                    dispatcher, cancel_token^, builder,
                    probe_keys, ht_indices, scan_indices,
                )
            else:
                builder.probe_inner_into(
                    probe_keys, ht_indices, scan_indices,
                )
        else:
            builder.probe_inner_into(
                probe_keys, ht_indices, scan_indices,
            )
        if op.probe_output_cols:
            var _r = assemble_join_result_projected_dispatch[
                True, LocalDispatcher[NoopSink], origin_of(dispatcher)
            ](
                probe_batch, build_batch,
                scan_indices^, ht_indices^,
                op.probe_output_cols.value(),
                Optional[
                    Pointer[LocalDispatcher[NoopSink], origin_of(dispatcher)]
                ](Pointer(to=dispatcher)),
            )
            return _r^
        var _r2 = assemble_join_result_dispatch[
            True, LocalDispatcher[NoopSink], origin_of(dispatcher)
        ](
            probe_batch, build_batch,
            scan_indices^, ht_indices^, out_schema,
            Optional[
                Pointer[LocalDispatcher[NoopSink], origin_of(dispatcher)]
            ](Pointer(to=dispatcher)),
        )
        return _r2^

    raise Error(
        "execute_multi_key_join_probe: unsupported join_type="
        + String(Int(join_type))
        + " for multi-key path. INNER / SEMI / ANTI / LEFT supported."
    )
