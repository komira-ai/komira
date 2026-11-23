# =============================================================================
# check_record_batch_stream: check, before a stream is handed out, that every
# batch crosses the Arrow C Stream Interface.
# =============================================================================
# `build_record_batch_stream` (c_data_stream.mojo) fills a caller's
# `ArrowArrayStream`, and a batch that cannot be exported is found only later,
# inside the consumer's `get_schema` or `get_next`, as EIO. A caller that must
# refuse a result before it writes the caller's stream (a C entry point that
# leaves `*out` untouched on failure) runs `check_record_batch_stream` first.
#
# The check builds what the stream's callbacks would build, through the same
# builders, and releases it at once: each column array of each batch, after the
# dictionary check `get_next` makes, then the schema `get_schema` returns
# (`_build_stream_schema`). Nothing built here leaves this module;
# each struct is a local released with `_release_unexported_*`, which frees the
# heap it owns (format and name strings, buffer and child slot arrays) and drops
# its share of the column bytes. The batches are only read.
#
# The refusals name the column and its Arrow type, and the batch for a refusal
# of the data. A batch that still carries a selection mask is refused: the
# export reads every row of the columns, so the rows the mask drops would cross
# the boundary.
# =============================================================================

from arrow.schema import RecordBatch, Schema
from arrow_ipc.c_data_stream import (
    _arrow_type_n_buffers,
    _build_column_array,
    _build_stream_schema,
    _check_dictionary_export,
    _release_unexported_array,
    _release_unexported_schema,
)
from containers.slab import Slab


def _column(schema: Schema, i: Int) -> String:
    return (
        "column '"
        + schema.field_name(i)
        + "' ("
        + String(schema.field_arrow_type(i))
        + ")"
    )


def check_record_batch_stream(schema: Schema, batches: Slab[RecordBatch]) raises:
    """Raise unless a stream of `batches` under `schema` exports whole.

    When this returns, `get_schema` and every `get_next` of
    `build_record_batch_stream(batches, schema, out)` build without a raise.
    The error names the column and its Arrow type, and the batch when the
    refusal is about a batch's data.
    """
    for i in range(schema.num_columns()):
        try:
            _ = _arrow_type_n_buffers(schema.field_arrow_type(i))
        except e:
            raise Error(
                "ArrowCStreamExport: "
                + _column(schema, i)
                + " cannot cross the Arrow C Data Interface: "
                + String(e)
            )
    for b in range(len(batches)):
        ref batch = batches[b]
        if batch.has_selection_mask():
            raise Error(
                "ArrowCStreamExport: batch "
                + String(b)
                + " carries a selection mask; materialize it before the"
                " export, which reads every row"
            )
        if batch.num_columns() != schema.num_columns():
            raise Error(
                "ArrowCStreamExport: batch "
                + String(b)
                + " has "
                + String(batch.num_columns())
                + " columns and the schema "
                + String(schema.num_columns())
            )
    for b in range(len(batches)):
        ref batch = batches[b]
        for i in range(schema.num_columns()):
            try:
                _check_dictionary_export(schema.field_at(i), batch.column_at(i))
                var array = _build_column_array(batch.column_at(i))
                _release_unexported_array(array)
            except e:
                raise Error(
                    "ArrowCStreamExport: "
                    + _column(schema, i)
                    + " of batch "
                    + String(b)
                    + ": "
                    + String(e)
                )
    # After the batches: the schema is built from batch 0, whose dictionary
    # check above names the column and the batch; what is left to refuse here
    # is an empty stream with a nested column.
    var root = _build_stream_schema(schema, batches)
    _release_unexported_schema(root)
