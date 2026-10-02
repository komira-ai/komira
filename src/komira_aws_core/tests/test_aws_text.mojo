# The text form of REST-bound scalars (aws_text.mojo): the exact text each
# Smithy HTTP binding rule writes, the strict readers, and the three
# timestamp formats as text. Each row is derived from the rule it cites:
#
#   [B]  https://smithy.io/2.0/spec/http-bindings.html (httpHeader,
#        httpLabel, httpQuery serialization rules)
#   [T]  https://smithy.io/2.0/spec/protocol-traits.html#timestampformat-trait
#   [H]  RFC 9110 section 5.6.7 (HTTP-date; IMF-fixdate), whose example
#        instant "Sun, 06 Nov 1994 08:49:37 GMT" is epoch 784111777
#   [R]  RFC 3339 section 5.6 (date-time)
#   [64] RFC 4648 section 4 (base64)

from std.testing import assert_equal, assert_true

from komira_aws_core import (
    AWS_TS_ISO8601,
    AWS_TS_RFC822,
    AWS_TS_UNIX,
    aws_blob_from_base64,
    aws_bool_from_text,
    aws_f64_from_text,
    aws_http_date_from_text,
    aws_i32_from_text,
    aws_i64_from_text,
    aws_int_from_text,
    aws_media_from_text,
    aws_text_blob,
    aws_text_bool,
    aws_text_f32,
    aws_text_f64,
    aws_text_int,
    aws_text_media,
    aws_text_ts,
    aws_ts_from_text,
)


comptime _RFC9110_EXAMPLE = 784111777.0


def _refused_int(text: String, bits: Int) raises:
    try:
        _ = aws_int_from_text(text, bits)
    except:
        return
    raise Error("integer '" + text + "' (" + String(bits) + ") was read")


def _refused_f64(text: String) raises:
    try:
        _ = aws_f64_from_text(text)
    except:
        return
    raise Error("number '" + text + "' was read")


def _refused_ts(text: String, fmt: Int) raises:
    try:
        _ = aws_ts_from_text(text, fmt)
    except:
        return
    raise Error("timestamp '" + text + "' was read in format " + String(fmt))


def _refused_bool(text: String) raises:
    try:
        _ = aws_bool_from_text(text)
    except:
        return
    raise Error("boolean '" + text + "' was read")


def test_booleans() raises:
    # [B] "true" / "false", and nothing else is read as one.
    assert_equal(aws_text_bool(True), "true")
    assert_equal(aws_text_bool(False), "false")
    assert_true(aws_bool_from_text("true"))
    assert_true(not aws_bool_from_text("false"))
    _refused_bool("TRUE")
    _refused_bool("True")
    _refused_bool("1")
    _refused_bool(" true")
    _refused_bool("")


def test_integers() raises:
    # [B] decimal, an optional '-'.
    assert_equal(aws_text_int(Int64(0)), "0")
    assert_equal(aws_text_int(Int64(-128)), "-128")
    assert_equal(aws_text_int(Int64(9007199254740993)), "9007199254740993")
    # Each kind's bounds read; one past them is refused.
    assert_equal(aws_int_from_text("127", 8), Int64(127))
    assert_equal(aws_int_from_text("-128", 8), Int64(-128))
    _refused_int("128", 8)
    _refused_int("-129", 8)
    assert_equal(aws_int_from_text("32767", 16), Int64(32767))
    assert_equal(aws_int_from_text("-32768", 16), Int64(-32768))
    _refused_int("32768", 16)
    assert_equal(aws_i32_from_text("2147483647"), Int32(2147483647))
    assert_equal(aws_i32_from_text("-2147483648"), Int32(-2147483648))
    _refused_int("2147483648", 32)
    _refused_int("-2147483649", 32)
    assert_equal(aws_i64_from_text("9223372036854775807"), Int64.MAX)
    assert_equal(aws_i64_from_text("-9223372036854775808"), Int64.MIN)
    _refused_int("9223372036854775808", 64)
    _refused_int("-9223372036854775809", 64)
    _refused_int("99999999999999999999999", 64)
    assert_equal(aws_i64_from_text("-0"), Int64(0))
    assert_equal(aws_i64_from_text("007"), Int64(7))
    # Only what the writer writes is read.
    _refused_int("", 32)
    _refused_int("-", 32)
    _refused_int("+1", 32)
    _refused_int("1.0", 32)
    _refused_int(" 1", 32)
    _refused_int("1 ", 32)
    _refused_int("0x10", 32)
    _refused_int("1", 12)


def test_floats() raises:
    # [B] the decimal number; the three non-finite values by name.
    var z = Float64(0.0)
    var inf = Float64(1.0) / z
    assert_equal(aws_text_f64(1.5), "1.5")
    assert_equal(aws_text_f64(-0.25), "-0.25")
    assert_equal(aws_text_f64(z / z), "NaN")
    assert_equal(aws_text_f64(inf), "Infinity")
    assert_equal(aws_text_f64(-inf), "-Infinity")
    assert_equal(aws_text_f32(Float32(0.1)), "0.1")
    assert_equal(aws_text_f32(Float32(1.0) / Float32(0.0)), "Infinity")
    var nan = aws_f64_from_text("NaN")
    assert_true(nan != nan, "NaN did not read as NaN")
    assert_equal(aws_f64_from_text("Infinity"), inf)
    assert_equal(aws_f64_from_text("-Infinity"), -inf)
    assert_equal(aws_f64_from_text("1.5"), 1.5)
    assert_equal(aws_f64_from_text("-2e3"), -2000.0)
    assert_equal(aws_f64_from_text("1E+2"), 100.0)
    assert_equal(aws_f64_from_text("7"), 7.0)
    var vals: List[Float64] = [0.0, 0.1, -3.75, 1e300, 123456789.125]
    for i in range(len(vals)):
        var t = aws_text_f64(vals[i])
        assert_equal(aws_f64_from_text(t), vals[i], t)
    _refused_f64("")
    _refused_f64(".5")
    _refused_f64("5.")
    _refused_f64("+1")
    _refused_f64("1e")
    _refused_f64("nan")
    _refused_f64("inf")
    _refused_f64("+Infinity")
    _refused_f64(" 1")
    _refused_f64("1,5")


def test_blobs_and_media() raises:
    # [64] standard alphabet, padded.
    var hi: List[UInt8] = [UInt8(0x68), UInt8(0x69)]
    assert_equal(aws_text_blob(Span(hi)), "aGk=")
    var back = aws_blob_from_base64("aGk=")
    assert_equal(len(back), 2)
    assert_equal(back[0], UInt8(0x68))
    assert_equal(back[1], UInt8(0x69))
    try:
        _ = aws_blob_from_base64("aGk")
        raise Error("unpadded base64 was read")
    except e:
        assert_true(String(e).find("not valid base64") >= 0, String(e))
    # [B] a @mediaType / @jsonValue string in a header is base64 of its
    # UTF-8 bytes.
    assert_equal(aws_text_media('{"a":1}'), "eyJhIjoxfQ==")
    assert_equal(aws_media_from_text("eyJhIjoxfQ=="), '{"a":1}')
    assert_equal(aws_media_from_text(aws_text_media("é😹")), "é😹")
    # Decoded bytes that are not UTF-8 (0xFF) are refused.
    try:
        _ = aws_media_from_text("/w==")
        raise Error("a non-UTF-8 media value was read")
    except e:
        assert_true(String(e).find("UTF-8") >= 0, String(e))


def test_timestamp_text() raises:
    # [H] the RFC 9110 example instant in each format.
    assert_equal(
        aws_text_ts(_RFC9110_EXAMPLE, AWS_TS_RFC822),
        "Sun, 06 Nov 1994 08:49:37 GMT",
    )
    # [R] / [T] date-time: UTC, "Z".
    assert_equal(
        aws_text_ts(_RFC9110_EXAMPLE, AWS_TS_ISO8601), "1994-11-06T08:49:37Z"
    )
    # [T] epoch-seconds: a whole number when there is no fraction.
    assert_equal(aws_text_ts(_RFC9110_EXAMPLE, AWS_TS_UNIX), "784111777")
    # Milliseconds are kept by date-time and epoch-seconds, trailing zeros
    # cut; IMF-fixdate has none.
    var frac = _RFC9110_EXAMPLE + 0.25
    assert_equal(aws_text_ts(frac, AWS_TS_ISO8601), "1994-11-06T08:49:37.25Z")
    assert_equal(aws_text_ts(frac, AWS_TS_UNIX), "784111777.25")
    assert_equal(aws_text_ts(frac, AWS_TS_RFC822), "Sun, 06 Nov 1994 08:49:37 GMT")
    # The epoch itself; 1970-01-01 was a Thursday.
    assert_equal(aws_text_ts(0.0, AWS_TS_RFC822), "Thu, 01 Jan 1970 00:00:00 GMT")
    assert_equal(aws_text_ts(0.0, AWS_TS_ISO8601), "1970-01-01T00:00:00Z")
    assert_equal(aws_text_ts(0.0, AWS_TS_UNIX), "0")
    # A leap day (2000 is a leap year: divisible by 400); a Tuesday.
    assert_equal(
        aws_text_ts(951782400.0, AWS_TS_RFC822), "Tue, 29 Feb 2000 00:00:00 GMT"
    )
    assert_equal(aws_text_ts(951782400.0, AWS_TS_ISO8601), "2000-02-29T00:00:00Z")
    # Refused: before 1970, NaN, an unknown format.
    var z = Float64(0.0)
    var bad: List[Float64] = [-1.0, z / z]
    for i in range(len(bad)):
        try:
            _ = aws_text_ts(bad[i], AWS_TS_ISO8601)
            raise Error("timestamp " + String(bad[i]) + " was written")
        except e:
            assert_true(String(e).find("AWS timestamp") >= 0, String(e))
    try:
        _ = aws_text_ts(0.0, 7)
        raise Error("format 7 was written")
    except e:
        assert_true(String(e).find("unknown AWS timestamp format") >= 0)


def test_timestamp_read() raises:
    # Every written form reads back in its own format.
    var fmts: List[Int] = [AWS_TS_ISO8601, AWS_TS_RFC822, AWS_TS_UNIX]
    var instants: List[Float64] = [0.0, _RFC9110_EXAMPLE, 951782400.0]
    for f in range(len(fmts)):
        for k in range(len(instants)):
            var t = aws_text_ts(instants[k], fmts[f])
            assert_equal(aws_ts_from_text(t, fmts[f]), instants[k], t)
    # [R] an offset is the same instant; any number of fraction digits.
    assert_equal(
        aws_ts_from_text("1994-11-06T09:49:37+01:00", AWS_TS_ISO8601),
        _RFC9110_EXAMPLE,
    )
    assert_equal(
        aws_ts_from_text("1994-11-06T08:49:37.5Z", AWS_TS_ISO8601),
        _RFC9110_EXAMPLE + 0.5,
    )
    var nine = aws_ts_from_text("1994-11-06T08:49:37.123456789Z", AWS_TS_ISO8601)
    assert_true(abs(nine - (_RFC9110_EXAMPLE + 0.123456789)) < 1e-6)
    # [H] IMF-fixdate with a fraction of a second.
    assert_equal(
        aws_http_date_from_text("Sun, 06 Nov 1994 08:49:37.5 GMT"),
        _RFC9110_EXAMPLE + 0.5,
    )
    # [T] epoch-seconds with a fraction, and before the epoch.
    assert_equal(aws_ts_from_text("784111777.25", AWS_TS_UNIX), frac_example())
    assert_equal(aws_ts_from_text("-1.5", AWS_TS_UNIX), -1.5)
    # Text of one format is not read as another.
    _refused_ts("1994-11-06T08:49:37Z", AWS_TS_RFC822)
    _refused_ts("1994-11-06T08:49:37Z", AWS_TS_UNIX)
    _refused_ts("Sun, 06 Nov 1994 08:49:37 GMT", AWS_TS_ISO8601)
    _refused_ts("784111777", AWS_TS_ISO8601)
    _refused_ts("784111777", AWS_TS_RFC822)
    _refused_ts("7.8e8", AWS_TS_UNIX)
    _refused_ts("", AWS_TS_UNIX)
    _refused_ts("1994-11-06", AWS_TS_ISO8601)
    _refused_ts("1994-11-06T08:49:37", AWS_TS_ISO8601)
    _refused_ts("1994-02-30T08:49:37Z", AWS_TS_ISO8601)
    _refused_ts("784111777", 9)
    # [H] the two obsolete forms are refused, as the AWS SDKs refuse them.
    _refused_ts("Sunday, 06-Nov-94 08:49:37 GMT", AWS_TS_RFC822)
    _refused_ts("Sun Nov  6 08:49:37 1994", AWS_TS_RFC822)
    # [H] IMF-fixdate is exact: names are case-sensitive, the day has two
    # digits, the zone is GMT, the day exists.
    _refused_ts("sun, 06 Nov 1994 08:49:37 GMT", AWS_TS_RFC822)
    _refused_ts("Xyz, 06 Nov 1994 08:49:37 GMT", AWS_TS_RFC822)
    _refused_ts("Sun, 06 nov 1994 08:49:37 GMT", AWS_TS_RFC822)
    _refused_ts("Sun, 6 Nov 1994 08:49:37 GMT", AWS_TS_RFC822)
    _refused_ts("Sun, 06 Nov 1994 08:49:37 UTC", AWS_TS_RFC822)
    _refused_ts("Sun, 06 Nov 1994 08:49:37 GMT ", AWS_TS_RFC822)
    _refused_ts("Sun,06 Nov 1994 08:49:37 GMT ", AWS_TS_RFC822)
    _refused_ts("Sun, 31 Nov 1994 08:49:37 GMT", AWS_TS_RFC822)
    _refused_ts("Sun, 06 Nov 1994 24:49:37 GMT", AWS_TS_RFC822)
    _refused_ts("Sun, 06 Nov 1994 08:49:37. GMT", AWS_TS_RFC822)
    # The day name is redundant (RFC 9110); a mismatched one is not checked.
    assert_equal(
        aws_http_date_from_text("Mon, 06 Nov 1994 08:49:37 GMT"),
        _RFC9110_EXAMPLE,
    )


def frac_example() -> Float64:
    return _RFC9110_EXAMPLE + 0.25


def main() raises:
    test_booleans()
    test_integers()
    test_floats()
    test_blobs_and_media()
    test_timestamp_text()
    test_timestamp_read()
    print("OK")
