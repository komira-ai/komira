# =============================================================================
# test_avro_resolve_errors.mojo — resolution typed errors + edge cases
# (AvroResolutionError.*).
# =============================================================================
#
#   test_resolve_no_default_for_missing_field_raise — reader field absent in
#       writer, no default -> NO_DEFAULT_FOR_MISSING_FIELD.
#   test_resolve_incompatible_promotion_raise — double->int (narrowing) ->
#       INCOMPATIBLE_TYPE_PROMOTION.
#   test_resolve_fixed_size_mismatch_raise — writer fixed[8] -> reader fixed[4].
#   test_resolve_named_type_by_fullname — com.example.Foo fullname matching.
# =============================================================================

from std.testing import assert_true, assert_equal

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
# no default for a reader field absent in the writer -> raise.
# -----------------------------------------------------------------------------
def test_resolve_no_default_for_missing_field_raise() raises:
    var writer = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"id","type":"long"}]}'
    )
    var reader = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"id","type":"long"},'
        '{"name":"score","type":"double"}]}'  # no default
    )
    var buf = List[UInt8]()
    _make_header(writer, buf)
    var p = List[UInt8]()
    _enc_long(Int64(1), p)
    _append_block(buf, Int64(1), p)

    var raised = False
    try:
        var rb = read_avro_bytes_resolved(Span(buf), reader)
        _ = rb.num_rows()
    except e:
        raised = True
    assert_true(raised, "no-default missing field must raise")


# -----------------------------------------------------------------------------
# incompatible (narrowing) promotion double->int -> raise.
# -----------------------------------------------------------------------------
def test_resolve_incompatible_promotion_raise() raises:
    var writer = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"v","type":"double"}]}'
    )
    var reader = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"v","type":"int"}]}'  # narrowing — not a legal promotion
    )
    var buf = List[UInt8]()
    _make_header(writer, buf)
    var p = List[UInt8]()
    for _i in range(8):
        p.append(UInt8(0))
    _append_block(buf, Int64(1), p)

    var raised = False
    try:
        var rb = read_avro_bytes_resolved(Span(buf), reader)
        _ = rb.num_rows()
    except e:
        raised = True
    assert_true(raised, "double->int narrowing must raise")


# -----------------------------------------------------------------------------
# fixed size mismatch writer fixed[8] -> reader fixed[4] -> raise.
# -----------------------------------------------------------------------------
def test_resolve_fixed_size_mismatch_raise() raises:
    var writer = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"h","type":{"type":"fixed","name":"H","size":8}}]}'
    )
    var reader = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"h","type":{"type":"fixed","name":"H","size":4}}]}'
    )
    var buf = List[UInt8]()
    _make_header(writer, buf)
    var p = List[UInt8]()
    for _i in range(8):
        p.append(UInt8(0xAB))
    _append_block(buf, Int64(1), p)

    var raised = False
    try:
        var rb = read_avro_bytes_resolved(Span(buf), reader)
        _ = rb.num_rows()
    except e:
        raised = True
    assert_true(raised, "fixed[8]->fixed[4] size mismatch must raise")


# -----------------------------------------------------------------------------
# named type by fullname: writer record-level type name is the fully-qualified
# "com.example.Foo"; reader field renamed via type alias matching the writer's
# fullname. Exercises _named_types_match for enum types by fullname/alias.
# -----------------------------------------------------------------------------
def test_resolve_named_type_by_fullname() raises:
    # The writer enum has fullname "com.example.Color"; the reader enum is
    # named "Shade" but lists "com.example.Color" as an alias. The two named
    # types match by fullname-via-alias, so enum resolution proceeds.
    var writer = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"c","type":{"type":"enum","name":"com.example.Color",'
        '"symbols":["RED","BLUE"]}}]}'
    )
    var reader = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"c","type":{"type":"enum","name":"Shade",'
        '"aliases":["com.example.Color"],"symbols":["RED","BLUE"]}}]}'
    )
    var buf = List[UInt8]()
    _make_header(writer, buf)
    var p = List[UInt8]()
    _enc_long(Int64(1), p)  # BLUE
    _enc_long(Int64(0), p)  # RED
    _append_block(buf, Int64(2), p)

    var rb = read_avro_bytes_resolved(Span(buf), reader)
    var c = rb.column_at(0).as_string()
    assert_equal(c.get(0), String("BLUE"), "fullname row0 BLUE")
    assert_equal(c.get(1), String("RED"), "fullname row1 RED")


def main() raises:
    test_resolve_no_default_for_missing_field_raise()
    test_resolve_incompatible_promotion_raise()
    test_resolve_fixed_size_mismatch_raise()
    test_resolve_named_type_by_fullname()
    print("test_avro_resolve_errors: ALL PASS")
