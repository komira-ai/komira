# =============================================================================
# protobuf_writer.mojo — ORC metadata protobuf ENCODER (the inverse of the
#                        footer.mojo decoder; the writer path).
# =============================================================================
#
# This is the symmetric flip of footer.mojo: it emits the 4 ORC metadata messages (PostScript /
# Footer / Metadata / StripeFooter) + the Type[] schema tree + per-stripe /
# per-file statistics, using the SAME field-number table as the decoder.
#
# Protocol Buffers wire encoding (the inverse of footer.mojo's readers):
#   - varint            : base-128 LEB128 (high bit = continuation).
#   - tag               : varint of (field_number << 3) | wire_type.
#   - length-delimited  : tag + varint(len) + payload (strings, sub-messages).
#   - (fixed32/64 are unused by ORC metadata; not emitted.)
#
# Every encoder builds an owned `List[UInt8]`; sub-messages are encoded into a
# child buffer then length-prefixed into the parent. No UnsafePointer crosses
# any module boundary (owned List/String only; pure index arithmetic).
# =============================================================================

# =============================================================================
# Protobuf primitive WRITERS live in the general `komira_protobuf` encoder;
# this module IMPORTS the pb_write_* primitives + zigzag_encode. The
# higher-level ORC-message encoders below (encode_footer, encode_post_script,
# ...) compose those primitives.
# =============================================================================

from komira_protobuf import (
    zigzag_encode,
    pb_write_varint,
    pb_write_tag,
    pb_write_varint_field,
    pb_write_len_field,
    pb_write_sint64_field,
    pb_write_double_field,
    pb_write_string_field,
    pb_write_message_field,
)


# =============================================================================
# Type encode — one ORC schema-tree node (inverse of OrcRawType.parse).
# =============================================================================
#
# Type fields (orc_proto.proto):
#   1 kind          Type.Kind enum (varint)
#   2 subtypes      repeated uint32 (we emit each as an individual varint)
#   3 fieldNames    repeated string (STRUCT / UNION field names)
#   4 maximumLength uint32 (VARCHAR / CHAR)
#   5 precision     uint32 (DECIMAL)
#   6 scale         uint32 (DECIMAL)


def encode_type_node(
    kind: Int,
    subtypes: List[Int],
    field_names: List[String],
    maximum_length: Int,
    precision: Int,
    scale: Int,
) -> List[UInt8]:
    """Encode one Footer.types Type node into a protobuf message buffer."""
    var out = List[UInt8]()
    pb_write_varint_field(out, 1, UInt64(kind))
    # subtypes: emit each child id as an individual (non-packed) varint — the
    # decoder accepts both packed and non-packed; non-packed is simplest.
    for i in range(len(subtypes)):
        pb_write_varint_field(out, 2, UInt64(subtypes[i]))
    for i in range(len(field_names)):
        pb_write_string_field(out, 3, field_names[i])
    if maximum_length > 0:
        pb_write_varint_field(out, 4, UInt64(maximum_length))
    if precision > 0:
        pb_write_varint_field(out, 5, UInt64(precision))
    if scale > 0:
        pb_write_varint_field(out, 6, UInt64(scale))
    return out^


# =============================================================================
# StripeInformation encode (inverse of StripeInformation.parse).
#   1 offset 2 indexLength 3 dataLength 4 footerLength 5 numberOfRows
# =============================================================================


def encode_stripe_information(
    offset: Int,
    index_length: Int,
    data_length: Int,
    footer_length: Int,
    number_of_rows: Int,
) -> List[UInt8]:
    var out = List[UInt8]()
    pb_write_varint_field(out, 1, UInt64(offset))
    pb_write_varint_field(out, 2, UInt64(index_length))
    pb_write_varint_field(out, 3, UInt64(data_length))
    pb_write_varint_field(out, 4, UInt64(footer_length))
    pb_write_varint_field(out, 5, UInt64(number_of_rows))
    return out^


# =============================================================================
# Stream + ColumnEncoding encode (inverse of OrcStream / OrcColumnEncoding).
#   Stream:         1 kind 2 column 3 length
#   ColumnEncoding: 1 kind 2 dictionarySize
# =============================================================================


def encode_stream(kind: Int, column: Int, length: Int) -> List[UInt8]:
    var out = List[UInt8]()
    pb_write_varint_field(out, 1, UInt64(kind))
    pb_write_varint_field(out, 2, UInt64(column))
    pb_write_varint_field(out, 3, UInt64(length))
    return out^


def encode_column_encoding(kind: Int, dictionary_size: Int) -> List[UInt8]:
    var out = List[UInt8]()
    pb_write_varint_field(out, 1, UInt64(kind))
    if dictionary_size > 0:
        pb_write_varint_field(out, 2, UInt64(dictionary_size))
    return out^


# =============================================================================
# StripeFooter encode (inverse of StripeFooter.parse).
#   1 streams (repeated Stream) 2 columns (repeated ColumnEncoding)
#   3 writerTimezone
# =============================================================================


def encode_stripe_footer(
    streams: List[List[UInt8]],
    column_encodings: List[List[UInt8]],
    writer_timezone: String,
) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(streams)):
        pb_write_message_field(out, 1, streams[i])
    for i in range(len(column_encodings)):
        pb_write_message_field(out, 2, column_encodings[i])
    if writer_timezone.byte_length() > 0:
        pb_write_string_field(out, 3, writer_timezone)
    return out^


# =============================================================================
# PostScript encode (inverse of PostScript.parse).
#   1 footerLength 2 compression 3 compressionBlockSize 4 version[] 5
#   metadataLength 8000 magic
# =============================================================================


def encode_post_script(
    footer_length: Int,
    compression: Int,
    compression_block_size: Int,
    version_major: Int,
    version_minor: Int,
    metadata_length: Int,
    magic: String,
) -> List[UInt8]:
    var out = List[UInt8]()
    pb_write_varint_field(out, 1, UInt64(footer_length))
    pb_write_varint_field(out, 2, UInt64(compression))
    if compression_block_size > 0:
        pb_write_varint_field(out, 3, UInt64(compression_block_size))
    # version is a repeated uint32 [major, minor].
    pb_write_varint_field(out, 4, UInt64(version_major))
    pb_write_varint_field(out, 4, UInt64(version_minor))
    pb_write_varint_field(out, 5, UInt64(metadata_length))
    pb_write_string_field(out, 8000, magic)
    return out^


# =============================================================================
# Footer encode (inverse of Footer.parse).
#   1 headerLength 2 contentLength 3 stripes[] 4 types[] 5 metadata[] (skip)
#   6 numberOfRows 7 statistics[] 8 rowIndexStride
# =============================================================================


def encode_footer(
    header_length: Int,
    content_length: Int,
    stripes: List[List[UInt8]],
    types: List[List[UInt8]],
    number_of_rows: Int,
    statistics: List[List[UInt8]],
    row_index_stride: Int,
) -> List[UInt8]:
    var out = List[UInt8]()
    pb_write_varint_field(out, 1, UInt64(header_length))
    pb_write_varint_field(out, 2, UInt64(content_length))
    for i in range(len(stripes)):
        pb_write_message_field(out, 3, stripes[i])
    for i in range(len(types)):
        pb_write_message_field(out, 4, types[i])
    pb_write_varint_field(out, 6, UInt64(number_of_rows))
    for i in range(len(statistics)):
        pb_write_message_field(out, 7, statistics[i])
    if row_index_stride > 0:
        pb_write_varint_field(out, 8, UInt64(row_index_stride))
    return out^


# =============================================================================
# Metadata encode (inverse of Metadata.parse).
#   1 stripeStats[] (repeated StripeStatistics)
# =============================================================================


def encode_metadata(stripe_stats: List[List[UInt8]]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(stripe_stats)):
        pb_write_message_field(out, 1, stripe_stats[i])
    return out^


# =============================================================================
# Statistics encode — ColumnStatistics + per-type sub-messages + StripeStats.
# =============================================================================
#
# ColumnStatistics fields (orc_proto.proto):
#   1 numberOfValues (uint64)  2 intStatistics  3 doubleStatistics
#   4 stringStatistics  5 bucketStatistics  10 hasNull (bool)
# IntegerStatistics: 1 minimum 2 maximum 3 sum  (ALL sint64 -> zigzag); sum
#   is omitted when it overflowed int64, as Apache ORC's Java writer does.
# DoubleStatistics:  1 minimum 2 maximum 3 sum  (ALL double -> fixed64).
# StringStatistics:  1 minimum (string) 2 maximum (string) 3 sum (sint64).
# StripeStatistics:  1 colStats (repeated ColumnStatistics).


def encode_integer_statistics(
    minimum: Int64, maximum: Int64, sum: Optional[Int64]
) -> List[UInt8]:
    """IntegerStatistics; field 3 (sum) only when `sum` is present (`None`
    means the sum overflowed int64)."""
    var out = List[UInt8]()
    pb_write_sint64_field(out, 1, minimum)
    pb_write_sint64_field(out, 2, maximum)
    if sum:
        pb_write_sint64_field(out, 3, sum.value())
    return out^


def encode_double_statistics(
    minimum: Float64, maximum: Float64, sum: Float64
) -> List[UInt8]:
    var out = List[UInt8]()
    pb_write_double_field(out, 1, minimum)
    pb_write_double_field(out, 2, maximum)
    pb_write_double_field(out, 3, sum)
    return out^


def encode_string_statistics(
    minimum: String, maximum: String, total_length: Int64
) -> List[UInt8]:
    var out = List[UInt8]()
    pb_write_string_field(out, 1, minimum)
    pb_write_string_field(out, 2, maximum)
    pb_write_sint64_field(out, 3, total_length)
    return out^


def encode_column_statistics(
    number_of_values: Int,
    has_null: Bool,
    int_stats: List[UInt8],
    double_stats: List[UInt8],
    string_stats: List[UInt8],
) -> List[UInt8]:
    """Encode one ColumnStatistics. Empty sub-message lists are omitted; pass
    an empty `List[UInt8]()` for the unused per-type stats slots."""
    var out = List[UInt8]()
    pb_write_varint_field(out, 1, UInt64(number_of_values))
    if len(int_stats) > 0:
        pb_write_message_field(out, 2, int_stats)
    if len(double_stats) > 0:
        pb_write_message_field(out, 3, double_stats)
    if len(string_stats) > 0:
        pb_write_message_field(out, 4, string_stats)
    pb_write_varint_field(out, 10, UInt64(1) if has_null else UInt64(0))
    return out^


def encode_stripe_statistics(col_stats: List[List[UInt8]]) -> List[UInt8]:
    """Encode one StripeStatistics: a repeated list of ColumnStatistics."""
    var out = List[UInt8]()
    for i in range(len(col_stats)):
        pb_write_message_field(out, 1, col_stats[i])
    return out^


# =============================================================================
# RowIndex encode (per-stride statistics + positions).
# =============================================================================
#
# orc_proto.proto:
#   message RowIndexEntry {
#     repeated uint64 positions = 1 [packed=true];
#     optional ColumnStatistics statistics = 2;
#   }
#   message RowIndex {
#     repeated RowIndexEntry entry = 1;
#   }
#
# Each column emits one ROW_INDEX stream = a serialized RowIndex with one
# RowIndexEntry per stride. The `statistics` sub-message holds the per-stride
# min/max/null-count that the stride-skip reader evaluates predicates against.
#
# `positions` is the seek table (chunk-byte-offset + decompressed-bytes-into-
# chunk + values-consumed at the stride boundary). This package's stride-skip
# reader does NOT seek via positions (it post-decode-filters whole strides),
# so the writer emits positions as the spec requires for cross-tool readers,
# while this package's own stride-skip relies on the statistics sub-message. Pass an empty positions list
# to omit the (optional, reader-tolerant) field.


def encode_row_index_entry(
    positions: List[Int], statistics: List[UInt8]
) -> List[UInt8]:
    """Encode one RowIndexEntry: packed positions + an embedded ColumnStatistics.
    """
    var out = List[UInt8]()
    # positions: packed repeated uint64 (field 1, wire LEN, concatenated varints).
    if len(positions) > 0:
        var packed = List[UInt8]()
        for i in range(len(positions)):
            pb_write_varint(packed, UInt64(positions[i]))
        pb_write_len_field(out, 1, Span(packed))
    if len(statistics) > 0:
        pb_write_message_field(out, 2, statistics)
    return out^


def encode_row_index(entries: List[List[UInt8]]) -> List[UInt8]:
    """Encode one RowIndex: a repeated list of RowIndexEntry sub-messages."""
    var out = List[UInt8]()
    for i in range(len(entries)):
        pb_write_message_field(out, 1, entries[i])
    return out^


# =============================================================================
# BloomFilter / BloomFilterIndex encode (per-stride bloom).
# =============================================================================
#
# orc_proto.proto:
#   message BloomFilter {
#     optional uint32 numHashFunctions = 1;
#     repeated fixed64 bitset = 2;     // legacy — NOT emitted
#     optional bytes utf8bitset = 3;   // current — the LE uint64[] byte buffer
#   }
#   message BloomFilterIndex { repeated BloomFilter bloomFilter = 1; }
#
# We emit ONLY the post-ORC-101 `utf8bitset` form (field 3), which orc-cpp /
# orc-java readers consume when ColumnEncoding.bloomEncoding == 1. This
# package's reader (`OrcBloomFilterEntry.parse`) reads field 3 directly.


def encode_bloom_filter(
    num_hash_functions: Int, utf8bitset: Span[UInt8, _]
) -> List[UInt8]:
    """Encode one BloomFilter: numHashFunctions + utf8bitset bytes."""
    var out = List[UInt8]()
    pb_write_varint_field(out, 1, UInt64(num_hash_functions))
    pb_write_len_field(out, 3, utf8bitset)
    return out^


def encode_bloom_filter_index(entries: List[List[UInt8]]) -> List[UInt8]:
    """Encode one BloomFilterIndex: a repeated list of BloomFilter sub-messages
    (one per stride)."""
    var out = List[UInt8]()
    for i in range(len(entries)):
        pb_write_message_field(out, 1, entries[i])
    return out^
