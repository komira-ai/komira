# =============================================================================
# test_avro_bytes_fixed_defaults.mojo — a bytes or fixed field default is a
# JSON string read as Latin-1 (Avro 1.11.1, field default table): code points
# U+0000..U+00FF are the byte values; a union default is read as the first
# branch it matches (spec: "the first schema that matches"), or as the first
# branch when none matches.
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
#      checked; a default matching no branch is checked against the first;
#      int, boolean, number, array and map defaults skip a leading bytes
#      branch; a by-name enum branch takes a string default as a string.
#   T5 schema resolution: reader fields absent from the writer get the
#      Latin-1 bytes in the decoded batch, for bytes, fixed, [bytes, null],
#      [null, bytes] and [fixed, null] fields.
#   T6 a writer schema with [bytes, null] and default null still opens.
#   T7 schema resolution refuses a reader default that does not fit the
#      reader column (exact messages), and still accepts one that fits.
#   T8 schema resolution accepts a default on every arm of the fit check
#      and synthesizes its value: string ("x", "", enum symbol, uuid,
#      [string, null]); boolean; int into int, long, date, timestamp-millis,
#      float, double and [int, null]; double into float and double; bytes
#      ("\u00ff" is FF); null into [long, null] (null as the second branch)
#      and [null, string].
#      A fit check too strict on any arm refuses the reader and goes red.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import (
    AvroSchema,
    read_avro_bytes,
    AVRO_DEFAULT_BOOL,
    AVRO_DEFAULT_BYTES,
    AVRO_DEFAULT_DOUBLE,
    AVRO_DEFAULT_INT,
    AVRO_DEFAULT_NONE,
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


def test_union_first_matching_branch() raises:
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
    # Each JSON value type skips a leading bytes branch and matches the
    # later branch of its type.
    assert_equal(
        _field_default_kind(_one_field('["bytes","long"]', "5"), 0),
        AVRO_DEFAULT_INT,
    )
    assert_equal(
        _field_default_kind(_one_field('["bytes","boolean"]', "true"), 0),
        AVRO_DEFAULT_BOOL,
    )
    assert_equal(
        _field_default_kind(_one_field('["bytes","double"]', "1"), 0),
        AVRO_DEFAULT_INT,
    )
    assert_equal(
        _field_default_kind(_one_field('["bytes","double"]', "1.5"), 0),
        AVRO_DEFAULT_DOUBLE,
    )
    # Array and map defaults are accepted and not captured.
    assert_equal(
        _field_default_kind(
            _one_field('["bytes",{"type":"array","items":"int"}]', "[]"), 0
        ),
        AVRO_DEFAULT_NONE,
    )
    assert_equal(
        _field_default_kind(
            _one_field('["bytes",{"type":"map","values":"int"}]', "{}"), 0
        ),
        AVRO_DEFAULT_NONE,
    )
    # Field g's union names the enum defined by field e; a string default
    # matches the enum branch and is not read as bytes.
    assert_equal(
        _field_default_kind(
            '{"type":"record","name":"R","fields":['
            '{"name":"e","type":{"type":"enum","name":"E","symbols":["A"]}},'
            '{"name":"g","type":["E","bytes"],"default":"A"}]}',
            1,
        ),
        AVRO_DEFAULT_STRING,
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


def _resolve_refusal(reader_field: String) -> String:
    """Resolve a one-row file whose writer has only `id` against a reader
    that adds `reader_field`; return the error text."""
    var writer = String(
        '{"type":"record","name":"R","fields":[{"name":"id","type":"long"}]}'
    )
    var reader = (
        String('{"type":"record","name":"R","fields":[')
        + '{"name":"id","type":"long"},'
        + reader_field
        + "]}"
    )
    var p = List[UInt8]()
    _enc_long(Int64(5), p)
    var buf = _ocf(writer, p, 1)
    try:
        _ = read_avro_bytes_resolved(Span(buf), reader)
    except e:
        return String(e)
    return String("<accepted>")


def test_resolution_refuses_unfit_default() raises:
    """T7: a reader default whose kind does not fit the reader column is
    refused when the resolution table is built, before any row is filled."""
    # The int default matches no branch; the first branch (null) is not
    # bytes, so the schema parses and the default is captured as int.
    assert_equal(
        _resolve_refusal(
            '{"name":"n","type":["null","bytes"],"default":5}'
        ),
        "AvroResolutionError.INVALID_DEFAULT: reader field 'n' has an int"
        " default that does not fit its type (Avro bytes)",
    )
    assert_equal(
        _resolve_refusal('{"name":"s","type":"long","default":"x"}'),
        "AvroResolutionError.INVALID_DEFAULT: reader field 's' has a string"
        " default that does not fit its type (Avro long)",
    )
    assert_equal(
        _resolve_refusal('{"name":"z","type":"int","default":null}'),
        "AvroResolutionError.INVALID_DEFAULT: reader field 'z' has a null"
        " default that does not fit its type (Avro int)",
    )
    assert_equal(
        _resolve_refusal('{"name":"t","type":"string","default":true}'),
        "AvroResolutionError.INVALID_DEFAULT: reader field 't' has a boolean"
        " default that does not fit its type (Avro string)",
    )
    assert_equal(
        _resolve_refusal('{"name":"i","type":"int","default":1.5}'),
        "AvroResolutionError.INVALID_DEFAULT: reader field 'i' has a double"
        " default that does not fit its type (Avro int)",
    )
    assert_equal(
        _resolve_refusal(
            '{"name":"d","type":{"type":"bytes","logicalType":"decimal",'
            '"precision":4,"scale":0},"default":"\\u0001"}'
        ),
        "AvroResolutionError.INVALID_DEFAULT: reader field 'd' has a bytes"
        " default that does not fit its type (Avro bytes, logical decimal)",
    )
    # Defaults that fit are still accepted.
    assert_equal(
        _resolve_refusal('{"name":"k","type":"double","default":2}'),
        "<accepted>",
    )
    assert_equal(
        _resolve_refusal('{"name":"m","type":["null","long"],"default":null}'),
        "<accepted>",
    )


def test_resolution_accepts_fitting_defaults() raises:
    """T8: one reader adds a field per arm of the default fit check; the
    file resolves and every row carries the synthesized default."""
    var writer = String(
        '{"type":"record","name":"R","fields":[{"name":"id","type":"long"}]}'
    )
    var reader = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"id","type":"long"},'
        '{"name":"s","type":"string","default":"x"},'
        '{"name":"s0","type":"string","default":""},'
        '{"name":"e","type":{"type":"enum","name":"E","symbols":["A","B"]},'
        '"default":"B"},'
        '{"name":"uu","type":{"type":"string","logicalType":"uuid"},'
        '"default":"123e4567-e89b-12d3-a456-426614174000"},'
        '{"name":"t","type":"boolean","default":true},'
        '{"name":"i","type":"int","default":5},'
        '{"name":"l","type":"long","default":7},'
        '{"name":"dt","type":{"type":"int","logicalType":"date"},'
        '"default":3},'
        '{"name":"ts","type":{"type":"long","logicalType":"timestamp-millis"},'
        '"default":9},'
        '{"name":"f","type":"float","default":1.5},'
        '{"name":"fi","type":"float","default":2},'
        '{"name":"d","type":"double","default":2.5},'
        '{"name":"ln","type":["long","null"],"default":null},'
        '{"name":"ns","type":["null","string"],"default":null},'
        '{"name":"sn","type":["string","null"],"default":"y"},'
        '{"name":"in","type":["int","null"],"default":4},'
        '{"name":"di","type":"double","default":3},'
        '{"name":"b","type":"bytes","default":"\\u00ff"}]}'
    )
    var p = List[UInt8]()
    _enc_long(Int64(5), p)
    _enc_long(Int64(6), p)
    var buf = _ocf(writer, p, 2)
    var rb = read_avro_bytes_resolved(Span(buf), reader)
    assert_equal(rb.num_rows(), 2)
    assert_equal(rb.num_columns(), 19)
    for r in range(2):
        assert_equal(rb.column_at(1).as_string().get(r), String("x"), "s")
        assert_equal(rb.column_at(2).as_string().get(r), String(""), "s0")
        assert_equal(rb.column_at(3).as_string().get(r), String("B"), "e")
        assert_equal(
            rb.column_at(4).as_string().get(r),
            String("123e4567-e89b-12d3-a456-426614174000"),
            "uu",
        )
        assert_equal(rb.column_at(5).as_boolean().get(r), True, "t")
        assert_equal(
            Int(rb.column_at(6).as_primitive[DType.int32]().get(r)), 5, "i"
        )
        assert_equal(
            Int(rb.column_at(7).as_primitive[DType.int64]().get(r)), 7, "l"
        )
        assert_equal(
            Int(rb.column_at(8).as_primitive[DType.int32]().get(r)), 3, "dt"
        )
        assert_equal(
            Int(rb.column_at(9).as_primitive[DType.int64]().get(r)), 9, "ts"
        )
        assert_equal(
            rb.column_at(10).as_primitive[DType.float32]().get(r),
            Float32(1.5),
            "f",
        )
        assert_equal(
            rb.column_at(11).as_primitive[DType.float32]().get(r),
            Float32(2.0),
            "fi",
        )
        assert_equal(
            rb.column_at(12).as_primitive[DType.float64]().get(r),
            Float64(2.5),
            "d",
        )
        assert_true(
            rb.column_at(13).as_primitive[DType.int64]().is_null(r), "ln null"
        )
        assert_true(rb.column_at(14).as_string().is_null(r), "ns null")
        var sn = rb.column_at(15).as_string()
        assert_true(not sn.is_null(r), "sn not null")
        assert_equal(sn.get(r), String("y"), "sn")
        var inc = rb.column_at(16).as_primitive[DType.int32]()
        assert_true(not inc.is_null(r), "in not null")
        assert_equal(Int(inc.get(r)), 4, "in")
        assert_equal(
            rb.column_at(17).as_primitive[DType.float64]().get(r),
            Float64(3.0),
            "di",
        )
        ref bvcol = rb.column_at(18)
        var bv = bvcol.as_binary().get(r)
        assert_equal(len(bv), 1, "b is one byte")
        assert_equal(Int(bv[0]), 0xFF, "b == FF")


def main() raises:
    test_bytes_default_is_latin1()
    test_fixed_default()
    test_refusals()
    test_union_first_matching_branch()
    test_resolution_applies_latin1_default()
    test_writer_union_null_default_opens()
    test_resolution_refuses_unfit_default()
    test_resolution_accepts_fitting_defaults()
    print("test_avro_bytes_fixed_defaults: ALL PASS")
