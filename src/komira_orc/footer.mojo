# =============================================================================
# footer.mojo — Apache ORC v1 metadata-parse foundation:
#   minimal Protocol Buffers wire decoder + PostScript / Footer / Metadata /
#   StripeFooter parse.
# =============================================================================
#
# This module is the FOUNDATION for the rest of the package. ORC's 4
# metadata structures are encoded as Protocol Buffers (NOT Thrift like
# Parquet). ORC reads the file tail from the END inward:
#
#   1. Read the LAST byte of the file = PostScript length (1..255).
#   2. PostScript occupies the `postscript_length` bytes immediately before
#      that last byte. It is ALWAYS uncompressed and carries the codec for
#      everything else.
#   3. Footer occupies `footer_length` bytes before the PostScript, optionally
#      compressed with the PostScript-declared codec.
#   4. Metadata (stripe-level stats) occupies `metadata_length` bytes before
#      the Footer, optionally compressed. Parsed lazily.
#   5. Per-stripe StripeFooter blobs live at the end of each stripe and carry
#      per-column stream byte sizes + column encodings.
#
# Compressed ORC streams are framed in 3-byte chunk headers: a 16-bit
# little-endian word `compressed_length << 1 | isOriginal_bit` plus a high
# byte (so the chunk-length field is effectively the low 23 bits). This module
# parses the chunk framing and short-circuits `isOriginal` (uncompressed)
# chunks; actual decompression (Zstd/Zlib/...) lives in orc_codec.mojo. For
# the NONE codec there is no chunk framing, so the metadata protobuf bytes are
# read raw.
#
# Encapsulation: the public API exposes only typed values (PostScript, Footer,
# Metadata, StripeFooter, Int/Int64, raised errors). No UnsafePointer crosses
# any module boundary. Internal storage uses owned List/String only; the
# protobuf reader walks a `Span[UInt8]` view with index arithmetic, no raw
# pointers.
#
# ⚠ KNOWN, UNFIXED, AND DELIBERATELY NAMED HERE — SUB-MESSAGE BOUNDARY
# ESCAPE.
#
# Every `parse`/`_parse_*` helper below walks a sub-message as
# `var pos = start; while pos < end:` and then reads with `pb_read_tag` /
# `pb_read_varint` / `pb_read_len_field` / `pb_skip_field`. Those free
# primitives bound themselves against `len(bytes)` — the WHOLE footer buffer
# — and NOT against this loop's `end`. So a nested field inside e.g.
# StripeInformation or ColumnStatistics can declare a length that runs past
# its parent's declared payload and read the SIBLING/PARENT bytes, which the
# loop then attributes to the inner message. Memory-safe (the buffer bound
# still holds) but it is field confusion on attacker-supplied ORC files.
#
# This is the SAME shape that `komira_protobuf`'s `PbFieldCursor._bound`
# closes (unbounded, a 2-byte sub-message can return a 20-byte string from
# its parent). It is not fixed here because these are ~12 hand-rolled loops
# whose repair is a per-loop `end` threading plus a per-loop falsifier — not
# because it is judged harmless. Do not read the absence of a fix as an
# absence of the defect.
# =============================================================================


# =============================================================================
# ORC CompressionKind enum (PostScript.compression). Matches orc_proto.proto.
# =============================================================================

comptime ORC_COMPRESSION_NONE: Int = 0
comptime ORC_COMPRESSION_ZLIB: Int = 1
comptime ORC_COMPRESSION_SNAPPY: Int = 2
comptime ORC_COMPRESSION_LZO: Int = 3
comptime ORC_COMPRESSION_LZ4: Int = 4
comptime ORC_COMPRESSION_ZSTD: Int = 5


@always_inline
def _write_orc_compression_name[W: Writer](mut writer: W, kind: Int):
    """WRITE what `orc_compression_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY; a shared library can
    bind such a pair CROSSED and crash the host process that loaded it."""
    if kind == ORC_COMPRESSION_NONE:
        writer.write(String("NONE"))
        return
    elif kind == ORC_COMPRESSION_ZLIB:
        writer.write(String("ZLIB"))
        return
    elif kind == ORC_COMPRESSION_SNAPPY:
        writer.write(String("SNAPPY"))
        return
    elif kind == ORC_COMPRESSION_LZO:
        writer.write(String("LZO"))
        return
    elif kind == ORC_COMPRESSION_LZ4:
        writer.write(String("LZ4"))
        return
    elif kind == ORC_COMPRESSION_ZSTD:
        writer.write(String("ZSTD"))
        return
    writer.write(String("UNKNOWN"))
    return


@always_inline
def orc_compression_name(kind: Int) -> String:
    """Human-readable ORC CompressionKind name (for diagnostics / tests)."""
    var out = String()
    _write_orc_compression_name(out, kind)
    return out^


# =============================================================================
# ORC Stream.Kind enum (StripeFooter.streams[*].kind). Matches orc_proto.proto.
# =============================================================================

comptime ORC_STREAM_PRESENT: Int = 0
comptime ORC_STREAM_DATA: Int = 1
comptime ORC_STREAM_LENGTH: Int = 2
comptime ORC_STREAM_DICTIONARY_DATA: Int = 3
comptime ORC_STREAM_DICTIONARY_COUNT: Int = 4
comptime ORC_STREAM_SECONDARY: Int = 5
comptime ORC_STREAM_ROW_INDEX: Int = 6
comptime ORC_STREAM_BLOOM_FILTER: Int = 7
comptime ORC_STREAM_BLOOM_FILTER_UTF8: Int = 8
comptime ORC_STREAM_ENCRYPTED_INDEX: Int = 9
comptime ORC_STREAM_ENCRYPTED_DATA: Int = 10


# =============================================================================
# ORC ColumnEncoding.Kind enum (StripeFooter.columns[*].kind).
# =============================================================================

comptime ORC_ENCODING_DIRECT: Int = 0
comptime ORC_ENCODING_DICTIONARY: Int = 1
comptime ORC_ENCODING_DIRECT_V2: Int = 2
comptime ORC_ENCODING_DICTIONARY_V2: Int = 3


@always_inline
def _write_orc_encoding_name[W: Writer](mut writer: W, kind: Int):
    """WRITE what `orc_encoding_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY; a shared library can
    bind such a pair CROSSED and crash the host process that loaded it."""
    if kind == ORC_ENCODING_DIRECT:
        writer.write(String("DIRECT"))
        return
    elif kind == ORC_ENCODING_DICTIONARY:
        writer.write(String("DICTIONARY"))
        return
    elif kind == ORC_ENCODING_DIRECT_V2:
        writer.write(String("DIRECT_V2"))
        return
    elif kind == ORC_ENCODING_DICTIONARY_V2:
        writer.write(String("DICTIONARY_V2"))
        return
    writer.write(String("UNKNOWN"))
    return


@always_inline
def orc_encoding_name(kind: Int) -> String:
    """Human-readable ColumnEncoding.Kind name (for diagnostics / tests)."""
    var out = String()
    _write_orc_encoding_name(out, kind)
    return out^


# =============================================================================
# Protobuf wire codec — the general `komira_protobuf` package. The wire-type
# constants, the PbVarint / PbTag / PbLenField result structs, and the
# pb_read_* primitive readers are IMPORTED from it (and `komira_orc`'s
# __init__.mojo re-exports the pb symbols).
# =============================================================================

from komira_protobuf import (
    PB_WIRE_VARINT,
    PB_WIRE_FIXED64,
    PB_WIRE_LEN,
    PB_WIRE_FIXED32,
    PbVarint,
    PbTag,
    PbLenField,
    pb_read_varint,
    pb_read_tag,
    pb_read_len_field,
    pb_skip_field,
    pb_read_string,
)


# =============================================================================
# THE uint64 -> Int BOUNDARY. Every metadata extent lands here.
# =============================================================================
#
# Every length / offset / count in ORC's metadata is a protobuf `uint64`, and
# `Int(v.value)` WRAPS SILENTLY: `Int(0xFFFF_FFFF_FFFF_FFFF)` is -1. That single
# fact is the root of most of this reader's hostile-input exposure, because the
# reader then does arithmetic on those Ints and slices `file_bytes[start:end]`
# with the result:
#
#   * `stripe_footer_start() = offset + index_length + data_length` — four
#     attacker-chosen uint64s summed with no overflow check.
#   * `footer_start = footer_end - ps.footer_length` — a
#     `footer_start < ORC_MAGIC_LEN` guard catches an honestly-LARGE length
#     (start goes very negative) but NOT a length >= 2^63, which wraps negative
#     and puts `footer_start` ABOVE `footer_end`.
#
# An INVERTED range is the lethal direction. Mojo's Span slicing CLAMPS an
# over-large end (so a merely-too-far offset degrades to a short span and the
# decoder raises TRUNCATED — not an OOB read), but `s[24:8]` on a 32-byte span
# yields a Span of length -16, and handing that to `decompress_stream`
# SIGSEGVs the process at ASSERT=none.
#
# So: reject the impossible value ONCE, HERE, where the field is first lifted
# off the wire — not at each of the ~10 downstream arithmetic sites. A field
# that is in range at parse time cannot invert a span later, and the per-field
# cost is one compare on a path that runs a few hundred times per FILE.
#
# THE CAP. `ORC_MAX_METADATA_EXTENT = 1 << 48` (256 TiB) is far above any real
# ORC file and far below the point where summing a handful of them can overflow
# Int64 — which is the property that makes the downstream sums safe without
# re-checking each one. It is deliberately NOT a "sane file size": a tighter cap
# would need to know the file length, which the protobuf parser does not have,
# and would reject legitimate footers from files we merely haven't seen. The
# tighter, file-relative checks belong at the slice sites (see
# `orc_reader._checked_file_span`) and exist there.

comptime ORC_MAX_METADATA_EXTENT: Int = 1 << 48


@always_inline
def orc_checked_extent(v: UInt64, field: StringSlice) raises -> Int:
    """Lift a protobuf uint64 length/offset/count to Int, or raise.

    The ONLY sanctioned conversion for an ORC metadata extent. A bare
    `Int(v.value)` on one of these fields is a bug — see the note above.
    """
    if v > UInt64(ORC_MAX_METADATA_EXTENT):
        raise Error(
            String("OrcSchemaError.FIELD_TOO_LARGE: ")
            + String(field)
            + " = "
            + String(v)
            + " exceeds the maximum ORC metadata extent "
            + String(ORC_MAX_METADATA_EXTENT)
            + " (a uint64 this large wraps NEGATIVE as an Int and inverts every"
            " byte range derived from it)"
        )
    return Int(v)


# =============================================================================
# PostScript — the file tail header (ALWAYS uncompressed; < 256 bytes).
# =============================================================================
#
# Fields (orc_proto.proto):
#   1 footerLength          uint64
#   2 compression           CompressionKind enum
#   3 compressionBlockSize  uint64
#   4 version               repeated uint32 (we keep the first two)
#   5 metadataLength        uint64
#   8000 magic              string ("ORC")


@fieldwise_init
struct PostScript(Copyable, Movable):
    """Parsed ORC PostScript (file tail header)."""

    var footer_length: Int
    var compression: Int
    var compression_block_size: Int
    var version_major: Int
    var version_minor: Int
    var metadata_length: Int
    var magic: String

    @staticmethod
    def parse(bytes: Span[UInt8, _]) raises -> PostScript:
        """Parse a PostScript protobuf from `bytes` (the whole PostScript)."""
        var footer_length = 0
        var compression = ORC_COMPRESSION_NONE
        var compression_block_size = 0
        var version_major = 0
        var version_minor = 0
        var metadata_length = 0
        var magic = String("")

        var pos = 0
        var n = len(bytes)
        var version_seen = 0
        while pos < n:
            var tag = pb_read_tag(bytes, pos)
            pos = tag.new_pos
            if tag.field_number == 1 and tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                footer_length = orc_checked_extent(v.value, "PostScript.footerLength")
                pos = v.new_pos
            elif tag.field_number == 2 and tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                compression = Int(v.value)
                pos = v.new_pos
            elif tag.field_number == 3 and tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                compression_block_size = orc_checked_extent(v.value, "PostScript.compressionBlockSize")
                pos = v.new_pos
            elif tag.field_number == 4 and tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                if version_seen == 0:
                    version_major = Int(v.value)
                elif version_seen == 1:
                    version_minor = Int(v.value)
                version_seen += 1
                pos = v.new_pos
            elif tag.field_number == 5 and tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                metadata_length = orc_checked_extent(v.value, "PostScript.metadataLength")
                pos = v.new_pos
            elif tag.field_number == 8000 and tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                magic = pb_read_string(bytes, f.payload_start, f.payload_end)
                pos = f.new_pos
            else:
                pos = pb_skip_field(bytes, pos, tag.wire_type)

        return PostScript(
            footer_length,
            compression,
            compression_block_size,
            version_major,
            version_minor,
            metadata_length,
            magic^,
        )


# =============================================================================
# Type — one node of the ORC schema tree (Footer.types is a flat pre-order
# list; this is the raw protobuf shape, lifted to OrcSchema in orc_schema.mojo).
# =============================================================================
#
# Fields (orc_proto.proto):
#   1 kind          Type.Kind enum
#   2 subtypes      repeated uint32 (child column ids; may be packed)
#   3 fieldNames    repeated string (STRUCT / UNION field names)
#   4 maximumLength uint32 (VARCHAR / CHAR length)
#   5 precision     uint32 (DECIMAL)
#   6 scale         uint32 (DECIMAL)


@fieldwise_init
struct OrcRawType(Copyable, Movable):
    """One raw ORC schema-tree node from Footer.types (pre-order, flat)."""

    var kind: Int
    var subtypes: List[Int]
    var field_names: List[String]
    var maximum_length: Int
    var precision: Int
    var scale: Int

    @staticmethod
    def parse(bytes: Span[UInt8, _], start: Int, end: Int) raises -> OrcRawType:
        """Parse one Type sub-message occupying `bytes[start:end)`."""
        var kind = 0
        var subtypes = List[Int]()
        var field_names = List[String]()
        var maximum_length = 0
        var precision = 0
        var scale = 0

        var pos = start
        while pos < end:
            var tag = pb_read_tag(bytes, pos)
            pos = tag.new_pos
            if tag.field_number == 1 and tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                kind = Int(v.value)
                pos = v.new_pos
            elif tag.field_number == 2 and tag.wire_type == PB_WIRE_VARINT:
                # subtypes as an individual (non-packed) varint.
                var v = pb_read_varint(bytes, pos)
                subtypes.append(Int(v.value))
                pos = v.new_pos
            elif tag.field_number == 2 and tag.wire_type == PB_WIRE_LEN:
                # packed subtypes; each varint is bounded by the block end.
                var f = pb_read_len_field(bytes, pos)
                var ip = f.payload_start
                while ip < f.payload_end:
                    var iv = pb_read_varint(bytes[: f.payload_end], ip)
                    subtypes.append(Int(iv.value))
                    ip = iv.new_pos
                pos = f.new_pos
            elif tag.field_number == 3 and tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                field_names.append(
                    pb_read_string(bytes, f.payload_start, f.payload_end)
                )
                pos = f.new_pos
            elif tag.field_number == 4 and tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                maximum_length = Int(v.value)
                pos = v.new_pos
            elif tag.field_number == 5 and tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                precision = Int(v.value)
                pos = v.new_pos
            elif tag.field_number == 6 and tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                scale = Int(v.value)
                pos = v.new_pos
            else:
                pos = pb_skip_field(bytes, pos, tag.wire_type)

        return OrcRawType(
            kind, subtypes^, field_names^, maximum_length, precision, scale
        )


# =============================================================================
# StripeInformation — one entry in Footer.stripes (the stripe directory).
# =============================================================================
#
# Fields (orc_proto.proto):
#   1 offset        uint64 (byte offset of the stripe in the file)
#   2 indexLength   uint64
#   3 dataLength    uint64
#   4 footerLength  uint64 (StripeFooter byte size, at the stripe's tail)
#   5 numberOfRows  uint64


@fieldwise_init
struct StripeInformation(Copyable, Movable):
    """One stripe-directory entry from Footer.stripes."""

    var offset: Int
    var index_length: Int
    var data_length: Int
    var footer_length: Int
    var number_of_rows: Int

    @staticmethod
    def parse(
        bytes: Span[UInt8, _], start: Int, end: Int
    ) raises -> StripeInformation:
        var offset = 0
        var index_length = 0
        var data_length = 0
        var footer_length = 0
        var number_of_rows = 0

        var pos = start
        while pos < end:
            var tag = pb_read_tag(bytes, pos)
            pos = tag.new_pos
            if tag.wire_type != PB_WIRE_VARINT:
                pos = pb_skip_field(bytes, pos, tag.wire_type)
                continue
            var v = pb_read_varint(bytes, pos)
            pos = v.new_pos
            if tag.field_number == 1:
                offset = orc_checked_extent(v.value, "StripeInformation.offset")
            elif tag.field_number == 2:
                index_length = orc_checked_extent(v.value, "StripeInformation.indexLength")
            elif tag.field_number == 3:
                data_length = orc_checked_extent(v.value, "StripeInformation.dataLength")
            elif tag.field_number == 4:
                footer_length = orc_checked_extent(v.value, "StripeInformation.footerLength")
            elif tag.field_number == 5:
                number_of_rows = orc_checked_extent(v.value, "StripeInformation.numberOfRows")

        return StripeInformation(
            offset, index_length, data_length, footer_length, number_of_rows
        )

    @always_inline
    def stripe_footer_start(self) -> Int:
        """Byte offset of this stripe's StripeFooter (index+data, then footer).
        """
        return self.offset + self.index_length + self.data_length

    @always_inline
    def stripe_footer_end(self) -> Int:
        """Byte offset one past this stripe's StripeFooter."""
        return self.stripe_footer_start() + self.footer_length


# =============================================================================
# Footer — file-level metadata (schema + stripe directory + row count).
# =============================================================================
#
# Fields (orc_proto.proto):
#   1 headerLength   uint64 (always 3 — "ORC" magic)
#   2 contentLength  uint64 (bytes of stripe content)
#   3 stripes        repeated StripeInformation
#   4 types          repeated Type (flat pre-order schema tree)
#   5 metadata       repeated UserMetadataItem (skipped)
#   6 numberOfRows   uint64
#   7 statistics     repeated ColumnStatistics (skipped)
#   8 rowIndexStride uint32


@fieldwise_init
struct Footer(Copyable, Movable):
    """Parsed ORC Footer."""

    var header_length: Int
    var content_length: Int
    var stripes: List[StripeInformation]
    var types: List[OrcRawType]
    var number_of_rows: Int
    var row_index_stride: Int

    @staticmethod
    def parse(bytes: Span[UInt8, _]) raises -> Footer:
        """Parse a Footer protobuf from the (already-decompressed) bytes."""
        var header_length = 0
        var content_length = 0
        var stripes = List[StripeInformation]()
        var types = List[OrcRawType]()
        var number_of_rows = 0
        var row_index_stride = 0

        var pos = 0
        var n = len(bytes)
        while pos < n:
            var tag = pb_read_tag(bytes, pos)
            pos = tag.new_pos
            if tag.field_number == 1 and tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                header_length = Int(v.value)
                pos = v.new_pos
            elif tag.field_number == 2 and tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                content_length = orc_checked_extent(v.value, "Footer.contentLength")
                pos = v.new_pos
            elif tag.field_number == 3 and tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                stripes.append(
                    StripeInformation.parse(
                        bytes, f.payload_start, f.payload_end
                    )
                )
                pos = f.new_pos
            elif tag.field_number == 4 and tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                types.append(
                    OrcRawType.parse(bytes, f.payload_start, f.payload_end)
                )
                pos = f.new_pos
            elif tag.field_number == 6 and tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                number_of_rows = orc_checked_extent(v.value, "Footer.numberOfRows")
                pos = v.new_pos
            elif tag.field_number == 8 and tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                row_index_stride = Int(v.value)
                pos = v.new_pos
            else:
                # fields 5 (metadata), 7 (statistics), and any unknown /
                # forward-compat field are skipped.
                pos = pb_skip_field(bytes, pos, tag.wire_type)

        return Footer(
            header_length,
            content_length,
            stripes^,
            types^,
            number_of_rows,
            row_index_stride,
        )

    @always_inline
    def num_stripes(self) -> Int:
        return len(self.stripes)


# =============================================================================
# Metadata — stripe-level statistics (Footer.metadata sibling blob).
# =============================================================================
#
# Fields (orc_proto.proto Metadata message):
#   1 stripeStats  repeated StripeStatistics
#
# The stripe-stats prune cascade level needs the actual per-stripe
# ColumnStatistics, so `Metadata.parse` decodes every StripeStatistics into
# `per_stripe_stats[stripe][node_id]`. The per-type min/max are the SAME
# structures the stride path trusts (produced by the same writer-side
# accumulators), just at coarser (whole-stripe) granularity.
# `stripe_stats_count` is the number of entries.


struct OrcStripeStatistics(Copyable, Movable):
    """One StripeStatistics: `colStats[node_id]` (orc_proto.proto field 1)."""

    var col_stats: List[OrcColumnStatistics]

    def __init__(out self):
        self.col_stats = List[OrcColumnStatistics]()

    def copy(self) -> Self:
        var c = OrcStripeStatistics()
        c.col_stats = self.col_stats.copy()
        return c^

    @staticmethod
    def parse(bytes: Span[UInt8, _], start: Int, end: Int) raises -> OrcStripeStatistics:
        var s = OrcStripeStatistics()
        var pos = start
        while pos < end:
            var tag = pb_read_tag(bytes, pos)
            pos = tag.new_pos
            if tag.field_number == 1 and tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                s.col_stats.append(
                    OrcColumnStatistics.parse(
                        bytes, f.payload_start, f.payload_end
                    )
                )
                pos = f.new_pos
            else:
                pos = pb_skip_field(bytes, pos, tag.wire_type)
        return s^


struct Metadata(Copyable, Movable):
    """Parsed ORC Metadata (stripe-level stats container)."""

    var stripe_stats_count: Int
    var per_stripe_stats: List[OrcStripeStatistics]

    def __init__(out self):
        self.stripe_stats_count = 0
        self.per_stripe_stats = List[OrcStripeStatistics]()

    def copy(self) -> Self:
        var c = Metadata()
        c.stripe_stats_count = self.stripe_stats_count
        c.per_stripe_stats = self.per_stripe_stats.copy()
        return c^

    @staticmethod
    def parse(bytes: Span[UInt8, _]) raises -> Metadata:
        var m = Metadata()
        var pos = 0
        var n = len(bytes)
        while pos < n:
            var tag = pb_read_tag(bytes, pos)
            pos = tag.new_pos
            if tag.field_number == 1 and tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                m.stripe_stats_count += 1
                m.per_stripe_stats.append(
                    OrcStripeStatistics.parse(
                        bytes, f.payload_start, f.payload_end
                    )
                )
                pos = f.new_pos
            else:
                pos = pb_skip_field(bytes, pos, tag.wire_type)
        return m^


# =============================================================================
# ColumnStatistics — per-column min/max/null statistics (stride decode).
# =============================================================================
#
# Fields (orc_proto.proto ColumnStatistics):
#   1  numberOfValues   uint64  (NON-null count)
#   2  intStatistics    IntegerStatistics { 1 minimum 2 maximum 3 sum (sint64) }
#   3  doubleStatistics DoubleStatistics  { 1 minimum 2 maximum 3 sum (double) }
#   4  stringStatistics StringStatistics  { 1 minimum 2 maximum (string) ... }
#   10 hasNull          bool
#
# The stride-skip reader consumes the per-stride form (one ColumnStatistics per RowIndexEntry).
# A `has_*` flag records which per-type sub-message was present so the predicate
# evaluator only trusts populated min/max. Strings keep min/max as bytes-as-str.


@always_inline
def _orc_zigzag_decode(u: UInt64) -> Int64:
    """ORC/Protobuf zigzag decode: (n >>> 1) ^ -(n & 1)."""
    return Int64((u >> 1)) ^ -Int64((u & 1))


struct OrcColumnStatistics(Copyable, Movable):
    """Parsed ORC ColumnStatistics (used per-stride by the stride-skip reader)."""

    var number_of_values: Int  # NON-null count
    var has_null: Bool
    var has_int: Bool
    var int_min: Int64
    var int_max: Int64
    var has_double: Bool
    var dbl_min: Float64
    var dbl_max: Float64
    var has_string: Bool
    var str_min: String
    var str_max: String

    def __init__(out self):
        self.number_of_values = 0
        self.has_null = False
        self.has_int = False
        self.int_min = 0
        self.int_max = 0
        self.has_double = False
        self.dbl_min = 0.0
        self.dbl_max = 0.0
        self.has_string = False
        self.str_min = String("")
        self.str_max = String("")

    def copy(self) -> Self:
        var c = OrcColumnStatistics()
        c.number_of_values = self.number_of_values
        c.has_null = self.has_null
        c.has_int = self.has_int
        c.int_min = self.int_min
        c.int_max = self.int_max
        c.has_double = self.has_double
        c.dbl_min = self.dbl_min
        c.dbl_max = self.dbl_max
        c.has_string = self.has_string
        c.str_min = self.str_min
        c.str_max = self.str_max
        return c^

    @staticmethod
    def parse(
        bytes: Span[UInt8, _], start: Int, end: Int
    ) raises -> OrcColumnStatistics:
        var s = OrcColumnStatistics()
        var pos = start
        while pos < end:
            var tag = pb_read_tag(bytes, pos)
            pos = tag.new_pos
            if tag.field_number == 1 and tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                s.number_of_values = Int(v.value)
                pos = v.new_pos
            elif tag.field_number == 10 and tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                s.has_null = v.value != 0
                pos = v.new_pos
            elif tag.field_number == 2 and tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                _parse_int_statistics(bytes, f.payload_start, f.payload_end, s)
                pos = f.new_pos
            elif tag.field_number == 3 and tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                _parse_double_statistics(
                    bytes, f.payload_start, f.payload_end, s
                )
                pos = f.new_pos
            elif tag.field_number == 4 and tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                _parse_string_statistics(
                    bytes, f.payload_start, f.payload_end, s
                )
                pos = f.new_pos
            else:
                pos = pb_skip_field(bytes, pos, tag.wire_type)
        return s^


def _parse_int_statistics(
    bytes: Span[UInt8, _], start: Int, end: Int, mut s: OrcColumnStatistics
) raises:
    var pos = start
    while pos < end:
        var tag = pb_read_tag(bytes, pos)
        pos = tag.new_pos
        if tag.wire_type != PB_WIRE_VARINT:
            pos = pb_skip_field(bytes, pos, tag.wire_type)
            continue
        var v = pb_read_varint(bytes, pos)
        pos = v.new_pos
        if tag.field_number == 1:
            s.int_min = _orc_zigzag_decode(v.value)
            s.has_int = True
        elif tag.field_number == 2:
            s.int_max = _orc_zigzag_decode(v.value)
            s.has_int = True


def _read_fixed64_double(bytes: Span[UInt8, _], pos: Int) raises -> Float64:
    from std.memory import bitcast

    if pos + 8 > len(bytes):
        raise Error("OrcSchemaError.MALFORMED_PROTOBUF: double past end")
    var bits: UInt64 = 0
    for k in range(8):
        bits |= UInt64(bytes[pos + k]) << UInt64(8 * k)
    return bitcast[DType.float64, 1](bits)


def _parse_double_statistics(
    bytes: Span[UInt8, _], start: Int, end: Int, mut s: OrcColumnStatistics
) raises:
    var pos = start
    while pos < end:
        var tag = pb_read_tag(bytes, pos)
        pos = tag.new_pos
        if tag.wire_type == PB_WIRE_FIXED64:
            if tag.field_number == 1:
                s.dbl_min = _read_fixed64_double(bytes, pos)
                s.has_double = True
            elif tag.field_number == 2:
                s.dbl_max = _read_fixed64_double(bytes, pos)
                s.has_double = True
            pos += 8
        else:
            pos = pb_skip_field(bytes, pos, tag.wire_type)


def _parse_string_statistics(
    bytes: Span[UInt8, _], start: Int, end: Int, mut s: OrcColumnStatistics
) raises:
    var pos = start
    while pos < end:
        var tag = pb_read_tag(bytes, pos)
        pos = tag.new_pos
        if tag.wire_type == PB_WIRE_LEN:
            var f = pb_read_len_field(bytes, pos)
            if tag.field_number == 1:
                s.str_min = pb_read_string(bytes, f.payload_start, f.payload_end)
                s.has_string = True
            elif tag.field_number == 2:
                s.str_max = pb_read_string(bytes, f.payload_start, f.payload_end)
                s.has_string = True
            pos = f.new_pos
        else:
            pos = pb_skip_field(bytes, pos, tag.wire_type)


# =============================================================================
# RowIndex — per-stride statistics + positions.
# =============================================================================
#
# Fields (orc_proto.proto):
#   RowIndexEntry { repeated uint64 positions = 1 [packed]; ColumnStatistics statistics = 2; }
#   RowIndex      { repeated RowIndexEntry entry = 1; }
#
# One ROW_INDEX stream per column = one serialized RowIndex; each RowIndexEntry
# is one stride. The stride-skip reader reads `entry[stride].statistics`.


struct OrcRowIndexEntry(Copyable, Movable):
    """One stride's row-index entry: positions (seek table) + statistics."""

    var positions: List[Int]
    var statistics: OrcColumnStatistics

    def __init__(out self):
        self.positions = List[Int]()
        self.statistics = OrcColumnStatistics()

    def copy(self) -> Self:
        var c = OrcRowIndexEntry()
        c.positions = self.positions.copy()
        c.statistics = self.statistics.copy()
        return c^

    @staticmethod
    def parse(
        bytes: Span[UInt8, _], start: Int, end: Int
    ) raises -> OrcRowIndexEntry:
        var e = OrcRowIndexEntry()
        var pos = start
        while pos < end:
            var tag = pb_read_tag(bytes, pos)
            pos = tag.new_pos
            if tag.field_number == 1 and tag.wire_type == PB_WIRE_LEN:
                # packed positions; each varint is bounded by the block end.
                var f = pb_read_len_field(bytes, pos)
                var pp = f.payload_start
                while pp < f.payload_end:
                    var pv = pb_read_varint(bytes[: f.payload_end], pp)
                    e.positions.append(Int(pv.value))
                    pp = pv.new_pos
                pos = f.new_pos
            elif tag.field_number == 1 and tag.wire_type == PB_WIRE_VARINT:
                # non-packed positions (each as its own varint field)
                var pv = pb_read_varint(bytes, pos)
                e.positions.append(Int(pv.value))
                pos = pv.new_pos
            elif tag.field_number == 2 and tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                e.statistics = OrcColumnStatistics.parse(
                    bytes, f.payload_start, f.payload_end
                )
                pos = f.new_pos
            else:
                pos = pb_skip_field(bytes, pos, tag.wire_type)
        return e^


struct OrcRowIndex(Copyable, Movable):
    """Parsed ORC RowIndex: one entry per stride for a single column."""

    var entries: List[OrcRowIndexEntry]

    def __init__(out self):
        self.entries = List[OrcRowIndexEntry]()

    def copy(self) -> Self:
        var c = OrcRowIndex()
        c.entries = self.entries.copy()
        return c^

    @staticmethod
    def parse(bytes: Span[UInt8, _]) raises -> OrcRowIndex:
        var ri = OrcRowIndex()
        var pos = 0
        var n = len(bytes)
        while pos < n:
            var tag = pb_read_tag(bytes, pos)
            pos = tag.new_pos
            if tag.field_number == 1 and tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                ri.entries.append(
                    OrcRowIndexEntry.parse(bytes, f.payload_start, f.payload_end)
                )
                pos = f.new_pos
            else:
                pos = pb_skip_field(bytes, pos, tag.wire_type)
        return ri^


# =============================================================================
# BloomFilter / BloomFilterIndex — per-stride bloom.
# =============================================================================
#
# Fields (orc_proto.proto):
#   message BloomFilter {
#     optional uint32 numHashFunctions = 1;
#     repeated fixed64 bitset = 2;     // legacy (pre-ORC-101) — REJECTED here
#     optional bytes utf8bitset = 3;   // post-ORC-101 (current) — what we use
#   }
#   message BloomFilterIndex { repeated BloomFilter bloomFilter = 1; }  // per-stride
#
# The reader uses ONLY the `utf8bitset` (field 3): a little-endian uint64[] stored
# as raw bytes. A bloom that arrives with only the legacy `bitset` field (3 is
# absent) is treated as UNSUPPORTED — `has_utf8bitset` stays False and the
# stride degrades to all-pass (never a false-skip).


struct OrcBloomFilterEntry(Copyable, Movable):
    """One stride's parsed bloom filter (numHashFunctions + utf8bitset bytes)."""

    var num_hash_functions: Int
    var has_utf8bitset: Bool
    var utf8bitset: List[UInt8]

    def __init__(out self):
        self.num_hash_functions = 0
        self.has_utf8bitset = False
        self.utf8bitset = List[UInt8]()

    def copy(self) -> Self:
        var c = OrcBloomFilterEntry()
        c.num_hash_functions = self.num_hash_functions
        c.has_utf8bitset = self.has_utf8bitset
        c.utf8bitset = self.utf8bitset.copy()
        return c^

    @staticmethod
    def parse(
        bytes: Span[UInt8, _], start: Int, end: Int
    ) raises -> OrcBloomFilterEntry:
        var e = OrcBloomFilterEntry()
        var pos = start
        while pos < end:
            var tag = pb_read_tag(bytes, pos)
            pos = tag.new_pos
            if tag.field_number == 1 and tag.wire_type == PB_WIRE_VARINT:
                var v = pb_read_varint(bytes, pos)
                # `numHashFunctions` is the iteration count of the
                # Kirsch-Mitzenmacher probe loop in `bloom_filter._add_hash` /
                # `_test_hash`, run once per stride-prune probe. The bit
                # ADDRESSING there is genuinely safe (`pos = combined % num_bits`
                # keeps every access inside the bitset), so this is not a memory
                # bug — it is an unbounded loop bound: a declared 2^40 hangs the
                # prune pass on ~10 bytes of index metadata. Real ORC writers
                # emit single digits (`bloom_optimal_num_hash_functions` returns
                # ~7 for the standard 1% FPP), so 64 costs nothing and is the
                # cheapest place to say so.
                if v.value > 64:
                    raise Error(
                        String("OrcSchemaError.FIELD_TOO_LARGE: BloomFilter")
                        + ".numHashFunctions = "
                        + String(v.value)
                        + " exceeds the maximum 64"
                    )
                e.num_hash_functions = Int(v.value)
                pos = v.new_pos
            elif tag.field_number == 3 and tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                e.utf8bitset = List[UInt8]()
                for i in range(f.payload_start, f.payload_end):
                    e.utf8bitset.append(bytes[i])
                e.has_utf8bitset = True
                pos = f.new_pos
            else:
                # field 2 (legacy fixed64 bitset) + unknown fields are skipped.
                pos = pb_skip_field(bytes, pos, tag.wire_type)
        return e^


struct OrcBloomFilterIndex(Copyable, Movable):
    """Parsed BloomFilterIndex: one BloomFilter entry per stride for a column."""

    var entries: List[OrcBloomFilterEntry]

    def __init__(out self):
        self.entries = List[OrcBloomFilterEntry]()

    def copy(self) -> Self:
        var c = OrcBloomFilterIndex()
        c.entries = self.entries.copy()
        return c^

    @staticmethod
    def parse(bytes: Span[UInt8, _]) raises -> OrcBloomFilterIndex:
        var bi = OrcBloomFilterIndex()
        var pos = 0
        var n = len(bytes)
        while pos < n:
            var tag = pb_read_tag(bytes, pos)
            pos = tag.new_pos
            if tag.field_number == 1 and tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                bi.entries.append(
                    OrcBloomFilterEntry.parse(
                        bytes, f.payload_start, f.payload_end
                    )
                )
                pos = f.new_pos
            else:
                pos = pb_skip_field(bytes, pos, tag.wire_type)
        return bi^


# =============================================================================
# Stream + ColumnEncoding — per-stripe wire entries (StripeFooter children).
# =============================================================================
#
# Stream fields (orc_proto.proto):
#   1 kind   Stream.Kind enum
#   2 column uint32 (column id this stream belongs to)
#   3 length uint64 (stream byte size)
#
# ColumnEncoding fields:
#   1 kind           ColumnEncoding.Kind enum
#   2 dictionarySize uint32


@fieldwise_init
struct OrcStream(Copyable, Movable):
    """One stream entry from a StripeFooter."""

    var kind: Int
    var column: Int
    var length: Int

    @staticmethod
    def parse(bytes: Span[UInt8, _], start: Int, end: Int) raises -> OrcStream:
        var kind = 0
        var column = 0
        var length = 0
        var pos = start
        while pos < end:
            var tag = pb_read_tag(bytes, pos)
            pos = tag.new_pos
            if tag.wire_type != PB_WIRE_VARINT:
                pos = pb_skip_field(bytes, pos, tag.wire_type)
                continue
            var v = pb_read_varint(bytes, pos)
            pos = v.new_pos
            if tag.field_number == 1:
                kind = Int(v.value)
            elif tag.field_number == 2:
                column = Int(v.value)
            elif tag.field_number == 3:
                length = orc_checked_extent(v.value, "Stream.length")
        return OrcStream(kind, column, length)


@fieldwise_init
struct OrcColumnEncoding(Copyable, Movable):
    """One column-encoding entry from a StripeFooter."""

    var kind: Int
    var dictionary_size: Int

    @staticmethod
    def parse(
        bytes: Span[UInt8, _], start: Int, end: Int
    ) raises -> OrcColumnEncoding:
        var kind = 0
        var dictionary_size = 0
        var pos = start
        while pos < end:
            var tag = pb_read_tag(bytes, pos)
            pos = tag.new_pos
            if tag.wire_type != PB_WIRE_VARINT:
                pos = pb_skip_field(bytes, pos, tag.wire_type)
                continue
            var v = pb_read_varint(bytes, pos)
            pos = v.new_pos
            if tag.field_number == 1:
                kind = Int(v.value)
            elif tag.field_number == 2:
                dictionary_size = orc_checked_extent(v.value, "ColumnEncoding.dictionarySize")
        return OrcColumnEncoding(kind, dictionary_size)


# =============================================================================
# StripeFooter — per-stripe stream catalog + per-column encoding.
# =============================================================================
#
# Fields (orc_proto.proto):
#   1 streams        repeated Stream
#   2 columns        repeated ColumnEncoding
#   3 writerTimezone string


@fieldwise_init
struct StripeFooter(Copyable, Movable):
    """Parsed ORC StripeFooter (per-stripe metadata)."""

    var streams: List[OrcStream]
    var columns: List[OrcColumnEncoding]
    var writer_timezone: String

    @staticmethod
    def parse(bytes: Span[UInt8, _]) raises -> StripeFooter:
        """Parse a StripeFooter protobuf from the (decompressed) bytes."""
        var streams = List[OrcStream]()
        var columns = List[OrcColumnEncoding]()
        var writer_timezone = String("")

        var pos = 0
        var n = len(bytes)
        while pos < n:
            var tag = pb_read_tag(bytes, pos)
            pos = tag.new_pos
            if tag.field_number == 1 and tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                streams.append(
                    OrcStream.parse(bytes, f.payload_start, f.payload_end)
                )
                pos = f.new_pos
            elif tag.field_number == 2 and tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                columns.append(
                    OrcColumnEncoding.parse(
                        bytes, f.payload_start, f.payload_end
                    )
                )
                pos = f.new_pos
            elif tag.field_number == 3 and tag.wire_type == PB_WIRE_LEN:
                var f = pb_read_len_field(bytes, pos)
                writer_timezone = pb_read_string(
                    bytes, f.payload_start, f.payload_end
                )
                pos = f.new_pos
            else:
                pos = pb_skip_field(bytes, pos, tag.wire_type)

        return StripeFooter(streams^, columns^, writer_timezone^)


# =============================================================================
# Chunk-header framing (ORC compressed-stream chunking).
# =============================================================================
#
# Each compressed ORC stream is broken into chunks. Every chunk is prefixed
# with a 3-byte LITTLE-ENDIAN header. The 24-bit value packs:
#   bit 0      : isOriginal (1 = chunk stored uncompressed)
#   bits 1..23 : compressed_length (the chunk payload byte count)
#
# So `compressed_length = (header24 >> 1)` and `is_original = header24 & 1`.
# ("compressed_length * 2 + isOriginal_bit" packs both into the field.) This
# module models the framing + short-circuits `isOriginal`; actual codec
# decompression is in orc_codec.mojo. The NONE codec has NO chunk framing at
# all — the stream IS the raw bytes.


@fieldwise_init
struct ChunkHeader(Copyable, Movable):
    """A decoded ORC compressed-stream chunk header."""

    var compressed_length: Int
    var is_original: Bool
    var payload_start: Int  # position immediately after the 3-byte header

    @always_inline
    def payload_end(self) -> Int:
        return self.payload_start + self.compressed_length


def parse_chunk_header(bytes: Span[UInt8, _], pos: Int) raises -> ChunkHeader:
    """Decode a 3-byte little-endian ORC chunk header at `pos`."""
    if pos + 3 > len(bytes):
        raise Error(
            "OrcSchemaError.MALFORMED_PROTOBUF: chunk header runs past buffer"
            " end"
        )
    var b0 = Int(bytes[pos])
    var b1 = Int(bytes[pos + 1])
    var b2 = Int(bytes[pos + 2])
    var header24 = b0 | (b1 << 8) | (b2 << 16)
    var is_original = (header24 & 1) == 1
    var compressed_length = header24 >> 1
    return ChunkHeader(compressed_length, is_original, pos + 3)


# =============================================================================
# OrcFileTail — the assembled file-tail metadata (PostScript + Footer +
# the byte-offset arithmetic that locates them).
# =============================================================================
#
# This is the metadata-only entry point for "open an ORC file and parse its
# metadata". It takes the WHOLE file bytes (in memory) and:
#   1. Reads the last byte = PostScript length.
#   2. Parses the PostScript.
#   3. Validates the leading "ORC" magic (3 bytes at file start).
#   4. Locates + parses the Footer (NONE codec → raw bytes).
#
# Metadata + per-stripe StripeFooter parse stay lazy (callers reach into the
# spans via `metadata_span` / `stripe_footer_span`) so a projection that
# never touches per-stripe stats pays nothing.


comptime ORC_MAGIC_LEN: Int = 3


@fieldwise_init
struct OrcFileTail(Copyable, Movable):
    """Assembled ORC file-tail metadata: PostScript + Footer."""

    var post_script: PostScript
    var footer: Footer
    var footer_start: Int
    var footer_end: Int
    var metadata_start: Int
    var metadata_end: Int

    @staticmethod
    def parse(bytes: Span[UInt8, _]) raises -> OrcFileTail:
        """Parse the metadata of a complete in-memory ORC file.

        Scope: the NONE codec (Footer + Metadata stored raw). For compressed
        files the Footer/Metadata spans must first be run through the
        chunk-framing + codec decompression (orc_codec) before being handed to
        `Footer.parse` / `Metadata.parse`; the whole-file reader does that.
        """
        var n = len(bytes)
        if n < ORC_MAGIC_LEN + 1:
            raise Error(
                "OrcSchemaError.MALFORMED_PROTOBUF: file too small to be ORC"
            )

        # Leading "ORC" magic.
        if not (
            bytes[0] == UInt8(ord("O"))
            and bytes[1] == UInt8(ord("R"))
            and bytes[2] == UInt8(ord("C"))
        ):
            raise Error(
                "OrcSchemaError.MALFORMED_PROTOBUF: missing leading 'ORC' magic"
            )

        # Last byte = PostScript length.
        var ps_len = Int(bytes[n - 1])
        if ps_len < 1:
            raise Error(
                "OrcSchemaError.MALFORMED_PROTOBUF: PostScript length is 0"
            )
        var ps_start = n - 1 - ps_len
        if ps_start < ORC_MAGIC_LEN:
            raise Error(
                "OrcSchemaError.MALFORMED_PROTOBUF: PostScript length overruns"
                " file start"
            )
        var ps = PostScript.parse(bytes[ps_start : n - 1])

        # Trailing magic inside the PostScript MUST be "ORC" (matches the
        # leading magic). orc_proto.proto stores it in field 8000.
        if ps.magic != "ORC":
            raise Error(
                String(
                    "OrcSchemaError.MALFORMED_PROTOBUF: PostScript magic is not"
                    " 'ORC' (got '"
                )
                + ps.magic
                + "')"
            )

        var footer_end = ps_start
        var footer_start = footer_end - ps.footer_length
        if footer_start < ORC_MAGIC_LEN:
            raise Error(
                "OrcSchemaError.MALFORMED_PROTOBUF: footer length overruns file"
                " start"
            )
        var metadata_end = footer_start
        var metadata_start = metadata_end - ps.metadata_length
        if metadata_start < ORC_MAGIC_LEN:
            raise Error(
                "OrcSchemaError.MALFORMED_PROTOBUF: metadata length overruns"
                " file start"
            )

        # NONE codec → Footer bytes are raw protobuf.
        if ps.compression != ORC_COMPRESSION_NONE:
            raise Error(
                String(
                    "OrcSchemaError.UNSUPPORTED: OrcFileTail.parse handles"
                    " NONE-codec ORC only; got compression "
                )
                + orc_compression_name(ps.compression)
                + " (decompress the tail through orc_codec, as the file"
                " reader does)"
            )

        # `PostScript.footerLength` / `.metadataLength` are bounded by
        # `orc_checked_extent` at parse time, so neither subtraction above can
        # wrap and invert these ranges. State the resulting
        # invariant rather than trusting it: this is the last thing between a
        # malformed tail and `Footer.parse`, and it is one compare on a path
        # that runs ONCE per file.
        if footer_end < footer_start or metadata_end < metadata_start:
            raise Error(
                String("OrcSchemaError.MALFORMED_PROTOBUF: inverted tail byte")
                + " range — footer ["
                + String(footer_start)
                + ", "
                + String(footer_end)
                + "), metadata ["
                + String(metadata_start)
                + ", "
                + String(metadata_end)
                + ")"
            )
        var footer = Footer.parse(bytes[footer_start:footer_end])

        return OrcFileTail(
            ps^,
            footer^,
            footer_start,
            footer_end,
            metadata_start,
            metadata_end,
        )

    @always_inline
    def num_stripes(self) -> Int:
        return self.footer.num_stripes()

    @always_inline
    def num_rows(self) -> Int:
        return self.footer.number_of_rows
