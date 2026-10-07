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
#   T4 unions: the default is read as the first branch it matches. [bytes,
#      null] reads a string default as bytes and keeps a null default;
#      [null, bytes] reads a string default as bytes; [string, bytes] reads it
#      as a string; a by-name fixed inside a union is resolved and its length
#      checked; a default matching no branch is checked against the first.
#   T5 schema resolution: reader fields absent from the writer get the
#      Latin-1 bytes in the decoded batch, for bytes, fixed, [bytes, null],
#      [null, bytes] and [fixed, null] fields.
#   T6 a writer schema with [bytes, null] and default null still opens.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import (
    AvroSchema,
    read_avro_bytes,
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
    # Default null matches the second branch.
    assert_equal(
        _field_default_kind(_one_field('["bytes","null"]', "null"), 0),
        AVRO_DEFAULT_NULL,
    )
    # A string default skips the null branch and is read as bytes.
    var nb = _field_default_bytes(_one_field('["null","bytes"]', '"ÿ"'), 0)
    assert_equal(len(nb), 1, "[null,bytes] default is one byte")
    assert_equal(Int(nb[0]), 0xFF)
    # A default matching no branch is checked against the first branch.
    assert_equal(
        _refusal(_one_field('["bytes","null"]', "5")),
        "AvroSchemaError.INVALID_DEFAULT: field 'f' default for bytes is not"
        " a JSON string",
    )
    # Field g's union names the fixed defined by field f.
    var rf = _field_default_bytes(
        '{"type":"record","name":"R","fields":['
        '{"name":"f","type":{"type":"fixed","name":"F1","size":1}},'
        '{"name":"g","type":["F1","null"],"default":"ÿ"}]}',
        1,
    )
    assert_equal(len(rf), 1, "[F1,null] default is one byte")
    assert_equal(Int(rf[0]), 0xFF)
    var rn = _field_default_bytes(
        '{"type":"record","name":"R","fields":['
        '{"name":"f","type":{"type":"fixed","name":"F1","size":1}},'
        '{"name":"g","type":["null","F1"],"default":"ÿ"}]}',
        1,
    )
    assert_equal(len(rn), 1, "[null,F1] default is one byte")
    assert_equal(Int(rn[0]), 0xFF)
    assert_equal(
        _refusal(
            '{"type":"record","name":"R","fields":['
            '{"name":"f","type":{"type":"fixed","name":"F2","size":2}},'
            '{"name":"g","type":["F2","null"],"default":"ÿ"}]}'
        ),
        "AvroSchemaError.INVALID_DEFAULT: field 'g' default is 1 bytes;"
        " fixed 'F2' has size 2",
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
    """T5: writer has only `id`; the reader adds bytes, fixed,
    union[bytes, null], union[null, bytes] and union[fixed, null] fields
    with defaults."""
    var writer = String(
        '{"type":"record","name":"R","fields":[{"name":"id","type":"long"}]}'
    )
    var reader = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"id","type":"long"},'
        '{"name":"b","type":"bytes","default":"ÿ"},'
        '{"name":"x","type":{"type":"fixed","name":"F2","size":2},'
        '"default":"\\u00e9\\u0000"},'
        '{"name":"u","type":["bytes","null"],"default":"\\u0080"},'
        '{"name":"n","type":["null","bytes"],"default":"\\u00fe"},'
        '{"name":"y","type":[{"type":"fixed","name":"F3","size":2},"null"],'
        '"default":"\\u0001\\u00ff"}]}'
    )
    var p = List[UInt8]()
    _enc_long(Int64(5), p)
    _enc_long(Int64(6), p)
    var buf = _ocf(writer, p, 2)
    var rb = read_avro_bytes_resolved(Span(buf), reader)
    assert_equal(rb.num_rows(), 2)
    assert_equal(rb.num_columns(), 6)
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
        ref ncol = rb.column_at(4)
        var na = ncol.as_binary()
        assert_true(not na.is_null(r), "n is not null")
        var nv = na.get(r)
        assert_equal(len(nv), 1, "n is one byte")
        assert_equal(Int(nv[0]), 0xFE, "n == FE")
        ref ycol = rb.column_at(5)
        var ya = ycol.as_binary()
        assert_true(not ya.is_null(r), "y is not null")
        var yv = ya.get(r)
        assert_equal(len(yv), 2, "y is two bytes")
        assert_equal(Int(yv[0]), 0x01, "y[0] == 01")
        assert_equal(Int(yv[1]), 0xFF, "y[1] == FF")


def test_writer_union_null_default_opens() raises:
    """T6: a writer schema whose [bytes, null] field defaults to null (a
    default matching the second branch) is read without resolution."""
    var writer = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"w","type":["bytes","null"],"default":null}]}'
    )
    var p = List[UInt8]()
    _enc_long(Int64(0), p)  # row 0: branch bytes
    _enc_long(Int64(1), p)
    p.append(0xAB)
    _enc_long(Int64(1), p)  # row 1: branch null
    var buf = _ocf(writer, p, 2)
    var rb = read_avro_bytes(Span(buf))
    assert_equal(rb.num_rows(), 2)
    ref wcol = rb.column_at(0)
    var wa = wcol.as_binary()
    assert_true(not wa.is_null(0), "row 0 is not null")
    var w0 = wa.get(0)
    assert_equal(Int(w0[0]), 0xAB, "row 0 == AB")
    assert_true(wa.is_null(1), "row 1 is null")


def main() raises:
    test_bytes_default_is_latin1()
    test_fixed_default()
    test_refusals()
    test_union_first_branch()
    test_resolution_applies_latin1_default()
    test_writer_union_null_default_opens()
    print("test_avro_bytes_fixed_defaults: ALL PASS")
