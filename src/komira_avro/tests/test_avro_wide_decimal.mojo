# =============================================================================
# test_avro_wide_decimal.mojo -- a plain read (`read_avro_bytes`, identity
# resolution) of a decimal whose two's-complement value is wider than 16
# bytes on the wire, and the plain-read enum refusal.
# =============================================================================
#
# What each case proves, and the defect it catches:
#   E1  a plain read of a record with an enum field is refused by name
#       ("UNSUPPORTED_FIELD_KIND: Avro kind 9"). This is the named refusal
#       docs/design/query_semantics_scans.md section 13.5 requires until enum
#       reads as DuckDB's ENUM (komira#1230); a STRING column would order by
#       text, where DuckDB orders an ENUM by symbol position. Mutant: a plain-
#       read enum arm that maps the index to the writer's symbol (the
#       issue's proposal): the plain read returns a STRING column, so the
#       refusal is gone and this case goes red.
#   W1  a decimal over fixed(17) whose leading byte is pure sign extension
#       reads as the Decimal128 value: 1, -1, and the largest and smallest
#       Decimal128 values (2^127 - 1 and -2^127). Before the fix every such
#       value was refused: "DECIMAL_TOO_WIDE: 17 bytes > 16".
#   W2  a decimal over bytes holding 18 bytes, two of them sign extension,
#       reads the same way (the bytes arm shares the decoder).
#   W3  a value that does not fit 16 bytes is still refused: a leading byte
#       that is not sign extension (0x01 then sixteen 0x00), and a leading
#       0x00 whose next byte has its top bit set (2^127, one past the
#       largest Decimal128), and its negative mirror (0xFF then 0x7F...).
#       Mutant: the sign taken from raw[0] instead of the first byte of the
#       low 16 (so a leading 0x00 never checks the next byte's top bit):
#       red, "W3 case 1 refused: (accepted)".
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType

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


def _enc_str(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _sync(mut out: List[UInt8]):
    for i in range(OCF_SYNC_LEN):
        out.append(UInt8(0xA0 + i))


def _ocf(schema: String, rows: Int, payload: List[UInt8]) -> List[UInt8]:
    """A null-codec OCF file holding one block of `rows` records."""
    var out = List[UInt8]()
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(0x01)
    _enc_long(Int64(2), out)
    _enc_str(String("avro.schema"), out)
    _enc_str(schema, out)
    _enc_str(String("avro.codec"), out)
    _enc_str(String("null"), out)
    _enc_long(Int64(0), out)
    _sync(out)
    _enc_long(Int64(rows), out)
    _enc_long(Int64(len(payload)), out)
    for i in range(len(payload)):
        out.append(payload[i])
    _sync(out)
    return out^


def _read_err(buf: List[UInt8]) -> String:
    try:
        _ = read_avro_bytes(Span(buf))
    except e:
        return String(e)
    return String("(accepted)")


def test_plain_enum_refused_by_name() raises:
    # E1: the issue's record, enum index 1.
    var schema = String(
        '{"type":"record","name":"R","fields":[{"name":"e","type":'
        '{"type":"enum","name":"E","symbols":["A","B"]}}]}'
    )
    var p = List[UInt8]()
    _enc_long(Int64(1), p)
    var msg = _read_err(_ocf(schema, 1, p))
    assert_true(
        "UNSUPPORTED_FIELD_KIND: Avro kind 9" in msg, "E1 refused: " + msg
    )


def _fixed17_schema() -> String:
    return String(
        '{"type":"record","name":"R","fields":[{"name":"d","type":'
        '{"type":"fixed","name":"D","size":17,"logicalType":"decimal",'
        '"precision":38,"scale":0}}]}'
    )


def _be(lead: UInt8, top: UInt8, rest: UInt8, n: Int) -> List[UInt8]:
    """`n` big-endian bytes: `lead`, then `top`, then n-2 bytes of `rest`."""
    var out = List[UInt8]()
    out.append(lead)
    out.append(top)
    for _ in range(n - 2):
        out.append(rest)
    return out^


def test_wide_fixed_decimal_fits() raises:
    # W1: 1, -1, 2^127 - 1, -2^127 over fixed(17).
    var p = List[UInt8]()
    for _ in range(16):
        p.append(0x00)
    p.append(0x01)  # 1 (the issue's value)
    p.extend(_be(0xFF, 0xFF, 0xFF, 17))  # -1
    p.extend(_be(0x00, 0x7F, 0xFF, 17))  # 2^127 - 1
    p.extend(_be(0xFF, 0x80, 0x00, 17))  # -2^127
    var buf = _ocf(_fixed17_schema(), 4, p)
    var rb = read_avro_bytes(Span(buf))
    ref col = rb.column_at(0)
    assert_equal(col.arrow_type.type_id, ArrowType.DECIMAL128.type_id, "W1 type")
    var d = col.as_decimal128()
    assert_equal(Int(d.get_low(0)), 1, "W1 1 low")
    assert_equal(Int(d.get_high(0)), 0, "W1 1 high")
    assert_equal(Int(d.get_low(1)), -1, "W1 -1 low")
    assert_equal(Int(d.get_high(1)), -1, "W1 -1 high")
    assert_equal(Int(d.get_low(2)), -1, "W1 max low")
    assert_equal(Int(d.get_high(2)), Int(Int64.MAX), "W1 max high")
    assert_equal(Int(d.get_low(3)), 0, "W1 min low")
    assert_equal(Int(d.get_high(3)), Int(Int64.MIN), "W1 min high")


def test_wide_bytes_decimal_fits() raises:
    # W2: decimal over bytes, 18 bytes holding -2 (0xFF.. 0xFE).
    var schema = String(
        '{"type":"record","name":"R","fields":[{"name":"d","type":'
        '{"type":"bytes","logicalType":"decimal","precision":38,"scale":2}}]}'
    )
    var v = _be(0xFF, 0xFF, 0xFF, 18)
    v[17] = 0xFE
    var p = List[UInt8]()
    _enc_long(Int64(len(v)), p)
    p.extend(v^)
    var rb = read_avro_bytes(Span(_ocf(schema, 1, p)))
    var d = rb.column_at(0).as_decimal128()
    assert_equal(Int(d.get_low(0)), -2, "W2 low")
    assert_equal(Int(d.get_high(0)), -1, "W2 high")


def test_wide_fixed_decimal_too_wide_refused() raises:
    # W3: each value needs more than 16 bytes.
    var cases = List[List[UInt8]]()
    cases.append(_be(0x01, 0x00, 0x00, 17))  # 2^128
    cases.append(_be(0x00, 0x80, 0x00, 17))  # 2^127
    cases.append(_be(0xFF, 0x7F, 0xFF, 17))  # -2^127 - 1
    for i in range(len(cases)):
        var msg = _read_err(_ocf(_fixed17_schema(), 1, cases[i]))
        assert_true(
            "DECIMAL_TOO_WIDE" in msg,
            "W3 case " + String(i) + " refused: " + msg,
        )


def main() raises:
    test_plain_enum_refused_by_name()
    test_wide_fixed_decimal_fits()
    test_wide_bytes_decimal_fits()
    test_wide_fixed_decimal_too_wide_refused()
    print("test_avro_wide_decimal: ALL PASS")
