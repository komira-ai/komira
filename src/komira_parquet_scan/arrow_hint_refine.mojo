# =============================================================================
# arrow_hint_refine — apply a footer's `ARROW:schema` offset widths to a batch
# =============================================================================
#
# A file written by Arrow may record, in its `ARROW:schema` footer key, that a
# BYTE_ARRAY column was a LARGE_STRING or LARGE_BINARY (64-bit offsets). The
# Parquet types alone say STRING / BINARY. Every batch the scan reader hands
# out passes through `refine_batch_by_arrow_hint`, which respells such a
# column (Field and buffers together) when the footer asks for it.
#
# Only the offset-width respellings are taken: they are a re-offset of the
# same bytes (`Column.widened_to_int64_offsets`). A DICTIONARY hint leaves the
# spec type: this reader does not build a dictionary-encoded column from a
# plain string column, and labelling one DICTIONARY would be a wrong type, not
# a missing one. A file without the key, the common case, costs one
# `is_empty()`.
# =============================================================================

from komira_arrow.arrow_types import ArrowType, widen_offset_type
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_parquet.arrow_schema_hint import ArrowSchemaHint, refine_from_hint


def refine_offset_width_only(spec_type: ArrowType, hint: Optional[ArrowType]) -> ArrowType:
    """`refine_from_hint`, minus the DICTIONARY answer: STRING -> STRING |
    LARGE_STRING, BINARY -> BINARY | LARGE_BINARY, anything else unchanged."""
    var r = refine_from_hint(spec_type, hint)
    if r == ArrowType.DICTIONARY:
        return spec_type
    return r


def refine_batch_by_arrow_hint(var batch: RecordBatch, hint: ArrowSchemaHint) raises -> RecordBatch:
    """`batch` with each column the hint widens respelled (Field and
    buffers), its selection mask carried over; `batch` itself when nothing
    changes. A column whose Field and Column types differ (a dictionary kept
    under `preserve_dict`) is left as it is."""
    if hint.is_empty():
        return batch^
    var n = batch.num_columns()
    if n == 0:
        return batch^
    var wants = List[ArrowType]()
    var changed = False
    for i in range(n):
        var fld_t = batch.schema.field_arrow_type(i)
        var col_t = batch.column_at(i).arrow_type
        var refined = fld_t
        if col_t == fld_t:
            var r = refine_offset_width_only(fld_t, hint.type_for_name(batch.schema.field_name(i)))
            if r != fld_t and widen_offset_type(col_t) == r:
                refined = r
                changed = True
        wants.append(refined)
    if not changed:
        return batch^
    var mask = batch.take_selection_mask()
    var cols = batch.take_columns()
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder.with_capacity(n)
    for i in range(n):
        var old = cols.replace(i, Column[HeapRegion]())
        if wants[i] == old.arrow_type:
            sb.add_field(batch.schema.field_at(i))
            builder.add_column(old^)
        else:
            var wide = old.widened_to_int64_offsets()
            _ = old^
            sb.add_field(Field(batch.schema.field_name(i), wants[i], batch.schema.field_nullable(i)))
            builder.add_column(wide^)
    _ = cols^
    var out = builder.build(sb.build())
    if mask:
        out.set_selection_mask(mask.take())
    return out^
