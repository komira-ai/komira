# =============================================================================
# join_fused_route -- which inputs the fused and chunked join kernels carry
# =============================================================================
#
# The fused (`join_fused_gather`) and chunked (`join_chunked_gather`) INNER
# join kernels copy `element_size(type)` bytes per output row and emit every
# output column with no validity bitmap. So they carry a column only if
#
#   * its type has a fixed per-row byte width they can stride: not one of
#     the offsets or dictionary layouts (STRING, BINARY, LARGE_STRING,
#     LARGE_BINARY, DICTIONARY), and not BOOL, whose bits are packed; and
#   * it holds no NULL: a NULL cell would be copied as the value under its
#     cleared validity bit and come out as a non-NULL value.
#
# A caller asks `fused_join_cannot_carry_output` (projected output) or
# `fused_join_cannot_carry_batches` (every column of both sides) before it
# routes to those kernels, and takes the per-column gather of
# `komira_join_assembly` when the answer is True; that gather carries
# offsets, dictionaries, packed bits and validity. Each kernel raises on a
# column holding a NULL, so a caller that skips the question fails rather
# than returning wrong rows. Other layouts with no fixed width (nested, view,
# FIXED_SIZE_BINARY) are not routed here; `element_size` raises on them
# inside the kernels.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch
from komira_join_assembly.compiler_join_assembly import (
    resolve_join_output_cols,
    _JSIDE_PROBE,
)


@always_inline
def is_offsets_or_dictionary_type(at: ArrowType) -> Bool:
    """True iff `at` is STRING, BINARY, LARGE_STRING, LARGE_BINARY or
    DICTIONARY: the layouts that carry an offsets buffer or a dictionary.
    False for every other type, including the other layouts with no fixed
    byte width."""
    return (
        at == ArrowType.STRING
        or at == ArrowType.BINARY
        or at == ArrowType.LARGE_STRING
        or at == ArrowType.LARGE_BINARY
        or at == ArrowType.DICTIONARY
    )


@always_inline
def fused_join_cannot_carry_type(at: ArrowType) -> Bool:
    """True iff the fused and chunked kernels cannot stride a column of type
    `at`: an offsets or dictionary layout, or BOOL."""
    return is_offsets_or_dictionary_type(at) or at == ArrowType.BOOL


def fused_join_cannot_carry_column(batch: RecordBatch, col: Int) -> Bool:
    """True iff column `col` of `batch` cannot be carried by the fused and
    chunked kernels: its type is one `fused_join_cannot_carry_type` names, or
    it holds at least one NULL."""
    if fused_join_cannot_carry_type(batch.schema.field_arrow_type(col)):
        return True
    return batch.column_at(col).null_count() != 0


def fused_join_cannot_carry_output(
    left: RecordBatch,
    right: RecordBatch,
    output_names: List[String],
) raises -> Bool:
    """True iff any column `output_names` selects cannot be carried.

    Names resolve as `komira_join_assembly`'s `resolve_join_output_cols`
    resolves them: the left schema first, then the right, then a `_right`
    suffix on a name both sides share.

    Raises:
        If a name resolves to neither side.
    """
    var resolved = resolve_join_output_cols(left.schema, right.schema, output_names)
    var sides = resolved[0].copy()
    var cols = resolved[1].copy()
    for i in range(len(sides)):
        if sides[i] == _JSIDE_PROBE:
            if fused_join_cannot_carry_column(left, cols[i]):
                return True
        elif fused_join_cannot_carry_column(right, cols[i]):
            return True
    return False


def fused_join_cannot_carry_batches(
    left: RecordBatch,
    right: RecordBatch,
) -> Bool:
    """True iff any column of `left` or `right` cannot be carried: the
    question for an unprojected join, whose output is every column of both
    sides."""
    for c in range(left.num_columns()):
        if fused_join_cannot_carry_column(left, c):
            return True
    for c in range(right.num_columns()):
        if fused_join_cannot_carry_column(right, c):
            return True
    return False


def require_null_free_column(
    batch: RecordBatch, col: Int, kernel: StaticString
) raises:
    """Raise, naming `kernel` and the column, if column `col` of `batch` holds
    a NULL. The fused and chunked kernels call this for every column they
    copy."""
    var nulls = batch.column_at(col).null_count()
    if nulls != 0:
        raise Error(
            String(kernel)
            + ": column '"
            + batch.schema.field_name(col)
            + "' holds "
            + String(nulls)
            + " NULL(s), which this kernel cannot carry; route by"
            " fused_join_cannot_carry_output / fused_join_cannot_carry_batches"
        )
