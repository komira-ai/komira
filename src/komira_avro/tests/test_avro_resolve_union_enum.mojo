# =============================================================================
# test_avro_resolve_union_enum.mojo — union + enum resolution
# (the union and enum rules).
# =============================================================================
#
# Union resolution: writer-union→reader-non-union, writer-non-union→reader-union
# (nullable shapes). Enum resolution: symbol resolve, enum default fallback,
# symbol-order irrelevance. Fixtures hand-emitted.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import read_avro_bytes_resolved, OCF_SYNC_LEN


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


def _append_block(mut out: List[UInt8], object_count: Int64, payload: List[UInt8]):
    _enc_long(object_count, out)
    _enc_long(Int64(len(payload)), out)
    for i in range(len(payload)):
        out.append(payload[i])
    var s = _sync()
    for i in range(len(s)):
        out.append(s[i])


# -----------------------------------------------------------------------------
# writer-union → reader-non-union. Writer field is union[null,long]; reader
# expects a plain long. Records where the writer wrote null surface as a null
# row in the (still-nullable) output column.
# -----------------------------------------------------------------------------
def test_resolve_union_to_nonunion() raises:
    var writer = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"v","type":["null","long"]}]}'
    )
    var reader = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"v","type":"long"}]}'
    )
    var buf = List[UInt8]()
    _make_header(writer, buf)
    var p = List[UInt8]()
    _enc_long(Int64(1), p)   # row 0: tag 1 -> long branch
    _enc_long(Int64(50), p)
    _enc_long(Int64(0), p)   # row 1: tag 0 -> null
    _enc_long(Int64(1), p)   # row 2: tag 1 -> long branch
    _enc_long(Int64(-9), p)
    _append_block(buf, Int64(3), p)

    var rb = read_avro_bytes_resolved(Span(buf), reader)
    assert_equal(rb.num_rows(), 3, "union->nonunion 3 rows")
    var c = rb.column_at(0).as_primitive[DType.int64]()
    assert_true(not c.is_null(0), "row0 valid")
    assert_equal(Int(c.get(0)), 50, "row0 == 50")
    assert_true(c.is_null(1), "row1 null")
    assert_true(not c.is_null(2), "row2 valid")
    assert_equal(Int(c.get(2)), -9, "row2 == -9")


# -----------------------------------------------------------------------------
# writer-non-union → reader-union. Writer field is a plain long; reader expects
# union[null,long]. The writer always wrote a value -> all rows non-null.
# -----------------------------------------------------------------------------
def test_resolve_nonunion_to_union() raises:
    var writer = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"v","type":"long"}]}'
    )
    var reader = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"v","type":["null","long"]}]}'
    )
    var buf = List[UInt8]()
    _make_header(writer, buf)
    var p = List[UInt8]()
    _enc_long(Int64(7), p)
    _enc_long(Int64(8), p)
    _append_block(buf, Int64(2), p)

    var rb = read_avro_bytes_resolved(Span(buf), reader)
    assert_equal(rb.num_rows(), 2, "nonunion->union 2 rows")
    var c = rb.column_at(0).as_primitive[DType.int64]()
    assert_true(not c.is_null(0), "row0 valid")
    assert_equal(Int(c.get(0)), 7, "row0 == 7")
    assert_equal(Int(c.get(1)), 8, "row1 == 8")


# -----------------------------------------------------------------------------
# enum symbol-resolve. Writer + reader enums share the same symbol set; the
# writer encodes an index, the reader resolves it to a symbol string.
# -----------------------------------------------------------------------------
def test_resolve_enum_symbol() raises:
    var writer = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"color","type":{"type":"enum","name":"Color",'
        '"symbols":["RED","GREEN","BLUE"]}}]}'
    )
    var reader = writer  # identical enum
    var buf = List[UInt8]()
    _make_header(writer, buf)
    var p = List[UInt8]()
    _enc_long(Int64(0), p)  # RED
    _enc_long(Int64(2), p)  # BLUE
    _enc_long(Int64(1), p)  # GREEN
    _append_block(buf, Int64(3), p)

    var rb = read_avro_bytes_resolved(Span(buf), reader)
    var c = rb.column_at(0).as_string()
    assert_equal(c.get(0), String("RED"), "enum row0")
    assert_equal(c.get(1), String("BLUE"), "enum row1")
    assert_equal(c.get(2), String("GREEN"), "enum row2")


# -----------------------------------------------------------------------------
# enum default. Writer has a symbol "PURPLE" the reader lacks; reader declares a
# default "UNKNOWN". The unresolvable symbol falls back to the default.
# -----------------------------------------------------------------------------
def test_resolve_enum_default() raises:
    var writer = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"color","type":{"type":"enum","name":"Color",'
        '"symbols":["RED","PURPLE"]}}]}'
    )
    var reader = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"color","type":{"type":"enum","name":"Color",'
        '"symbols":["RED","GREEN"],"default":"UNKNOWN"}}]}'
    )
    var buf = List[UInt8]()
    _make_header(writer, buf)
    var p = List[UInt8]()
    _enc_long(Int64(0), p)  # RED -> resolvable
    _enc_long(Int64(1), p)  # PURPLE -> not in reader -> default UNKNOWN
    _append_block(buf, Int64(2), p)

    var rb = read_avro_bytes_resolved(Span(buf), reader)
    var c = rb.column_at(0).as_string()
    assert_equal(c.get(0), String("RED"), "enum-default row0 RED")
    assert_equal(c.get(1), String("UNKNOWN"), "enum-default row1 UNKNOWN")


# -----------------------------------------------------------------------------
# enum symbol-order irrelevant. Writer + reader share the same symbol *set* but
# in a different order; resolution is by symbol STRING, not by index.
# -----------------------------------------------------------------------------
def test_resolve_enum_symbol_order_irrelevant() raises:
    var writer = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"color","type":{"type":"enum","name":"Color",'
        '"symbols":["RED","GREEN","BLUE"]}}]}'
    )
    var reader = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"color","type":{"type":"enum","name":"Color",'
        '"symbols":["BLUE","GREEN","RED"]}}]}'
    )
    var buf = List[UInt8]()
    _make_header(writer, buf)
    var p = List[UInt8]()
    _enc_long(Int64(0), p)  # writer index 0 == "RED"
    _enc_long(Int64(2), p)  # writer index 2 == "BLUE"
    _append_block(buf, Int64(2), p)

    var rb = read_avro_bytes_resolved(Span(buf), reader)
    var c = rb.column_at(0).as_string()
    # Resolution must use the WRITER's symbol at each index, mapped by string.
    assert_equal(c.get(0), String("RED"), "order-irrelevant row0 RED")
    assert_equal(c.get(1), String("BLUE"), "order-irrelevant row1 BLUE")


def main() raises:
    test_resolve_union_to_nonunion()
    test_resolve_nonunion_to_union()
    test_resolve_enum_symbol()
    test_resolve_enum_default()
    test_resolve_enum_symbol_order_irrelevant()
    print("test_avro_resolve_union_enum: ALL PASS")
