"""`komira_avro` — Apache Avro 1.11.1 Object Container File (OCF) support.

Modules:
  - avro_schema.mojo  — Avro schema JSON parse -> Parsing Canonical Form ->
    CRC-64-AVRO ("Rabin") fingerprint; Avro->Arrow type lattice;
    recursive-schema reject-on-detect via name visit-stack.
  - json_string.mojo  — JSON string-literal decode for the schema parser
    (escapes incl. UTF-16 surrogate pairs, raw UTF-8 byte-exact) and the
    UTF-8 well-formedness check the header decoder uses.
  - ocf_header.mojo   — OCF header decode (magic + Avro-binary metadata map),
    codec dispatch on the Avro spec wire-name strings (note "zstandard",
    not "zstd"), 16-byte sync marker extraction.
  - ocf_block_scan.mojo — block-boundary discovery via chained sync-marker
    walk (+ scalar resync helper).
  - varint_decode_scalar.mojo / action_table.mojo / comptime_decoder.mojo —
    the data-level decoders (scalar reader, schema-compiled action table,
    comptime shape-kind cascade).
  - avro_codec.mojo — block codecs (null, deflate, snappy, bzip2, xz,
    zstandard).
  - avro_ocf_reader.mojo / parallel_driver.mojo — file readers, serial and
    block-parallel.
  - avro_logical_arrow.mojo — Avro logical types <-> Arrow types.
  - varint_encode.mojo / ocf_block_emit.mojo / avro_ocf_writer.mojo — the
    OCF writer.

Dependency direction (cycle-free, like komira_csv / komira_json):
  komira_avro -> the core packages (ArrowType lattice; byte_class SIMD)
  NOT komira_avro -> komira_parquet / komira_compiler / komira_sdk
  (those packages consume komira_avro).
"""

from .avro_schema import (
    AvroSchema,
    AvroNode,
    AvroDefault,
    avro_node_to_arrow,
    crc_64_avro,
    AVRO_KIND_NULL,
    AVRO_KIND_BOOLEAN,
    AVRO_KIND_INT,
    AVRO_KIND_LONG,
    AVRO_KIND_FLOAT,
    AVRO_KIND_DOUBLE,
    AVRO_KIND_BYTES,
    AVRO_KIND_STRING,
    AVRO_KIND_RECORD,
    AVRO_KIND_ENUM,
    AVRO_KIND_ARRAY,
    AVRO_KIND_MAP,
    AVRO_KIND_UNION,
    AVRO_KIND_FIXED,
    AVRO_DEFAULT_NONE,
    AVRO_DEFAULT_NULL,
    AVRO_DEFAULT_BOOL,
    AVRO_DEFAULT_INT,
    AVRO_DEFAULT_DOUBLE,
    AVRO_DEFAULT_STRING,
    AVRO_DEFAULT_BYTES,
)
from .ocf_header import (
    OcfHeader,
    decode_ocf_header,
    codec_tag_from_wire_name,
    codec_wire_name,
    AVRO_CODEC_NULL,
    AVRO_CODEC_DEFLATE,
    AVRO_CODEC_SNAPPY,
    AVRO_CODEC_BZIP2,
    AVRO_CODEC_XZ,
    AVRO_CODEC_ZSTANDARD,
    OCF_MAGIC_LEN,
    OCF_SYNC_LEN,
)
from .ocf_block_scan import (
    OcfBlock,
    scan_ocf_blocks,
    scan_ocf_blocks_after_header,
    find_sync_marker_from,
)
from .varint_decode_scalar import (
    AvroByteReader,
    decode_zigzag_long,
    ZigzagLong,
)
# There is deliberately no SIMD varint reader. A SIMD mirror of
# `varint_decode_scalar.mojo` was slower than the scalar reader (0.39x) and
# lacked its overflow-safe length guards; the action-table reader is
# `AvroByteReader`.
from .action_table import (
    ResolutionTable,
    ActionTableInterpreter,
    ColumnAccVariant,
    FieldAction,
    ReadFieldData,
    SynthesizeDefaultData,
    SkipBytesData,
    SelectBranchData,
    RemapEnumSymbolData,
    NULL_NONE,
    NULL_FIRST,
    NULL_SECOND,
    PROMOTE_NONE,
    PROMOTE_TO_LONG,
    PROMOTE_TO_FLOAT,
    PROMOTE_TO_DOUBLE,
    PROMOTE_STRING_TO_BYTES,
    PROMOTE_BYTES_TO_STRING,
)
from .avro_logical_arrow import (
    ArrowLogicalEntry,
    avro_node_to_arrow_with_override,
    from_arrow_avro_type_json,
    arrow_logical_annotation,
    is_lossy_arrow_type,
    ARROW_LT_INT8,
    ARROW_LT_INT16,
    ARROW_LT_UINT8,
    ARROW_LT_UINT16,
    ARROW_LT_UINT32,
    ARROW_LT_UINT64,
    ARROW_LT_FLOAT16,
    ARROW_LT_DATE64,
    ARROW_LT_TIMESTAMP_SECONDS,
    ARROW_LT_TIMESTAMP_NANOS,
    ARROW_LT_TIME_SECONDS,
    ARROW_LT_TIME_NANOS,
    ARROW_LT_DURATION_SECONDS,
    ARROW_LT_DURATION_MILLIS,
    ARROW_LT_DURATION_MICROS,
    ARROW_LT_DURATION_NANOS,
    ARROW_LT_UNION_SPARSE,
)
from .comptime_decoder import (
    classify_avro_shape,
    decode_avro_bytes_comptime,
    is_hot_shape,
    SHAPE_KIND_UNKNOWN,
    SHAPE_KIND_KAFKA_EVENT_ROW,
    SHAPE_KIND_STRUCT_OF_1_INT,
    SHAPE_KIND_STRUCT_OF_N_PRIMS,
    SHAPE_KIND_STRUCT_OF_NULLABLE_PRIMS,
    SHAPE_KIND_TPCH_LINEITEM_SHAPE,
    SHAPE_KIND_OPTIONAL_STRING_ARRAY,
    SHAPE_KIND_TWO_LEVEL_NESTED_RECORD,
    SHAPE_KIND_SINGLE_UNION_NULL_T,
)
from .avro_codec import decompress_block, compress_block, crc32_ieee
from .avro_ocf_reader import (
    read_avro_bytes,
    read_avro_file,
    read_avro_bytes_resolved,
    read_avro_file_resolved,
)
from .parallel_driver import (
    read_avro_bytes_parallel,
    read_avro_bytes_parallel_with_dispatcher,
)
from .avro_logical_arrow import from_arrow_schema_json
from .varint_encode import (
    encode_long,
    encode_int,
    encode_boolean,
    encode_float,
    encode_double,
    encode_string,
    encode_bytes,
    encode_fixed,
    encode_union_tag,
)
from .ocf_block_emit import (
    generate_sync_marker,
    emit_ocf_header,
    emit_ocf_block,
    should_flush_block,
    AVRO_DEFAULT_BLOCK_SIZE_BYTES,
    AVRO_DEFAULT_BLOCK_SIZE_ROWS,
)
from .avro_ocf_writer import (
    AvroWriterOptions,
    write_avro_bytes,
    write_avro_bytes_with_dispatcher,
    write_avro_file,
    write_avro_file_with_dispatcher,
)
