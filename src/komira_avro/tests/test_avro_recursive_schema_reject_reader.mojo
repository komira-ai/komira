# =============================================================================
# test_avro_recursive_schema_reject_reader.mojo — recursive reject via reader.
# =============================================================================
#
# Acceptance:
#   test_recursive_schema_reject — a recursive schema raises THROUGH the
#   reader path (the schema parser has the visit-stack; this confirms it fires
#   when reached via read_avro_bytes → header.parse_schema).
# =============================================================================

from std.testing import assert_true

from komira_avro import read_avro_bytes, OCF_SYNC_LEN


def _enc_long(n: Int64, mut out: List[UInt8]):
    var zz = UInt64((n << 1) ^ (n >> 63))
    while True:
        var b = UInt8(zz & 0x7F)
        zz >>= 7
        if zz != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _str_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _enc_str(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _enc_bytes(b: List[UInt8], mut out: List[UInt8]):
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _sync() -> List[UInt8]:
    var s = List[UInt8]()
    for i in range(OCF_SYNC_LEN):
        s.append(UInt8(0xA0 + i))
    return s^


def _make_header(schema: String, mut out: List[UInt8]):
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(0x01)
    _enc_long(Int64(2), out)
    _enc_str(String("avro.schema"), out)
    _enc_bytes(_str_bytes(schema), out)
    _enc_str(String("avro.codec"), out)
    _enc_bytes(_str_bytes(String("null")), out)
    _enc_long(Int64(0), out)
    var s = _sync()
    for i in range(len(s)):
        out.append(s[i])


# A self-referential record (linked-list node) is recursive — reject FOREVER.
comptime _SCHEMA_RECURSIVE = String(
    '{"type":"record","name":"Node","fields":['
    '{"name":"value","type":"long"},'
    '{"name":"next","type":["null","Node"]}]}'
)


def test_recursive_schema_rejected_through_reader() raises:
    """A recursive schema embedded in an OCF header raises when read."""
    var buf = List[UInt8]()
    _make_header(_SCHEMA_RECURSIVE, buf)
    # No block needed — the schema parse (at read_avro_bytes start) raises
    # before any record is decoded.
    var raised = False
    try:
        var _rb = read_avro_bytes(Span(buf))
    except:
        raised = True
    assert_true(raised, "recursive Avro schema must raise through the reader")


def main() raises:
    test_recursive_schema_rejected_through_reader()
    print("test_avro_recursive_schema_reject_reader: ALL PASS")
