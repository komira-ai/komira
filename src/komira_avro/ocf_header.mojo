# =============================================================================
# ocf_header.mojo — Avro Object Container File (OCF) header decode.
# =============================================================================
#
# OCF header byte layout (Avro spec "Object Container Files"):
#
#   header := "O" "b" "j" 0x01                 // 4 bytes magic + version
#             file_metadata                    // map<string,bytes> Avro binary
#                 "avro.schema" -> <JSON>
#                 "avro.codec"  -> <"null"|"deflate"|"snappy"|"bzip2"|"xz"|"zstandard">
#                 ... user metadata ...
#             sync_marker                      // 16 random bytes, fixed per file
#
# This module:
#   1. Validates the 4-byte magic `Obj\x01`.
#   2. Decodes the Avro-binary metadata map (key:string -> value:bytes).
#   3. Extracts `avro.schema` (JSON) + `avro.codec` (wire-name string).
#   4. Dispatches the codec on the Avro spec WIRE-NAME string
#      (e.g. "zstandard", NOT "zstd"). This module only EXTRACTS + validates
#      the codec name; decompression is `avro_codec.mojo`.
#   5. Reads the 16-byte sync marker for block-boundary validation.
#
# Encapsulation: no UnsafePointer crosses any module boundary. The header is
# decoded out of a borrowed `Span[UInt8]` view of the file bytes; the result
# is an owned OcfHeader value (owned String schema + InlineArray sync marker).
# =============================================================================

from .avro_schema import AvroSchema


# =============================================================================
# Codec tags — dispatched on the Avro spec WIRE-NAME string.
# =============================================================================
#
# The struct names (AvroOcfZstd) do NOT equal the wire names ("zstandard").
# Reader codec dispatch is byte-equality on the spec string.

comptime AVRO_CODEC_NULL: Int = 0
comptime AVRO_CODEC_DEFLATE: Int = 1
comptime AVRO_CODEC_SNAPPY: Int = 2
comptime AVRO_CODEC_BZIP2: Int = 3
comptime AVRO_CODEC_XZ: Int = 4
comptime AVRO_CODEC_ZSTANDARD: Int = 5


@always_inline
def codec_tag_from_wire_name(wire_name: String) raises -> Int:
    """Map an Avro `avro.codec` wire-name string to its codec tag.

    Dispatch is byte-equality on the Avro 1.11.1 spec wire-name.
    Note `"zstandard"` is the spec name — NOT the `"zstd"` shorthand.
    """
    if wire_name == "null":
        return AVRO_CODEC_NULL
    elif wire_name == "deflate":
        return AVRO_CODEC_DEFLATE
    elif wire_name == "snappy":
        return AVRO_CODEC_SNAPPY
    elif wire_name == "bzip2":
        return AVRO_CODEC_BZIP2
    elif wire_name == "xz":
        return AVRO_CODEC_XZ
    elif wire_name == "zstandard":
        return AVRO_CODEC_ZSTANDARD
    raise Error(
        String("AvroOcfError.UNKNOWN_CODEC: '") + wire_name
        + "' (expected one of null/deflate/snappy/bzip2/xz/zstandard)"
    )


@always_inline
def _write_codec_wire_name[W: Writer](mut writer: W, tag: Int):
    """WRITE what `codec_wire_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, and a shared
    library can bind such a pair CROSSED, returning the wrong string or
    crashing its host."""
    if tag == AVRO_CODEC_NULL:
        writer.write(String("null"))
        return
    elif tag == AVRO_CODEC_DEFLATE:
        writer.write(String("deflate"))
        return
    elif tag == AVRO_CODEC_SNAPPY:
        writer.write(String("snappy"))
        return
    elif tag == AVRO_CODEC_BZIP2:
        writer.write(String("bzip2"))
        return
    elif tag == AVRO_CODEC_XZ:
        writer.write(String("xz"))
        return
    elif tag == AVRO_CODEC_ZSTANDARD:
        writer.write(String("zstandard"))
        return
    writer.write(String("unknown"))
    return


@always_inline
def codec_wire_name(tag: Int) -> String:
    """Inverse of codec_tag_from_wire_name: tag -> Avro spec wire name."""
    var out = String()
    _write_codec_wire_name(out, tag)
    return out^


comptime OCF_MAGIC_LEN: Int = 4
comptime OCF_SYNC_LEN: Int = 16


# =============================================================================
# OcfHeader — decoded header value.
# =============================================================================

@fieldwise_init
struct OcfHeader(Copyable, Movable):
    """Decoded OCF header: schema JSON, codec tag, 16-byte sync marker, and
    the byte offset where the first block begins (header end)."""

    var schema_json: String
    var codec_tag: Int
    var sync_marker: Array[UInt8, OCF_SYNC_LEN]
    # Byte offset of the first block (== end of header). Block scan starts here.
    var header_len: Int

    def codec_name(self) -> String:
        return codec_wire_name(self.codec_tag)

    def parse_schema(self) raises -> AvroSchema:
        """Parse the embedded `avro.schema` JSON into an AvroSchema."""
        return AvroSchema.parse(self.schema_json)


# =============================================================================
# Header decode.
# =============================================================================

def decode_ocf_header(bytes: Span[UInt8, _]) raises -> OcfHeader:
    """Decode the OCF header from the start of a file byte view.

    Validates magic, decodes the Avro-binary metadata map, extracts
    `avro.schema` + `avro.codec`, reads the 16-byte sync marker, and reports
    the header length (== first-block offset).
    """
    if len(bytes) < OCF_MAGIC_LEN + OCF_SYNC_LEN:
        raise Error("AvroOcfError.TRUNCATED_HEADER: file too short for header")

    # ---- Magic: "Obj" 0x01 ----
    if (
        bytes[0] != UInt8(ord("O"))
        or bytes[1] != UInt8(ord("b"))
        or bytes[2] != UInt8(ord("j"))
        or bytes[3] != 0x01
    ):
        raise Error("AvroOcfError.BAD_MAGIC: expected 'Obj' 0x01")

    var pos = OCF_MAGIC_LEN

    # ---- Metadata map: Avro map<string, bytes> binary encoding. ----
    #
    # An Avro map is a sequence of blocks. Each block: a `long` count. If
    # count > 0, `count` key/value pairs follow. If count < 0, abs(count) pairs
    # follow preceded by a `long` byte-size (the block-size optimization). A
    # zero-count block terminates the map.
    var schema_json = String("")
    var codec_name = String("null")  # spec default when avro.codec is absent
    var saw_codec = False

    while True:
        var count_read = _read_long(bytes, pos)
        var count = count_read.value
        pos = count_read.new_pos
        if count == 0:
            break
        if count < 0:
            # Negative count: a byte-size long follows, then abs(count) pairs.
            count = -count
            # UNTRUSTED INPUT: `-Int64.MIN` is still Int64.MIN. Left unchecked
            # the negated count stays negative, `range()` yields nothing, and
            # the map loop re-enters without having consumed a pair.
            if count < 0:
                raise Error(
                    "AvroOcfError.MALFORMED_HEADER: metadata map pair count"
                    " out of range"
                )
            var sz_read = _read_long(bytes, pos)
            pos = sz_read.new_pos  # consume (and ignore) the block byte-size
        for _i in range(Int(count)):
            # key: Avro string (long length + UTF-8 bytes).
            var key_read = _read_string(bytes, pos)
            var key = key_read.value
            pos = key_read.new_pos
            # value: Avro bytes (long length + raw bytes).
            var val_len_read = _read_long(bytes, pos)
            var val_len = Int(val_len_read.value)
            pos = val_len_read.new_pos
            var val_start = pos
            # UNTRUSTED INPUT. `val_len` is a zigzag
            # varint read straight out of the file header and reaches Int64.MAX
            # in 10 well-formed bytes. The naive guard
            # `val_start + val_len > len(bytes)` has two defects:
            #
            #   (a) NO SIGN CHECK. A negative val_len passes, and
            #       `pos = val_start + val_len` then REWINDS the cursor — a
            #       crafted header can make the rewind exactly periodic and
            #       this loop never terminates.
            #   (b) SIGNED OVERFLOW. `val_start + Int64.MAX` wraps negative, so
            #       the comparison passes and the oversized length reaches
            #       `_bytes_to_string`, which walks off the end of the mapped
            #       file. At ASSERT=safe the stdlib Span check aborts; at
            #       ASSERT=none that is an unbounded out-of-bounds read whose
            #       bytes land in `schema_json` and can surface in error text.
            #
            # Written subtraction-first so it cannot overflow: `val_start` is
            # bounded by `len(bytes)` (every `_read_long` leaves the cursor at
            # or before the end), so `len(bytes) - val_start` is >= 0.
            if val_len < 0 or val_len > len(bytes) - val_start:
                raise Error(
                    String(
                        "AvroOcfError.TRUNCATED_HEADER: metadata value for key"
                        " '"
                    )
                    + key
                    + "' declares length "
                    + String(val_len)
                    + " but only "
                    + String(len(bytes) - val_start)
                    + " header bytes remain"
                )
            if key == "avro.schema":
                schema_json = _bytes_to_string(bytes, val_start, val_len)
            elif key == "avro.codec":
                codec_name = _bytes_to_string(bytes, val_start, val_len)
                saw_codec = True
            pos = val_start + val_len

    if schema_json.byte_length() == 0:
        raise Error("AvroOcfError.MISSING_SCHEMA: header has no 'avro.schema'")

    var codec_tag = codec_tag_from_wire_name(codec_name) if saw_codec else AVRO_CODEC_NULL

    # ---- Sync marker: 16 raw bytes. ----
    if pos + OCF_SYNC_LEN > len(bytes):
        raise Error("AvroOcfError.TRUNCATED_HEADER: missing sync marker")
    var sync = Array[UInt8, OCF_SYNC_LEN](fill=0)
    for i in range(OCF_SYNC_LEN):
        sync[i] = bytes[pos + i]
    pos += OCF_SYNC_LEN

    return OcfHeader(schema_json^, codec_tag, sync^, pos)


# =============================================================================
# Avro binary primitive readers (header-local; `varint_decode_scalar.mojo`
# has the canonical set).
# =============================================================================
#
# Avro `long`/`int` are zigzag-encoded variable-length integers. The header
# only needs `long` (metadata counts + string/bytes lengths) and string. We
# return small result structs (value + new_pos) so position threading stays
# explicit and pointer-free. (Heterogeneous tuple returns are awkward in
# Mojo — the named-result struct is the idiomatic shape.)


@fieldwise_init
struct VarintRead(Copyable, Movable):
    """Result of decoding a zigzag varint: the value + the position after it."""
    var value: Int64
    var new_pos: Int


@fieldwise_init
struct StringRead(Copyable, Movable):
    """Result of decoding an Avro string: the value + position after it."""
    var value: String
    var new_pos: Int


def _read_long(bytes: Span[UInt8, _], pos: Int) raises -> VarintRead:
    """Decode a zigzag varint Avro `long` starting at `pos`."""
    var p = pos
    var shift: UInt64 = 0
    var acc: UInt64 = 0
    while True:
        if p >= len(bytes):
            raise Error("AvroOcfError.TRUNCATED_HEADER: varint overrun")
        var b = bytes[p]
        p += 1
        acc |= (UInt64(b & 0x7F) << shift)
        if (b & 0x80) == 0:
            break
        shift += 7
        if shift >= 64:
            raise Error("AvroOcfError.MALFORMED_VARINT: long > 10 bytes")
    # Zigzag decode: (n >>> 1) ^ -(n & 1).
    var decoded = Int64((acc >> 1) ^ (~(acc & 1) + 1))
    return VarintRead(decoded, p)


def _read_string(bytes: Span[UInt8, _], pos: Int) raises -> StringRead:
    """Decode an Avro `string`: a `long` byte-length followed by UTF-8 bytes."""
    var len_read = _read_long(bytes, pos)
    var n = Int(len_read.value)
    var start = len_read.new_pos
    # Subtraction-first: `start + n` overflows for a wire-supplied n near
    # Int64.MAX (see the metadata-value guard in decode_ocf_header).
    if n < 0 or n > len(bytes) - start:
        raise Error(
            String("AvroOcfError.TRUNCATED_HEADER: string declares length ")
            + String(n)
            + " but only "
            + String(len(bytes) - start)
            + " header bytes remain"
        )
    var s = _bytes_to_string(bytes, start, n)
    return StringRead(s^, start + n)


def _bytes_to_string(bytes: Span[UInt8, _], start: Int, n: Int) raises -> String:
    """Copy `n` bytes starting at `start` into an owned String.

    UNTRUSTED INPUT: this function checks the range itself rather than
    trusting whichever caller computed `n` — a caller's guard can be defeated
    by signed overflow, and `for i in range(n)` would then index
    `bytes[start + i]` past the end of the mapped file, which at ASSERT=none is
    an unbounded out-of-bounds read (the bytes are accumulated into a String
    that reaches `schema_json` and error text).

    The range is re-validated here rather than only at the call sites: this is
    header-parse code that runs at most a handful of times per file, so an
    owned bounds contract costs nothing and removes the ability of a future
    caller to reintroduce the hole.
    """
    if start < 0 or n < 0 or n > len(bytes) - start:
        raise Error(
            String("AvroOcfError.TRUNCATED_HEADER: byte range [")
            + String(start)
            + ", "
            + String(start)
            + "+"
            + String(n)
            + ") is not contained in the "
            + String(len(bytes))
            + "-byte header view"
        )
    var out = String("")
    for i in range(n):
        out += String(chr(Int(bytes[start + i])))
    return out^
