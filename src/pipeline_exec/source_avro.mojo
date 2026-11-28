# =============================================================================
# source_avro -- SOURCE_AVRO, one local Avro object container file as morsels
# =============================================================================
#
# `build_avro_source` reads the file a SOURCE_AVRO spec names, checks every
# column of its writer schema against the types the SQL surface reads, decodes
# it with the OCF reader's block-parallel entry
# (`avro.parallel_driver.read_avro_bytes_parallel`; with no dispatcher in the
# builder it decodes the blocks on this thread) at the schema the file's
# header gives, and serves the columns the spec names, in the spec's order, as
# a resident batch (`BatchSource`). No other decoder is involved and nothing
# is inferred: an Avro file states its own schema.
#
# The type envelope (§13.5 of the scan semantics, rulings 25 and 29) is
# checked on the writer schema before any block is decoded, so a file of no
# row is refused like a file of many, and every refusal names the column:
#
#   AvroDecodeError.UNSUPPORTED_FIELD_KIND   an `enum`, a `record`, an `array`
#                                            or a `map` column (DuckDB reads
#                                            them as ENUM, STRUCT, LIST, MAP)
#   AvroDecodeError.UNSUPPORTED_UNION        a union other than
#                                            ["null", T] / [T, "null"]
#                                            (DuckDB reads it as UNION)
#   AvroDecodeError.UNSUPPORTED_COLUMN_TYPE  a `duration`, a `uuid`, a
#                                            `timestamp-nanos` or a
#                                            `local-timestamp-nanos` column
#                                            (DuckDB reads INTERVAL, UUID,
#                                            TIMESTAMP_NS)
#
# A ["null", T] union is a nullable T column, checked as T. The tokens are
# the ones the decoder raises for the same kinds, so a refusal reads the same
# whichever side meets the type first.
#
# The file is checked against the plan: a column the spec names must be in
# the file at the type the spec gives it (AVRO_SOURCE_SCHEMA_MISMATCH), so a
# file rewritten between bind and run is an error, never another answer. Any
# failure to read or decode the file names it.
#
# The decoder reads a whole file at once, so the file is read before the
# first morsel; the source does not stream.

from arrow.schema import RecordBatch, Schema
from arrow_ipc.chunked_read import read_chunked
from avro.avro_schema import (
    AvroSchema,
    AVRO_KIND_ARRAY,
    AVRO_KIND_ENUM,
    AVRO_KIND_MAP,
    AVRO_KIND_NULL,
    AVRO_KIND_RECORD,
    AVRO_KIND_UNION,
)
from avro.ocf_header import decode_ocf_header
from avro.parallel_driver import read_avro_bytes_parallel
from byte_buffer.mmap_region import MmapRegion
from byte_buffer.shared_aligned_buffer import SharedAlignedBuffer
from column_kernels.compiler_helpers import (
    empty_batch_like_schema,
    project_batch_by_names,
)
from physical_plan.physical_plan import SourceSpecPod

from .source_batch import BatchSource


comptime AVRO_SOURCE_SCHEMA_MISMATCH: StaticString = "AVRO_SOURCE_SCHEMA_MISMATCH"
"""The token of the refusal of a file that lacks a column the spec names, or
holds it at another type than the spec's."""


def _value_node(schema: AvroSchema, idx: Int) -> Int:
    """The node a column's values are read at: T for ["null", T] or
    [T, "null"], the node itself otherwise."""
    ref n = schema.nodes[idx]
    if n.kind == AVRO_KIND_UNION and len(n.children) == 2:
        if schema.nodes[n.children[0]].kind == AVRO_KIND_NULL:
            return n.children[1]
        if schema.nodes[n.children[1]].kind == AVRO_KIND_NULL:
            return n.children[0]
    return idx


def _refused_column(
    path: String, column: String, token: StaticString, what: String
) -> Error:
    return Error(
        String(token)
        + ": column '"
        + column
        + "' of the Avro file '"
        + path
        + "' is "
        + what
        + ", which read_avro does not read yet"
    )


def _check_avro_column_types(schema: AvroSchema, path: String) raises:
    """Raise, naming the first column of `schema`'s root record whose type the
    SQL surface does not read (see the header for the list and the tokens);
    return when every column is read as DuckDB reads it."""
    ref root = schema.nodes[schema.root()]
    for i in range(len(root.children)):
        var column = root.field_names[i]
        var idx = _value_node(schema, root.children[i])
        ref n = schema.nodes[idx]
        if n.kind == AVRO_KIND_UNION:
            raise _refused_column(
                path,
                column,
                "AvroDecodeError.UNSUPPORTED_UNION",
                "a union of " + String(len(n.children)) + " branches",
            )
        if n.kind == AVRO_KIND_ENUM:
            raise _refused_column(
                path, column, "AvroDecodeError.UNSUPPORTED_FIELD_KIND", "an enum"
            )
        if n.kind == AVRO_KIND_RECORD:
            raise _refused_column(
                path,
                column,
                "AvroDecodeError.UNSUPPORTED_FIELD_KIND",
                "a nested record",
            )
        if n.kind == AVRO_KIND_ARRAY:
            raise _refused_column(
                path, column, "AvroDecodeError.UNSUPPORTED_FIELD_KIND", "an array"
            )
        if n.kind == AVRO_KIND_MAP:
            raise _refused_column(
                path, column, "AvroDecodeError.UNSUPPORTED_FIELD_KIND", "a map"
            )
        if (
            n.logical_type == "duration"
            or n.logical_type == "uuid"
            or n.logical_type == "timestamp-nanos"
            or n.logical_type == "local-timestamp-nanos"
        ):
            raise _refused_column(
                path,
                column,
                "AvroDecodeError.UNSUPPORTED_COLUMN_TYPE",
                "a " + n.logical_type,
            )


def _delivered(batch: RecordBatch, ref spec: SourceSpecPod) raises -> RecordBatch:
    """The columns of `batch` the spec names, in the spec's order; raises
    AVRO_SOURCE_SCHEMA_MISMATCH when one is missing or of another type."""
    ref want = spec.avro_schema
    var names = List[String]()
    for i in range(want.num_columns()):
        var name = want.field_name(i)
        var found = -1
        for j in range(batch.schema.num_columns()):
            if batch.schema.field_name(j) == name:
                found = j
                break
        if found < 0:
            raise Error(
                String(AVRO_SOURCE_SCHEMA_MISMATCH)
                + ": the Avro file '"
                + spec.avro_path
                + "' has no column '"
                + name
                + "' (the file changed after the query was bound)"
            )
        if batch.schema.field_arrow_type(found) != want.field_arrow_type(i):
            raise Error(
                String(AVRO_SOURCE_SCHEMA_MISMATCH)
                + ": column '"
                + name
                + "' of the Avro file '"
                + spec.avro_path
                + "' is "
                + String(batch.schema.field_arrow_type(found))
                + ", and the query was bound at "
                + String(want.field_arrow_type(i))
                + " (the file changed after the query was bound)"
            )
        names.append(name^)
    if len(names) == 0:
        # A spec of no column (what a count(*) reads) keeps the row count.
        return RecordBatch.count_only(batch.num_rows())
    return project_batch_by_names(batch, names)


def _mapped(path: String) raises -> SharedAlignedBuffer[MmapRegion]:
    """The bytes of the file at `path`, mapped; raises naming the file."""
    try:
        return read_chunked(path)
    except e:
        raise Error(
            "pipeline_exec: the Avro file '" + path + "' cannot be read: "
            + String(e)
        )


def _writer_schema(path: String, bytes: Span[UInt8, _]) raises -> AvroSchema:
    """The writer schema in the OCF header of `bytes`; raises naming the file
    when the header or its schema does not parse."""
    try:
        return decode_ocf_header(bytes).parse_schema()
    except e:
        raise Error(
            "pipeline_exec: the Avro file '" + path + "' cannot be read: "
            + String(e)
        )


def _decoded(path: String, bytes: Span[UInt8, _]) raises -> RecordBatch:
    """Every row of the OCF `bytes`, at the header's schema; raises naming
    the file when a block does not decode."""
    try:
        return read_avro_bytes_parallel(bytes)
    except e:
        raise Error(
            "pipeline_exec: the Avro file '" + path + "' cannot be decoded: "
            + String(e)
        )


def build_avro_source(
    ref spec: SourceSpecPod, morsel_rows: Int
) raises -> BatchSource:
    """The morsels of the Avro file `spec` names: its columns the spec names,
    in the spec's order; raises by name for a column type outside the
    envelope, a file that does not match the spec, or a file that cannot be
    read."""
    if spec.avro_path == "":
        raise Error("pipeline_exec: an Avro source names no path")
    var buf = _mapped(spec.avro_path)
    var bytes = buf.view_range_ro(0, buf.len()).into_span()
    _check_avro_column_types(
        _writer_schema(spec.avro_path, bytes), spec.avro_path
    )
    var batch = _decoded(spec.avro_path, bytes)
    _ = buf^
    var out = _delivered(batch, spec)
    if out.num_rows() == 0 and spec.avro_schema.num_columns() > 0:
        out = empty_batch_like_schema(spec.avro_schema)
    return BatchSource(out^, morsel_rows)
