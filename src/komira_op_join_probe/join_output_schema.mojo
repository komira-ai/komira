# =============================================================================
# join_output_schema -- the output schema of a join, and the projection of a
# SEMI / ANTI result.
# =============================================================================
#
# A join's output is the probe (left) side's columns, then the build (right)
# side's; a build column whose name the probe side already uses is renamed with
# a `_right` suffix. Each field is copied whole (type, metadata, dictionary and
# decimal parameters) and only its name, and for an outer join its
# nullability, change.
# =============================================================================

from std.collections import Set

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema, SchemaBuilder

from komira_column_kernels.compiler_helpers import project_batch_by_names


def build_join_output_schema(
    left_schema: Schema, right_schema: Schema
) raises -> Schema:
    """The INNER join output schema: `left_schema`'s fields, then
    `right_schema`'s, a right name the left side uses suffixed `_right`."""
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


def build_join_output_schema_outer(
    left_schema: Schema,
    right_schema: Schema,
    left_nullable: Bool,
    right_nullable: Bool,
) raises -> Schema:
    """`build_join_output_schema`, with every field of a side that can come
    out NULL marked nullable: the left side for RIGHT and FULL
    (`left_nullable`), the right side for LEFT and FULL (`right_nullable`)."""
    var sb = SchemaBuilder()
    var left_names = Set[String]()
    for i in range(left_schema.num_columns()):
        left_names.add(left_schema.field_name(i))
        var lf = left_schema.field_at(i)
        if left_nullable:
            lf.nullable = True
        sb.add_field(lf^)
    for i in range(right_schema.num_columns()):
        var rname = right_schema.field_name(i)
        var rf = right_schema.field_at(i)
        if rname in left_names:
            rf.name = rname + "_right"
        if right_nullable:
            rf.nullable = True
        sb.add_field(rf^)
    return sb.build()


def project_semi_anti_result(
    var batch: RecordBatch, output_cols: List[String]
) raises -> RecordBatch:
    """A SEMI / ANTI result (probe columns only) cut to `output_cols`.

    Names that are not columns of `batch` (a build-side name a projection may
    carry) are dropped. An empty `output_cols` returns a column-less batch
    that keeps the row count, for a COUNT(*) over the join.
    """
    if len(output_cols) == 0:
        return RecordBatch.count_only(batch.num_rows())
    var names = List[String]()
    for i in range(len(output_cols)):
        var name = output_cols[i]
        for c in range(batch.schema.num_columns()):
            if batch.schema.field_name(c) == name:
                names.append(name)
                break
    if len(names) == batch.schema.num_columns():
        return batch^
    return project_batch_by_names(batch, names)
