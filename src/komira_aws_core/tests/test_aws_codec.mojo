# The awsJson scalar codec: round trips for every scalar kind and timestamp
# format, the special doubles, the exact wire text of each, and the error
# shape (__type / code normalization, message, and that nothing else from an
# error body is ever returned).

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_core import (
    AWS_ERROR_CODE_MAX_BYTES,
    AWS_ERROR_MESSAGE_MAX_BYTES,
    AWS_JSON_BOOL,
    AWS_JSON_NUMBER,
    AWS_JSON_STRING,
    AWS_TS_ISO8601,
    AWS_TS_RFC822,
    AWS_TS_UNIX,
    AwsJsonToken,
    aws_blob_from_text,
    aws_error_code,
    aws_error_code_from_body,
    aws_error_message_from_body,
    aws_f64_from_token,
    aws_is_error_status,
    aws_token_blob,
    aws_token_bool,
    aws_token_f32,
    aws_token_f64,
    aws_token_i32,
    aws_token_i64,
    aws_token_string,
    aws_token_ts,
    aws_ts_from_token,
    expiration_unix_seconds,
)


def _is(t: AwsJsonToken, kind: Int, text: String) raises:
    assert_equal(t.kind, kind, text)
    assert_equal(t.text, text)


def test_scalars() raises:
    _is(aws_token_string("héllo \"q\""), AWS_JSON_STRING, "héllo \"q\"")
    _is(aws_token_bool(True), AWS_JSON_BOOL, "true")
    _is(aws_token_bool(False), AWS_JSON_BOOL, "false")
    _is(aws_token_i32(Int32(-2147483648)), AWS_JSON_NUMBER, "-2147483648")
    _is(aws_token_i64(Int64(9007199254740993)), AWS_JSON_NUMBER, "9007199254740993")
    _is(aws_token_i64(Int64(0)), AWS_JSON_NUMBER, "0")


def test_doubles() raises:
    var z = Float64(0.0)
    var nan = z / z
    var inf = Float64(1.0) / z
    _is(aws_token_f64(nan), AWS_JSON_STRING, "NaN")
    _is(aws_token_f64(inf), AWS_JSON_STRING, "Infinity")
    _is(aws_token_f64(-inf), AWS_JSON_STRING, "-Infinity")
    var back = aws_f64_from_token(aws_token_f64(nan))
    assert_true(back != back, "NaN did not round trip")
    assert_equal(aws_f64_from_token(aws_token_f64(inf)), inf)
    assert_equal(aws_f64_from_token(aws_token_f64(-inf)), -inf)
    var vals: List[Float64] = [0.0, 1.5, -2.25, 1e300, 0.1, 123456789.125]
    for i in range(len(vals)):
        var t = aws_token_f64(vals[i])
        assert_equal(t.kind, AWS_JSON_NUMBER, t.text)
        assert_equal(aws_f64_from_token(t), vals[i], t.text)
    # Float32 is written at its own precision and round trips through it.
    var f32s: List[Float32] = [0.1, 3.4028235e38, -1.5]
    for i in range(len(f32s)):
        var t = aws_token_f32(f32s[i])
        assert_equal(t.kind, AWS_JSON_NUMBER, t.text)
        var back32 = aws_f64_from_token(t).cast[DType.float32]()
        assert_equal(back32, f32s[i], t.text)
    # The exact text: a Float64 widening ("0.10000000149011612") would also
    # survive the round trip above.
    _is(aws_token_f32(Float32(0.1)), AWS_JSON_NUMBER, "0.1")
    _is(aws_token_f32(Float32(1.0) / Float32(0.0)), AWS_JSON_STRING, "Infinity")
    # A double read from a string that is not one of the three is refused.
    try:
        _ = aws_f64_from_token(aws_token_string("1.5"))
        raise Error("accepted a string double")
    except e:
        assert_true(String(e).find("NaN / Infinity") >= 0, String(e))
    try:
        _ = aws_f64_from_token(AwsJsonToken(AWS_JSON_NUMBER, "1.5x"))
        raise Error("accepted a malformed number")
    except e:
        assert_true(String(e).find("outside") >= 0, String(e))


def test_blobs() raises:
    var raw: List[UInt8] = [0, 1, 2, 250, 255, 0x66, 0x6F, 0x6F]
    var t = aws_token_blob(Span(raw))
    _is(t, AWS_JSON_STRING, "AAEC+v9mb28=")
    var back = aws_blob_from_text(t.text)
    assert_equal(len(back), len(raw))
    for i in range(len(raw)):
        assert_equal(back[i], raw[i])
    var empty = List[UInt8]()
    _is(aws_token_blob(Span(empty)), AWS_JSON_STRING, "")
    assert_equal(len(aws_blob_from_text("")), 0)
    try:
        _ = aws_blob_from_text("not base64!")
        raise Error("accepted bad base64")
    except e:
        assert_true(String(e).find("not valid base64") >= 0, String(e))


def test_timestamps() raises:
    # epoch seconds, unix text, ISO 8601 text, RFC 822 text
    var rows: List[List[String]] = [
        ["0", "0", "1970-01-01T00:00:00Z", "Thu, 01 Jan 1970 00:00:00 GMT"],
        ["1789819200", "1789819200", "2026-09-19T12:00:00Z",
         "Sat, 19 Sep 2026 12:00:00 GMT"],
        ["1789819200.5", "1789819200.5", "2026-09-19T12:00:00.5Z",
         "Sat, 19 Sep 2026 12:00:00 GMT"],
        ["1789819200.125", "1789819200.125", "2026-09-19T12:00:00.125Z",
         "Sat, 19 Sep 2026 12:00:00 GMT"],
        ["951782400", "951782400", "2000-02-29T00:00:00Z",
         "Tue, 29 Feb 2000 00:00:00 GMT"],
        ["253402300799", "253402300799", "9999-12-31T23:59:59Z",
         "Fri, 31 Dec 9999 23:59:59 GMT"],
    ]
    for i in range(len(rows)):
        var r = rows[i].copy()
        var v = atof(r[0])
        var u = aws_token_ts(v, AWS_TS_UNIX)
        _is(u, AWS_JSON_NUMBER, r[1])
        var iso = aws_token_ts(v, AWS_TS_ISO8601)
        _is(iso, AWS_JSON_STRING, r[2])
        var rfc = aws_token_ts(v, AWS_TS_RFC822)
        _is(rfc, AWS_JSON_STRING, r[3])
        assert_equal(aws_ts_from_token(u), v, r[1])
        assert_equal(aws_ts_from_token(iso), v, r[2])
        # RFC 822 carries whole seconds only.
        assert_equal(aws_ts_from_token(rfc), Float64(Int(v)), r[3])
    # Offsets, lower-case separators and a numeric string are read.
    assert_equal(
        aws_ts_from_token(aws_token_string("2026-09-19T14:00:00+02:00")),
        Float64(1789819200),
    )
    assert_equal(
        aws_ts_from_token(aws_token_string("2026-09-19t12:00:00z")),
        Float64(1789819200),
    )
    assert_equal(aws_ts_from_token(aws_token_string("1789819200")), Float64(1789819200))
    # Refusals: no zone, a day that does not exist, a bad month, a zone that
    # is not GMT, a bad month name, and text that is no time at all.
    var bad: List[String] = [
        "2026-09-19T12:00:00",
        "2026-02-30T12:00:00Z",
        "2026-13-01T12:00:00Z",
        "Sat, 19 Sep 2026 12:00:00 PST",
        "Sat, 19 Foo 2026 12:00:00 GMT",
        "yesterday",
    ]
    for i in range(len(bad)):
        try:
            _ = aws_ts_from_token(aws_token_string(bad[i]))
            raise Error("accepted " + bad[i])
        except e:
            assert_true(String(e).find("accepted") < 0, String(e))
    # A date-time long enough for the ISO 8601 parser (>= 20 bytes) with no
    # zone is refused by that parser, not by the number fallback.
    try:
        _ = aws_ts_from_token(aws_token_string("2026-09-19T12:00:00.5"))
        raise Error("accepted a date-time with no zone")
    except e:
        assert_true(String(e).find("no time zone") >= 0, String(e))
    var z = Float64(0.0)
    var out_of_range: List[Float64] = [-1.0, 253402300800.0, 1e300]
    for i in range(len(out_of_range)):
        try:
            _ = aws_token_ts(out_of_range[i], AWS_TS_UNIX)
            raise Error("accepted " + String(out_of_range[i]))
        except e:
            assert_true(String(e).find("1970..9999") >= 0, String(e))
    try:
        _ = aws_token_ts(z / z, AWS_TS_ISO8601)
        raise Error("accepted a NaN time")
    except e:
        assert_true(String(e).find("is NaN") >= 0, String(e))
    # Just under the bound, rounding to the millisecond would reach
    # 10000-01-01; the millisecond is clamped instead.
    _is(
        aws_token_ts(253402300799.9996, AWS_TS_ISO8601),
        AWS_JSON_STRING,
        "9999-12-31T23:59:59.999Z",
    )
    try:
        _ = aws_token_ts(0.0, 7)
        raise Error("accepted format 7")
    except e:
        assert_true(String(e).find("unknown AWS timestamp format") >= 0, String(e))
    # The credential chain's expirations read through the same parser.
    assert_equal(expiration_unix_seconds(""), -1)
    assert_equal(expiration_unix_seconds("2026-09-19T12:00:00Z"), 1789819200)


def test_error_shape() raises:
    assert_true(aws_is_error_status(400))
    assert_true(aws_is_error_status(500))
    assert_true(aws_is_error_status(199))
    assert_true(aws_is_error_status(301))
    assert_false(aws_is_error_status(200))
    assert_false(aws_is_error_status(204))
    assert_false(aws_is_error_status(299))

    # The Smithy awsJson code normalization.
    assert_equal(aws_error_code("FooError"), "FooError")
    assert_equal(aws_error_code("aws.protocoltests.restjson#FooError"), "FooError")
    assert_equal(
        aws_error_code(
            "aws.protocoltests.restjson#FooError:http://internal.amazon.com/coral/"
            "com.amazon.coral.validate/"
        ),
        "FooError",
    )
    assert_equal(aws_error_code("FooError:http://x/"), "FooError")
    assert_equal(aws_error_code("Bad\r\nCode<script>"), "BadCodescript")
    # At most AWS_ERROR_CODE_MAX_BYTES of code.
    var long_code = String("")
    for _ in range(200):
        long_code += "A"
    var short = aws_error_code(long_code)
    assert_equal(short.byte_length(), AWS_ERROR_CODE_MAX_BYTES)
    assert_equal(AWS_ERROR_CODE_MAX_BYTES, 128)

    # A real-shaped error body with a secret-looking member next to the error.
    var body = String(
        '{"__type":"com.amazonaws.secretsmanager#ResourceNotFoundException",'
        '"Message":"Secrets Manager cannot find the specified secret.",'
        '"SecretString":"hunter2-SECRET",'
        '"Details":{"nested":["hunter3-SECRET", {"x": "}"}]}}'
    )
    assert_equal(aws_error_code_from_body(body), "ResourceNotFoundException")
    var msg = aws_error_message_from_body(body)
    assert_equal(msg, "Secrets Manager cannot find the specified secret.")
    assert_true(msg.find("SECRET") < 0)
    # `code` when there is no `__type`; `message` / `errorMessage` spellings.
    assert_equal(
        aws_error_code_from_body('{"code":"ThrottlingException","message":"slow"}'),
        "ThrottlingException",
    )
    assert_equal(
        aws_error_message_from_body('{"code":"X","message":"slow\\ndown"}'),
        "slow down",
    )
    assert_equal(
        aws_error_message_from_body('{"errorMessage":"lambda says no"}'),
        "lambda says no",
    )
    # Precedence when a body carries both members of a pair, in either
    # order: `__type` over `code`; `message` over `Message` over
    # `errorMessage`.
    assert_equal(aws_error_code_from_body('{"code":"C","__type":"T"}'), "T")
    assert_equal(aws_error_code_from_body('{"__type":"T","code":"C"}'), "T")
    assert_equal(
        aws_error_message_from_body('{"Message":"upper","message":"lower"}'),
        "lower",
    )
    assert_equal(
        aws_error_message_from_body('{"errorMessage":"e","Message":"upper"}'),
        "upper",
    )
    assert_equal(
        aws_error_message_from_body('{"message":"lower","errorMessage":"e"}'),
        "lower",
    )
    # A body that is not a JSON object yields nothing at all.
    var junk: List[String] = [
        "",
        "<html>hunter2-SECRET</html>",
        '{"__type": "X", "message": "unterminated',
        '["__type", "X"]',
        '{"__type":"X"} trailing hunter2-SECRET',
    ]
    for i in range(len(junk)):
        assert_equal(aws_error_code_from_body(junk[i]), "", junk[i])
        assert_equal(aws_error_message_from_body(junk[i]), "", junk[i])
    # A long message is cut, on a UTF-8 boundary.
    var long = String('{"message":"')
    for _ in range(AWS_ERROR_MESSAGE_MAX_BYTES):
        long += "é"
    long += '"}'
    var cut = aws_error_message_from_body(long)
    assert_true(cut.byte_length() <= AWS_ERROR_MESSAGE_MAX_BYTES)
    assert_true(cut.byte_length() >= AWS_ERROR_MESSAGE_MAX_BYTES - 1)
    assert_equal(cut.byte_length() % 2, 0, "cut inside a character")
    # One ASCII byte first puts byte 512 in the middle of an 'é', so the cut
    # has to back off one byte: 'a' + 255 x 'é' = 511 bytes.
    var odd = String('{"message":"a')
    for _ in range(AWS_ERROR_MESSAGE_MAX_BYTES):
        odd += "é"
    odd += '"}'
    var cut2 = aws_error_message_from_body(odd)
    assert_equal(cut2.byte_length(), AWS_ERROR_MESSAGE_MAX_BYTES - 1)
    var b2 = cut2.as_bytes()
    assert_equal(b2[0], UInt8(0x61))
    for i in range(1, len(b2), 2):
        assert_equal(b2[i], UInt8(0xC3), "not a whole 'é' at " + String(i))
        assert_equal(b2[i + 1], UInt8(0xA9), "not a whole 'é' at " + String(i))


def main() raises:
    test_scalars()
    test_doubles()
    test_blobs()
    test_timestamps()
    test_error_shape()
    print("OK")
