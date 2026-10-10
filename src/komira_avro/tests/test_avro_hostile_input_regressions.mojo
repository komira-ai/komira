# =============================================================================
# test_avro_hostile_input_regressions.mojo -- regression tests for named past
# defects in the Avro reader's handling of untrusted bytes.
# =============================================================================
#
# These fixtures are hand-made. That is acceptable here only because each case
# is the regression test for ONE named past defect: a site that read out of
# bounds, wrapped a signed length, sized an allocation from a wire count, or
# looped forever on a crafted file before the guard now in the code. The
# defect is described above each case. General hostile-input coverage belongs
# to an established conformance or fuzz corpus, not to this file.
#
# Every case asserts that the reader REJECTED the input with the named error
# of the guard that owns the site. Several sites are guarded twice (a caller
# check and a callee check); pinning the owning guard's message means a
# mutant that deletes it goes red even when the second guard still catches the
# input, so the case says which guard is doing the work.
#
# ASSERT LEVEL. This file is built at the package's default assert level. The
# defects it guards were measured at ASSERT=none, where the stdlib's
# debug_asserts are compiled out; at a level where they remain, a deleted
# guard can surface as an assert abort rather than an out-of-bounds access.
# Either way the build goes red, which is what a regression test needs; what
# it cannot show at this level is the silent ASSERT=none behaviour itself.
#
# Mutants planted against this file, each alone; every one turned the build
# red. Where the site has a second guard (the two header cases, object count,
# fixed size, zstd) the input was still rejected and the case went red on the
# message; the others went red on an assert abort or a crash:
#   hdr_val_len_overflow     metadata-value overrun guard deleted
#   hdr_val_len_negative     metadata-value sign check deleted
#   blk_byte_count_overflow  block guard reverted to the additive form
#                            `pos + byte_count + OCF_SYNC_LEN > n`
#   blk_object_count_overflow  the decode_block reserve clamp deleted
#   payload_string_len_overflow  read_string_span guard reverted to the
#                            additive form `self.pos + n > len(self.data)`
#   logical_over_wrong_physical  the physical-type check made a no-op
#   fixed_size_overflow      the FIXED_SIZE_OUT_OF_RANGE check deleted
#   schema_json_depth        the JSON depth check deleted
#   zstd_content_size        the ZSTD_CONTENT_SIZE_OUT_OF_RANGE check deleted
#                            (libzstd then refuses: the buffer it is told
#                            about is the buffer that was allocated)
#   varint_negative_start    decode_zigzag_long's `pos < 0` entry check deleted
#   varint_legal_offsets     the entry check tightened to `pos >= len(bytes)`
#
# Public API only; no private symbols are imported.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import (
    AvroSchema,
    decode_ocf_header,
    decode_zigzag_long,
    read_avro_bytes,
    scan_ocf_blocks,
    OCF_SYNC_LEN,
)


# -----------------------------------------------------------------------------
# Avro binary encoders.
# -----------------------------------------------------------------------------


def _encode_long(n: Int64, mut out: List[UInt8]):
    """Append a well-formed zigzag varint Avro `long`."""
    var zz = UInt64((n << 1) ^ (n >> 63))
    while True:
        var b = UInt8(zz & 0x7F)
        zz >>= 7
        if zz != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _encode_varint_raw(acc_in: UInt64, mut out: List[UInt8]):
    """Append the raw base-128 encoding of `acc_in` (before zigzag).

    `acc = 0xFFFF_FFFF_FFFF_FFFE` decodes to Int64.MAX in exactly 10 bytes,
    whose last group sits at shift 63: a well-formed varint carrying a
    length that wraps any additive bounds check."""
    var acc = acc_in
    while acc >= 0x80:
        out.append(UInt8(acc & 0x7F) | 0x80)
        acc >>= 7
    out.append(UInt8(acc & 0x7F))


comptime _ACC_INT64_MAX: UInt64 = 0xFFFF_FFFF_FFFF_FFFE


def _encode_string(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _encode_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _sync_bytes(mut out: List[UInt8]):
    for i in range(OCF_SYNC_LEN):
        out.append(UInt8(0xA0 + i))


def _magic(mut out: List[UInt8]):
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(0x01)


def _make_header_codec(schema_json: String, codec: String) -> List[UInt8]:
    """A well-formed OCF header carrying `schema_json` and `avro.codec`."""
    var out = List[UInt8]()
    _magic(out)
    _encode_long(Int64(2), out)  # 2 metadata pairs
    _encode_string(String("avro.schema"), out)
    _encode_string(schema_json, out)
    _encode_string(String("avro.codec"), out)
    _encode_string(codec, out)
    _encode_long(Int64(0), out)  # map terminator
    _sync_bytes(out)
    return out^


def _make_header(schema_json: String) -> List[UInt8]:
    return _make_header_codec(schema_json, String("null"))


def _append_block(
    mut out: List[UInt8], object_count: Int64, payload: List[UInt8]
):
    """Append an OCF block: count, size, payload, sync."""
    _encode_long(object_count, out)
    _encode_long(Int64(len(payload)), out)
    for i in range(len(payload)):
        out.append(payload[i])
    _sync_bytes(out)


comptime _SCHEMA_LONG = (
    '{"type":"record","name":"R","fields":[{"name":"a","type":"long"}]}'
)
comptime _SCHEMA_STRING = (
    '{"type":"record","name":"R","fields":[{"name":"a","type":"string"}]}'
)


def _expect_named(msg: String, raised: Bool, name: String, token: String) raises:
    """`raised` must be True and `msg` must carry `token`."""
    assert_true(raised, name + ": expected an Error, got a successful read")
    assert_true(
        msg.find(token) >= 0,
        name + ": expected the error to name '" + token + "', got: " + msg,
    )
    print("  [ok] " + name + " -> " + msg)


def _read_error(buf: List[UInt8]) -> Tuple[Bool, String]:
    """Run `read_avro_bytes` over `buf`; (raised, message)."""
    try:
        var _rb = read_avro_bytes(Span(buf))
    except e:
        return (True, String(e))
    return (False, String(""))


# =============================================================================
# hdr_val_len_overflow -- ocf_header.mojo, metadata value length.
#
# The defect: the guard was `val_start + val_len > len(bytes)`. A 10-byte
# varint names Int64.MAX, the sum wraps negative, the guard passed, and the
# copy walked off the end of the file.
# =============================================================================


def case_hdr_val_len_overflow() raises:
    var buf = List[UInt8]()
    _magic(buf)
    _encode_long(Int64(1), buf)  # one metadata pair
    _encode_string(String("avro.schema"), buf)
    _encode_varint_raw(_ACC_INT64_MAX, buf)  # val_len = Int64.MAX
    for _i in range(8):
        buf.append(UInt8(0x7B))
    _sync_bytes(buf)
    var raised = False
    var msg = String("")
    try:
        var _h = decode_ocf_header(Span(buf))
    except e:
        raised = True
        msg = String(e)
    _expect_named(
        msg,
        raised,
        "hdr_val_len_overflow",
        "TRUNCATED_HEADER: metadata value for key 'avro.schema' declares"
        " length 9223372036854775807",
    )


# =============================================================================
# hdr_val_len_negative -- ocf_header.mojo, metadata value length sign.
#
# The defect: no sign check. A negative length passed the overrun guard and
# `pos = val_start + val_len` rewound the cursor. The fixture is tuned so the
# rewind lands back on the map's count (offset 4): magic [0, 4), count at 4,
# key at 5..17, val_len at 17, val_start 18, val_len -14 -> pos 4, so the
# metadata loop never ended.
# =============================================================================


def case_hdr_val_len_negative() raises:
    var buf = List[UInt8]()
    _magic(buf)  # 0..4
    _encode_long(Int64(1), buf)  # offset 4: one pair
    _encode_string(String("avro.schema"), buf)  # offsets 5..17
    _encode_long(Int64(-14), buf)  # offset 17 -> val_start 18
    for _i in range(8):
        buf.append(UInt8(0x7B))
    _sync_bytes(buf)
    var raised = False
    var msg = String("")
    try:
        var _h = decode_ocf_header(Span(buf))
    except e:
        raised = True
        msg = String(e)
    _expect_named(
        msg,
        raised,
        "hdr_val_len_negative",
        "TRUNCATED_HEADER: metadata value for key 'avro.schema' declares"
        " length -14",
    )


# =============================================================================
# blk_byte_count_overflow -- ocf_block_scan.mojo, block byte count.
#
# The defect: `pos + byte_count + OCF_SYNC_LEN > n` wrapped for a byte count
# near 2^63, the cursor went hugely negative, and the sync check read at an
# index of about -2^63.
# =============================================================================


def case_blk_byte_count_overflow() raises:
    var buf = _make_header(_SCHEMA_LONG)
    _encode_long(Int64(1), buf)  # object_count = 1
    _encode_varint_raw(_ACC_INT64_MAX, buf)  # byte_count = Int64.MAX
    for _i in range(8):
        buf.append(UInt8(0x00))
    _sync_bytes(buf)
    var raised = False
    var msg = String("")
    try:
        var _blocks = scan_ocf_blocks(Span(buf))
    except e:
        raised = True
        msg = String(e)
    _expect_named(
        msg,
        raised,
        "blk_byte_count_overflow",
        "TRUNCATED_BLOCK: block at offset",
    )


# =============================================================================
# blk_object_count_overflow -- block object count as an allocation size.
#
# The defect: the wire object count reached the accumulator's reserve, whose
# `length * 8` multiply wrapped 2^61 + 8 elements to a 64-byte buffer that the
# accumulator believed held 2^61 + 8, and every push wrote past it. The fix
# clamps the pre-reserve to the payload length (one record is at least one
# byte), so a lying count sizes nothing and the block fails as TRUNCATED when
# its 2,000,000 one-byte records run out. A ROW_COUNT_OUT_OF_RANGE here would
# mean the clamp is gone and only the accumulator ceiling stood in the way.
# =============================================================================


def case_blk_object_count_overflow() raises:
    var buf = _make_header(_SCHEMA_LONG)
    var payload = List[UInt8](capacity=2000000)
    for _i in range(2000000):
        payload.append(UInt8(0x00))  # zigzag long 0
    _append_block(buf, Int64(2305843009213693960), payload)  # 2^61 + 8
    var r = _read_error(buf)
    _expect_named(
        r[1],
        r[0],
        "blk_object_count_overflow",
        "AvroDecodeError.TRUNCATED: long varint overrun",
    )


# =============================================================================
# payload_string_len_overflow -- varint_decode_scalar.mojo, string length.
#
# The defect: `self.pos + n > len(self.data)` wrapped for n = Int64.MAX and a
# slice with a wrapped end reached a memcpy into the Arrow data buffer.
# =============================================================================


def case_payload_string_len_overflow() raises:
    var buf = _make_header(_SCHEMA_STRING)
    var payload = List[UInt8]()
    _encode_varint_raw(_ACC_INT64_MAX, payload)  # string length = Int64.MAX
    payload.append(UInt8(0x41))
    _append_block(buf, Int64(1), payload)
    var r = _read_error(buf)
    _expect_named(
        r[1],
        r[0],
        "payload_string_len_overflow",
        "AvroDecodeError.TRUNCATED: string payload overrun",
    )


# =============================================================================
# logical_over_wrong_physical -- a logicalType over an illegal physical type.
#
# The defect: `{"type":"long","logicalType":"decimal"}` built a DECIMAL128
# accumulator paired with a LONG wire read, and the read unwrapped an empty
# Optional. The arrow.* overrides already had this check; the standard
# logical types did not.
# =============================================================================


comptime _SCHEMA_DECIMAL_OVER_LONG = (
    '{"type":"record","name":"R","fields":[{"name":"a","type":'
    '{"type":"long","logicalType":"decimal","precision":10,"scale":2}}]}'
)


def case_logical_over_wrong_physical() raises:
    var buf = _make_header(_SCHEMA_DECIMAL_OVER_LONG)
    var payload = List[UInt8]()
    payload.append(UInt8(0x02))  # zigzag long 1
    _append_block(buf, Int64(1), payload)
    var r = _read_error(buf)
    _expect_named(
        r[1],
        r[0],
        "logical_over_wrong_physical",
        "AvroSchemaError.LOGICAL_TYPE_PHYSICAL_MISMATCH: logicalType 'decimal'",
    )


# =============================================================================
# fixed_size_overflow -- schema `fixed.size`, unbounded.
#
# The defect: `size` was parsed with no digit cap and flowed into the fixed
# read as a slice length, where the (then additive) payload guard wrapped.
# The leading `long` field moves the cursor to 1 so that `1 + (2^63 - 1)`
# wraps; with `fixed` first the old guard happened to catch it.
# =============================================================================


comptime _SCHEMA_FIXED_HUGE = (
    '{"type":"record","name":"R","fields":['
    '{"name":"lead","type":"long"},'
    '{"name":"a","type":{"type":"fixed","name":"F","size":9223372036854775807}}]}'
)


def case_fixed_size_overflow() raises:
    var buf = _make_header(_SCHEMA_FIXED_HUGE)
    var payload = List[UInt8]()
    payload.append(UInt8(0x02))  # lead: zigzag long 1 -> cursor at 1
    payload.append(UInt8(0x41))
    _append_block(buf, Int64(1), payload)
    var r = _read_error(buf)
    _expect_named(
        r[1],
        r[0],
        "fixed_size_overflow",
        "AvroSchemaError.FIXED_SIZE_OUT_OF_RANGE: fixed 'F'",
    )


# =============================================================================
# schema_json_depth -- unbounded JSON nesting in the schema.
#
# The defect: the schema JSON parser recursed once per nesting level with no
# counter, so a header of a few hundred thousand `[` exhausted the stack.
# =============================================================================


def case_schema_json_depth() raises:
    var deep = String("")
    for _i in range(200000):
        deep += "["
    var raised = False
    var msg = String("")
    try:
        var _s = AvroSchema.parse(deep)
    except e:
        raised = True
        msg = String(e)
    _expect_named(
        msg, raised, "schema_json_depth", "AvroSchemaError.SCHEMA_TOO_DEEP"
    )


# =============================================================================
# zstd_content_size -- zstd Frame_Content_Size sized dstCapacity but not the
# allocation.
#
# The defect: a frame declaring 2^63 bytes narrowed to a negative Int; the
# buffer was allocated at max(cap, 1) = 1 byte while libzstd was told the
# unclamped capacity, and wrote the frame's real output into one byte. This
# one is independent of the assert level: libzstd does the writing.
#
# The frame is assembled by hand (RAW blocks are literal copies):
#   magic 28 B5 2F FD; descriptor 0xC0 (8-byte FCS, not single-segment);
#   window 0x50 (windowLog 20, so 128 KiB blocks are legal);
#   FCS = 2^63 little-endian; 32 raw blocks of 128 KiB (4 MiB of output).
# =============================================================================


comptime _ZSTD_RAW_BLOCK_BYTES: Int = 131072
comptime _ZSTD_RAW_BLOCK_COUNT: Int = 32


def _hostile_zstd_frame() -> List[UInt8]:
    var f = List[UInt8]()
    f.append(0x28)
    f.append(0xB5)
    f.append(0x2F)
    f.append(0xFD)
    f.append(0xC0)  # frame header descriptor
    f.append(0x50)  # window descriptor: windowLog 20
    for _i in range(7):  # Frame_Content_Size = 2^63, little-endian
        f.append(UInt8(0x00))
    f.append(UInt8(0x80))
    for b in range(_ZSTD_RAW_BLOCK_COUNT):
        var last = 1 if b == _ZSTD_RAW_BLOCK_COUNT - 1 else 0
        # Block_Header = (Block_Size << 3) | (Block_Type << 1) | Last_Block,
        # 3 bytes little-endian; Block_Type 0 is Raw.
        var hdr = (_ZSTD_RAW_BLOCK_BYTES << 3) | last
        f.append(UInt8(hdr & 0xFF))
        f.append(UInt8((hdr >> 8) & 0xFF))
        f.append(UInt8((hdr >> 16) & 0xFF))
        for _i in range(_ZSTD_RAW_BLOCK_BYTES):
            f.append(UInt8(0x00))
    return f^


def case_zstd_content_size() raises:
    var buf = _make_header_codec(_SCHEMA_LONG, String("zstandard"))
    _append_block(buf, Int64(1), _hostile_zstd_frame())
    var r = _read_error(buf)
    _expect_named(
        r[1],
        r[0],
        "zstd_content_size",
        "AvroCodecError.ZSTD_CONTENT_SIZE_OUT_OF_RANGE",
    )


# =============================================================================
# varint_negative_start -- decode_zigzag_long's start offset.
#
# The defect: the standalone decoder (unlike AvroByteReader, it has no cursor
# invariant) tested only `p >= len(bytes)`, which is false for every negative
# p, and indexed bytes[p]. -2**40 is far enough below the buffer that the
# address is unmapped.
# =============================================================================


def case_varint_negative_start() raises:
    var buf = List[UInt8]()
    for _i in range(16):
        buf.append(UInt8(0x02))  # zigzag long 1
    var raised = False
    var msg = String("")
    try:
        var _d = decode_zigzag_long(Span(buf), -(1 << 40))
    except e:
        raised = True
        msg = String(e)
    _expect_named(
        msg,
        raised,
        "varint_negative_start",
        "AvroDecodeError.TRUNCATED: varint start offset -1099511627776 is"
        " outside the 16-byte payload",
    )


# =============================================================================
# varint_legal_offsets -- the over-validation control for the entry check.
#
# Not a regression test for the defect above: with the entry check deleted it
# still passes. It catches the opposite mistake, an entry check that refuses
# legal offsets or swallows the loop's own message: `pos == len(bytes)` is a
# truncation and must say "overrun", not "start offset".
# =============================================================================


def case_varint_legal_offsets() raises:
    var buf: List[UInt8] = [0x02, 0x04, 0x06]  # 1, 2, 3
    var d0 = decode_zigzag_long(Span(buf), 0)
    assert_equal(d0.value, Int64(1), "offset 0 decodes")
    assert_equal(d0.new_pos, 1, "offset 0 advances")
    var d1 = decode_zigzag_long(Span(buf), 1)
    assert_equal(d1.value, Int64(2), "offset 1 decodes")
    var d2 = decode_zigzag_long(Span(buf), 2)
    assert_equal(d2.value, Int64(3), "offset 2 decodes")
    assert_equal(d2.new_pos, 3, "offset 2 advances to the end")
    var raised = False
    var msg = String("")
    try:
        var _d = decode_zigzag_long(Span(buf), len(buf))
    except e:
        raised = True
        msg = String(e)
    _expect_named(
        msg,
        raised,
        "varint_legal_offsets",
        "AvroDecodeError.TRUNCATED: long varint overrun",
    )


def main() raises:
    case_hdr_val_len_overflow()
    case_hdr_val_len_negative()
    case_blk_byte_count_overflow()
    case_blk_object_count_overflow()
    case_payload_string_len_overflow()
    case_logical_over_wrong_physical()
    case_fixed_size_overflow()
    case_schema_json_depth()
    case_zstd_content_size()
    case_varint_negative_start()
    case_varint_legal_offsets()
    print("test_avro_hostile_input_regressions: ALL PASS")
