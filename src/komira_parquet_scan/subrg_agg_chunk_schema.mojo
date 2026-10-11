# =============================================================================
# subrg_agg_chunk_schema — the column type rule of a sub-row-group aggregate
# chunk
# =============================================================================
#
# The sub-row-group aggregate (`subrg_agg_executor`) builds each chunk's
# columns from a cursor's fixed buffer, and the chunk batch carries a schema
# the aggregate fold reads its column widths from. Both must name the same
# type for every column, so the type each builder produces is stated once,
# here, and the chunk schema is derived from it:
#
#   * a non-key aggregate input is WIDENED: an integer column is built as
#     INT64 (`resolve_flat_int64_col`, `build_flat_plain_col`) and a FLOAT or
#     DOUBLE one as FLOAT64 (`resolve_flat_f64_col`, `build_flat_plain_col`),
#     because the accumulator cell is 8 bytes wide. A schema stamped with the
#     footer type (INT32) over an INT64 buffer makes a width-driven fold read
#     every other 4-byte lane;
#   * a group key keeps its footer type: it is a dictionary column whose
#     dictionary values have the key's own width (`subrg_agg_fold`);
#   * a STRING column keeps STRING.
#
# The scan side takes the opposite rule (every column keeps its own type,
# `subrg_split_decode.subrg_build_chunk_schema`), because a scan's output is
# the collected rows themselves.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder

from .subrg_agg_plan import SubrgAggPlan


def subrg_agg_chunk_arrow_type(footer_at: ArrowType, is_key: Bool) -> ArrowType:
    """The Arrow type of the chunk column the aggregate builds for a projected
    column whose footer type is `footer_at`: the footer type for a key or a
    STRING column, FLOAT64 for a FLOAT32 / FLOAT64 input, INT64 for every
    other (integer) input."""
    if is_key:
        return footer_at
    if footer_at == ArrowType.STRING:
        return footer_at
    if footer_at == ArrowType.FLOAT32 or footer_at == ArrowType.FLOAT64:
        return ArrowType.FLOAT64
    return ArrowType.INT64


def subrg_agg_build_chunk_schema(plan: SubrgAggPlan) raises -> Schema:
    """The chunk batch schema of `plan`, in projection order, each field typed
    by `subrg_agg_chunk_arrow_type` and non-nullable (a cursor refuses a chunk
    holding a null)."""
    var sb = SchemaBuilder()
    for ci in range(len(plan.proj_names)):
        sb.add_field(
            Field(
                plan.proj_names[ci],
                subrg_agg_chunk_arrow_type(plan.col_arrow_types[ci], plan.is_key_proj(ci)),
                False,
            )
        )
    return sb.build()
