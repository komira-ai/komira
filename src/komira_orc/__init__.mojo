"""`komira_orc` — Apache ORC v1 (1.9.x) reader and writer.

The package is organised in layers:
  - footer.mojo      — the ORC metadata structures over the Protocol Buffers
    wire codec (`komira_protobuf`): PostScript (file tail header), Footer
    (schema + stripe directory), Metadata (stripe-level stats container),
    StripeFooter (per-stripe stream catalog + column encodings); 3-byte
    chunk-header framing + isOriginal short-circuit; OrcFileTail end-to-end
    metadata parse with leading + trailing "ORC" magic validation.
  - orc_schema.mojo  — ORC flat-arena type tree (Footer.types index links,
    NO recursive struct, NO UnsafePointer) -> Arrow type lattice;
    Hive-notation canonical form for round-trip equality testing.
  - rle_decode / rle_encode, orc_codec, column_decoder, nested_decoder —
    the stream encodings, the compression codecs and the column decoders.
  - orc_reader / orc_writer / orc_stride_skip — whole-file read and write,
    and the statistics-driven stripe and row-group pruning.

ORC metadata is Protocol Buffers (NOT Thrift like Parquet).

Dependency direction (cycle-free):
  komira_orc -> the core packages (ArrowType lattice), komira_protobuf,
                komira_async (the parallel stripe compress / decode path)
  Query engines and the SDK consume komira_orc, never the other way round.
"""

from .footer import (
    PostScript,
    Footer,
    Metadata,
    StripeFooter,
    StripeInformation,
    OrcRawType,
    OrcStream,
    OrcColumnEncoding,
    OrcColumnStatistics,
    OrcRowIndexEntry,
    OrcRowIndex,
    OrcBloomFilterEntry,
    OrcBloomFilterIndex,
    ChunkHeader,
    OrcFileTail,
    PbVarint,
    PbTag,
    PbLenField,
    pb_read_varint,
    pb_read_tag,
    pb_read_len_field,
    pb_skip_field,
    pb_read_string,
    parse_chunk_header,
    orc_compression_name,
    orc_encoding_name,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZLIB,
    ORC_COMPRESSION_SNAPPY,
    ORC_COMPRESSION_LZO,
    ORC_COMPRESSION_LZ4,
    ORC_COMPRESSION_ZSTD,
    ORC_STREAM_PRESENT,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_STREAM_DICTIONARY_DATA,
    ORC_STREAM_SECONDARY,
    ORC_STREAM_ROW_INDEX,
    ORC_STREAM_BLOOM_FILTER,
    ORC_STREAM_BLOOM_FILTER_UTF8,
    ORC_ENCODING_DIRECT,
    ORC_ENCODING_DICTIONARY,
    ORC_ENCODING_DIRECT_V2,
    ORC_ENCODING_DICTIONARY_V2,
    ORC_MAGIC_LEN,
    PB_WIRE_VARINT,
    PB_WIRE_FIXED64,
    PB_WIRE_LEN,
    PB_WIRE_FIXED32,
)
from .orc_schema import (
    OrcSchema,
    orc_node_to_arrow,
    orc_kind_name,
    ORC_KIND_BOOLEAN,
    ORC_KIND_BYTE,
    ORC_KIND_SHORT,
    ORC_KIND_INT,
    ORC_KIND_LONG,
    ORC_KIND_FLOAT,
    ORC_KIND_DOUBLE,
    ORC_KIND_STRING,
    ORC_KIND_BINARY,
    ORC_KIND_TIMESTAMP,
    ORC_KIND_LIST,
    ORC_KIND_MAP,
    ORC_KIND_STRUCT,
    ORC_KIND_UNION,
    ORC_KIND_DECIMAL,
    ORC_KIND_DATE,
    ORC_KIND_VARCHAR,
    ORC_KIND_CHAR,
    ORC_KIND_TIMESTAMP_INSTANT,
    ORC_DECIMAL_MAX_PRECISION,
)
from .rle_decode import (
    OrcIntReader,
    zigzag_decode,
    rlev2_decode_bit_width,
    decode_rlev1,
    decode_rlev2,
    decode_int_rle,
    decode_boolean_rle,
    decode_byte_rle,
    RLEV2_SHORT_REPEAT,
    RLEV2_DIRECT,
    RLEV2_PATCHED_BASE,
    RLEV2_DELTA,
)
from .orc_codec import decompress_stream, compress_stream
from .column_decoder import (
    StreamSpan,
    ColumnAcc,
    make_accumulator,
    decode_stripe_column,
)
from .nested_decoder import decode_column_subtree
from .orc_logical_arrow import (
    stamp_arrow_orc_metadata,
    is_acid_schema,
    acid_row_struct_index,
    acid_output_columns,
    AcidOutputColumns,
    ARROW_ORC_VARCHAR_MAX_LENGTH,
    ARROW_ORC_CHAR_LENGTH,
    ARROW_ORC_UNION_MODE,
    ARROW_ORC_ORIGINAL_TZ,
    ARROW_ORC_TIME_UNIT,
    ARROW_ORC_DURATION_UNIT,
    ARROW_ORC_INTERVAL_KIND,
    ARROW_ORC_FIXED_SIZE,
    ARROW_ORC_FIXED_LIST_SIZE,
    ARROW_ORC_MAP_KEYS_SORTED,
)
from .orc_reader import (
    read_orc_bytes,
    read_orc_bytes_opts,
    read_orc_bytes_projected,
    read_orc_bytes_with_dispatcher,
    read_orc_bytes_opts_with_dispatcher,
    read_orc_bytes_projected_with_dispatcher,
    read_orc_file,
    read_orc_file_opts,
    read_orc_file_with_dispatcher,
)
from .protobuf_writer import (
    pb_write_varint,
    pb_write_tag,
    pb_write_varint_field,
    pb_write_len_field,
    pb_write_string_field,
    pb_write_message_field,
    pb_write_sint64_field,
    pb_write_double_field,
    zigzag_encode,
    encode_type_node,
    encode_stripe_information,
    encode_stream,
    encode_column_encoding,
    encode_stripe_footer,
    encode_post_script,
    encode_footer,
    encode_metadata,
    encode_integer_statistics,
    encode_double_statistics,
    encode_string_statistics,
    encode_column_statistics,
    encode_stripe_statistics,
    encode_row_index_entry,
    encode_row_index,
    encode_bloom_filter,
    encode_bloom_filter_index,
)
from .bloom_filter import (
    OrcBloomFilter,
    make_orc_bloom_filter,
    wang64_hash,
    wang64_hash_double,
    murmur3_hash64,
    bloom_optimal_num_bits,
    bloom_optimal_num_hash_functions,
)
from .rle_encode import (
    encode_vulong,
    encode_vslong,
    encode_byte_rle,
    encode_boolean_rle,
    encode_int_rle_v2,
)
from .orc_writer import (
    OrcWriterOptions,
    write_orc_bytes,
    write_orc_file,
    write_orc_bytes_with_dispatcher,
    write_orc_file_with_dispatcher,
)
from .orc_stride_skip import (
    OrcFilteredResult,
    read_orc_bytes_filtered,
    OrcPrunedResult,
    read_orc_bytes_pruned,
)
