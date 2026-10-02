# The JsonValue-typed awsJson names (aws_json.mojo), as a generated
# komira_aws_<svc> module calls them. The import block below is the emitter's
# `Always` import contract (tools/build/proto-codegen/src/emit_aws/mod.rs,
# AWS_IMPORTS): every name a pure-mode module imports from komira_aws_core,
# plus JsonValue / parse_json_value from komira_json, so a name the emitter
# writes and the core does not export fails this test's compile.
#
# Each encoder is checked by the exact JSON text it serializes to, and that
# text is put back through komira_json's strict RFC 8259 parser, so a
# rendering that is not valid JSON (an `inf`, a `nan`, a bare `.5`) fails here
# rather than at AWS. Each decoder is checked against the encoder's output
# after that parse, as a response would arrive, and on the JSON kinds it must
# refuse.

from std.testing import assert_equal, assert_true

from komira_aws_core import (
    AWS_TS_ISO8601,
    AWS_TS_RFC822,
    AWS_TS_UNIX,
    AwsRequest,
    aws_blob_from_json,
    aws_error_code,
    aws_error_code_from_body,
    aws_error_message_from_body,
    aws_is_error_status,
    aws_f64_from_json,
    aws_json_blob,
    aws_json_bool,
    aws_json_f32,
    aws_json_f64,
    aws_json_i32,
    aws_json_i64,
    aws_json_string,
    aws_ts_from_json,
    aws_ts_to_json,
)
from komira_json import JsonValue, parse_json_value


def _wire(v: JsonValue, expect: String) raises -> JsonValue:
    """`v` serializes to exactly `expect`, which strict JSON parses; the
    parsed value is returned, as a response would carry it."""
    var text = v.serialize()
    assert_equal(text, expect)
    return parse_json_value(text)


def _refused(v: JsonValue, which: Int, expect: String) raises:
    var raised = False
    try:
        if which == 0:
            _ = aws_f64_from_json(v)
        elif which == 1:
            _ = aws_ts_from_json(v)
        else:
            _ = aws_blob_from_json(v)
    except e:
        raised = True
        var m = String(e)
        assert_true(m.find(expect) >= 0, m)
        assert_true(m.find("SECRET") < 0, "the value is in the error: " + m)
    assert_true(raised, "a wrong JSON kind was accepted: " + expect)


def test_scalars() raises:
    _ = _wire(aws_json_string('a"b'), '"a\\"b"')
    assert_equal(_wire(aws_json_string("héllo"), '"héllo"').as_string(), "héllo")
    assert_true(_wire(aws_json_bool(True), "true").as_bool())
    assert_true(not _wire(aws_json_bool(False), "false").as_bool())
    assert_equal(
        _wire(aws_json_i32(Int32(-2147483648)), "-2147483648").as_int64(),
        Int64(-2147483648),
    )
    assert_equal(
        _wire(aws_json_i64(Int64(9007199254740993)), "9007199254740993").as_int64(),
        Int64(9007199254740993),
    )
    assert_true(aws_json_i64(Int64(0)).is_number())
    assert_true(aws_json_string("1").is_string())


def test_doubles() raises:
    var z = Float64(0.0)
    var nan = z / z
    var inf = Float64(1.0) / z
    # NaN / Infinity travel as JSON STRINGS, never as a bare token.
    var n = _wire(aws_json_f64(nan), '"NaN"')
    var back = aws_f64_from_json(n)
    assert_true(back != back, "NaN did not round trip")
    assert_equal(aws_f64_from_json(_wire(aws_json_f64(inf), '"Infinity"')), inf)
    assert_equal(
        aws_f64_from_json(_wire(aws_json_f64(-inf), '"-Infinity"')), -inf
    )
    assert_equal(aws_f64_from_json(_wire(aws_json_f64(0.5), "0.5")), 0.5)
    var xs: List[Float64] = [0.1, -1.0e300, 123456.789, -0.0, 4503599627370497.0]
    for i in range(len(xs)):
        var v = aws_json_f64(xs[i])
        assert_true(v.is_number(), v.serialize())
        var p = parse_json_value(v.serialize())
        assert_equal(aws_f64_from_json(p), xs[i])
    # A float is written at Float32 precision and read back the way the
    # emitter writes it: Float32(aws_f64_from_json(v)).
    var f = _wire(aws_json_f32(Float32(0.1)), "0.1")
    assert_equal(Float32(aws_f64_from_json(f)), Float32(0.1))
    _ = _wire(aws_json_f32(Float32(1.0) / Float32(0.0)), '"Infinity"')
    # Only the exact three spellings are a non-finite double.
    _refused(JsonValue.from_string("nan"), 0, "neither a number nor NaN")
    _refused(JsonValue.from_bool(True), 0, "double is neither a JSON number")
    _refused(JsonValue.null(), 0, "double is neither a JSON number")


def test_blobs() raises:
    var raw: List[UInt8] = [0x00, 0x66, 0x6F, 0x6F, 0xFF]
    var p = _wire(aws_json_blob(raw), '"AGZvb/8="')
    var back = aws_blob_from_json(p)
    assert_equal(len(back), len(raw))
    for i in range(len(raw)):
        assert_equal(back[i], raw[i])
    var empty = List[UInt8]()
    assert_equal(len(aws_blob_from_json(_wire(aws_json_blob(empty), '""'))), 0)
    _refused(JsonValue.from_number("1"), 2, "blob is not a JSON string")
    _refused(JsonValue.from_string("SECRET@@"), 2, "not valid base64")


def test_timestamps() raises:
    var t = Float64(1789819200.5)
    var u = _wire(aws_ts_to_json(t, AWS_TS_UNIX), "1789819200.5")
    assert_equal(aws_ts_from_json(u), t)
    var iso = _wire(aws_ts_to_json(t, AWS_TS_ISO8601), '"2026-09-19T12:00:00.5Z"')
    assert_equal(aws_ts_from_json(iso), t)
    var rfc = _wire(
        aws_ts_to_json(t, AWS_TS_RFC822), '"Sat, 19 Sep 2026 12:00:00 GMT"'
    )
    assert_equal(aws_ts_from_json(rfc), Float64(1789819200))
    # A timestamp as a decimal STRING is read too (aws_ts_from_token).
    assert_equal(aws_ts_from_json(JsonValue.from_string("1789819200")), Float64(1789819200))
    _refused(JsonValue.from_bool(False), 1, "timestamp is neither a JSON number")
    var raised = False
    try:
        _ = aws_ts_to_json(t, 7)
    except e:
        raised = True
        assert_true(String(e).find("unknown AWS timestamp format") >= 0)
    assert_true(raised, "an unknown timestamp format was accepted")


def test_error_names_still_exported() raises:
    # The rest of the Always row resolves and behaves (its rules are tested
    # in test_aws_codec); this pins that the import block above compiles
    # against names that are used, not merely re-exported.
    assert_true(aws_is_error_status(400))
    assert_equal(aws_error_code("aws.protocols#Throttling:http"), "Throttling")
    assert_equal(aws_error_code_from_body('{"__type":"X#Y"}'), "Y")
    assert_equal(aws_error_message_from_body('{"message":"m"}'), "m")
    assert_equal(AWS_TS_UNIX, 0)


def main() raises:
    test_scalars()
    test_doubles()
    test_blobs()
    test_timestamps()
    test_error_names_still_exported()
    print("OK")
