# =============================================================================
# orc_file_schema.mojo — an ORC file's tail and output schema, no row decoded.
# =============================================================================
#
# `read_orc_tail` parses the PostScript and the Footer of a file of any codec:
# the Footer of a compressed file is itself compressed with the file's codec,
# so `OrcFileTail.parse` (the uncompressed form) cannot read it. The Footer
# holds the type tree, the stripe directory and the row count.
#
# `read_orc_bytes_schema` is the schema `read_orc_bytes` gives the same file,
# derived from the Footer alone: the root struct's direct children in file
# order, each nullable, at the Arrow type `orc_node_to_arrow` maps it to; a
# file with a nested top-level column, or a Hive ACID file, at the schema of
# the nested path (ACID metadata columns suppressed, `row.*` lifted). A binder
# that has to name a file's columns before the plan runs reads this, and pays
# for the tail only (no stripe is read, no stream decompressed).
#
# Encapsulation: both take a borrowed Span and return owned values; no pointer
# crosses the module boundary.
# =============================================================================

from arrow.schema import Schema

from .footer import OrcFileTail
from .nested_decoder import nested_output_schema
from .orc_logical_arrow import _output_columns
from .orc_reader import (
    _build_output_schema,
    _parse_tail_codec_aware,
    _resolve_projection,
    _schema_needs_nested_path,
)
from .orc_schema import OrcSchema


def read_orc_tail(file_bytes: Span[UInt8, _]) raises -> OrcFileTail:
    """The PostScript and Footer of the complete ORC file `file_bytes`, of any
    codec (NONE, ZLIB, SNAPPY, LZO, LZ4, ZSTD).

    Raises:
        `OrcSchemaError.MALFORMED_PROTOBUF` for bytes that are not an ORC file
        (too short, no leading `ORC` magic, a PostScript or Footer that does
        not fit the file), and the codec's error for a Footer that does not
        decompress.
    """
    return _parse_tail_codec_aware(file_bytes)


def read_orc_bytes_schema(file_bytes: Span[UInt8, _]) raises -> Schema:
    """The schema `read_orc_bytes(file_bytes)` returns, read from the file's
    Footer alone: no stripe is read and no row decoded.

    Raises:
        What `read_orc_tail` raises; `OrcDecodeError.ROOT_NOT_STRUCT` for a
        file whose root type is not a struct; `OrcSchemaError.*` for a type
        tree the reader cannot map.
    """
    var tail = _parse_tail_codec_aware(file_bytes)
    var schema = OrcSchema.from_types(tail.footer.types.copy())
    if _schema_needs_nested_path(schema, False):
        var cols = _output_columns(schema, False)
        return nested_output_schema(schema, cols.node_idxs, cols.names)
    return _build_output_schema(
        schema, _resolve_projection(schema, List[Int]())
    )
