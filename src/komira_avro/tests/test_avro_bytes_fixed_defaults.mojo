# =============================================================================
# test_avro_bytes_fixed_defaults.mojo — a bytes or fixed field default is a
# JSON string read as Latin-1 (Avro 1.11.1, field default table): code points
# U+0000..U+00FF are the byte values; a union default applies to its first
# branch.
# =============================================================================
#
#   T1 bytes default "ÿ" (raw UTF-8 or the \u00ff escape) is one byte, FF, not C3 BF.
#   T2 fixed default: Latin-1 bytes; length must equal the fixed size; a
#      by-name reference to a fixed is resolved.
#   T3 refusals: a code point above U+00FF; a non-string default for bytes;
#      a fixed default of the wrong length (exact messages).
#   T4 unions: [bytes, null] reads the default as bytes; [string, bytes] reads
#      it as a string; ["null", bytes] keeps a null default.
#   T5 schema resolution: reader fields absent from the writer get the
#      Latin-1 bytes in the decoded batch.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import (
    AvroSchema,
    AVRO_DEFAULT_BYTES,
    AVRO_DEFAULT_NULL,
    AVRO_DEFAULT_STRING,
    OCF_SYNC_LEN,
    read_avro_bytes_resolved,
)


def _field_default_kind(json: String, field: Int) raises -> Int:
    var s = AvroSchema.parse(json)
    return s.node(s.root()).field_defaults[field].kind


def _field_default_bytes(json: String, field: Int) raises -> List[UInt8]:
    var s = AvroSchema.parse(json)
    var d = s.node(s.root()).field_defaults[field].copy()
    assert_equal(d.kind, AVRO_DEFAULT_BYTES, "default kind is BYTES")
    return d.bytes_val.copy()


def _one_field(ftype: String, default: String) -> String:
    return (
        '{"type":"record","name":"R","fields":[{"name":"f","type":'
        + ftype
        + ',"default":'
        + default
        + "}]}"
    )


def _refusal(json: String) -> String:
    try:
        _ = AvroSchema.parse(json)
    except e:
        return String(e)
    return String("<accepted>")


def test_bytes_default_is_latin1() raises:
    """T1."""
    var raw = _field_default_bytes(_one_field('"bytes"', '"ÿ"'), 0)
    assert_equal(len(raw), 1, "raw UTF-8 ÿ is one byte")
    assert_equal(Int(raw[0]), 0xFF)
    var esc = _field_default_bytes(
        _one_field('"bytes"', '"a\\u0000\\u0080\\u00ff"'), 0
    )
    assert_equal(len(esc), 4)
    assert_equal(Int(esc[0]), 0x61)
    assert_equal(Int(esc[1]), 0x00)
    assert_equal(Int(esc[2]), 0x80)
    assert_equal(Int(esc[3]), 0xFF)
    assert_equal(len(_field_default_bytes(_one_field('"bytes"', '""'), 0)), 0)


def test_fixed_default() raises:
    """T2."""
    var fx = _field_default_bytes(
        _one_field(
            '{"type":"fixed","name":"F2","size":2}', '"\\u00ff\\u0001"'
        ),
        0,
    )
    assert_equal(len(fx), 2)
    assert_equal(Int(fx[0]), 0xFF)
    assert_equal(Int(fx[1]), 0x01)
    # Field g names the fixed defined by field f.
    var by_ref = _field_default_bytes(
        '{"type":"record","name":"R","fields":['
        '{"name":"f","type":{"type":"fixed","name":"F1","size":1}},'
        '{"name":"g","type":"F1","default":"é"}]}',
        1,
    )
    assert_equal(len(by_ref), 1)
    assert_equal(Int(by_ref[0]), 0xE9)


def test_refusals() raises:
    """T3."""
    assert_equal(
        _refusal(_one_field('"bytes"', '"a\\u0100"')),
        "AvroSchemaError.INVALID_DEFAULT: field 'f' default contains U+0100;"
        " a bytes or fixed default holds only code points U+0000..U+00FF",
    )
    assert_equal(
        _refusal(_one_field('"bytes"', '"\\ud83d\\ude00"')),
        "AvroSchemaError.INVALID_DEFAULT: field 'f' default contains U+1F600;"
        " a bytes or fixed default holds only code points U+0000..U+00FF",
    )
    assert_equal(
        _refusal(
            _one_field('{"type":"fixed","name":"F","size":2}', '"€€"')
        ),
        "AvroSchemaError.INVALID_DEFAULT: field 'f' default contains U+20AC;"
        " a bytes or fixed default holds only code points U+0000..U+00FF",
    )
    assert_equal(
        _refusal(_one_field('"bytes"', "5")),
        "AvroSchemaError.INVALID_DEFAULT: field 'f' default for bytes is not"
        " a JSON string",
    )
    assert_equal(
        _refusal(_one_field('{"type":"fixed","name":"F","size":2}', "null")),
        "AvroSchemaError.INVALID_DEFAULT: field 'f' default for fixed is not"
        " a JSON string",
    )
    assert_equal(
        _refusal(
            _one_field('{"type":"fixed","name":"F","size":2}', '"ÿ"')
        ),
        "AvroSchemaError.INVALID_DEFAULT: field 'f' default is 1 bytes;"
        " fixed 'F' has size 2",
    )
    assert_equal(
        _refusal(_one_field('{"type":"fixed","name":"F","size":2}', '"abc"')),
        "AvroSchemaError.INVALID_DEFAULT: field 'f' default is 3 bytes;"
        " fixed 'F' has size 2",
    )


def test_union_first_branch() raises:
    """T4."""
    var ub = _field_default_bytes(_one_field('["bytes","null"]', '"ÿ"'), 0)
    assert_equal(len(ub), 1)
    assert_equal(Int(ub[0]), 0xFF)
    var uf = _field_default_bytes(
        _one_field('[{"type":"fixed","name":"F","size":1},"null"]', '"ÿ"'),
        0,
    )
    assert_equal(Int(uf[0]), 0xFF)
    assert_equal(
        _field_default_kind(_one_field('["string","bytes"]', '"ÿ"'), 0),
        AVRO_DEFAULT_STRING,
    )
    assert_equal(
        _field_default_kind(_one_field('["null","bytes"]', "null"), 0),
        AVRO_DEFAULT_NULL,
    )
    assert_equal(
        _refusal(_one_field('["bytes","null"]', "null")),
        "AvroSchemaError.INVALID_DEFAULT: field 'f' default for bytes is not"
        " a JSON string",
    )


# ---- OCF fixture helpers (decoder-inverse, as in the resolution tests). ----


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


def _ocf(writer_schema: String, payload: List[UInt8], rows: Int) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(0x01)
    _enc_long(Int64(2), out)
    _enc_str(String("avro.schema"), out)
    _enc_str(writer_schema, out)
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


def test_resolution_applies_latin1_default() raises:
    """T5: writer has only `id`; the reader adds bytes, fixed and
    union[bytes, null] fields with defaults."""
    var writer = String(
        '{"type":"record","name":"R","fields":[{"name":"id","type":"long"}]}'
    )
    var reader = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"id","type":"long"},'
        '{"name":"b","type":"bytes","default":"ÿ"},'
        '{"name":"x","type":{"type":"fixed","name":"F2","size":2},'
        '"default":"\\u00e9\\u0000"},'
        '{"name":"u","type":["bytes","null"],"default":"\\u0080"}]}'
    )
    var p = List[UInt8]()
    _enc_long(Int64(5), p)
    _enc_long(Int64(6), p)
    var buf = _ocf(writer, p, 2)
    var rb = read_avro_bytes_resolved(Span(buf), reader)
    assert_equal(rb.num_rows(), 2)
    assert_equal(rb.num_columns(), 4)
    for r in range(2):
        ref bcol = rb.column_at(1)
        var b = bcol.as_binary().get(r)
        assert_equal(len(b), 1, "b is one byte")
        assert_equal(Int(b[0]), 0xFF, "b == FF")
        ref xcol = rb.column_at(2)
        var x = xcol.as_binary().get(r)
        assert_equal(len(x), 2, "x is two bytes")
        assert_equal(Int(x[0]), 0xE9, "x[0] == E9")
        assert_equal(Int(x[1]), 0x00, "x[1] == 00")
        ref ucol = rb.column_at(3)
        var ua = ucol.as_binary()
        assert_true(not ua.is_null(r), "u is not null")
        var u = ua.get(r)
        assert_equal(len(u), 1, "u is one byte")
        assert_equal(Int(u[0]), 0x80, "u == 80")


def main() raises:
    test_bytes_default_is_latin1()
    test_fixed_default()
    test_refusals()
    test_union_first_branch()
    test_resolution_applies_latin1_default()
    print("test_avro_bytes_fixed_defaults: ALL PASS")
