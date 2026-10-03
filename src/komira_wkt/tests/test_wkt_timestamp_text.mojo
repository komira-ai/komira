# =============================================================================
# test_wkt_timestamp_text.mojo -- google.protobuf.Timestamp text form.
# =============================================================================
#
# The proto3 JSON form of a Timestamp is RFC 3339 (section 5.6) with these
# rules from timestamp.proto and the protobuf JSON mapping:
#
#   * the range is 0001-01-01T00:00:00Z .. 9999-12-31T23:59:59.999999999Z;
#   * OUTPUT is always UTC with `Z`, and the fraction has 0, 3, 6 or 9 digits;
#   * INPUT may carry a `+hh:mm` / `-hh:mm` offset, which is applied, and a
#     fraction of one to nine digits.
#
# `seconds` counts from 1970-01-01T00:00:00Z and `nanos` counts FORWARD from
# it, so an instant before 1970 that is not a whole second is (seconds - 1,
# positive nanos), and one that is not a whole day lands on the calendar day
# that contains it. Every expected value below is an independent reading of
# the calendar (POSIX `date -u -d @<seconds>`), not output of this package.
# =============================================================================

from std.testing import assert_equal, assert_raises

from komira_wkt import Timestamp


def _out(seconds: Int, nanos: Int) raises -> String:
    return Timestamp(Int64(seconds), Int32(nanos)).to_proto3_json()


def _check_in(text: String, seconds: Int, nanos: Int) raises:
    var ts = Timestamp.from_proto3_json(text)
    assert_equal(ts.seconds, Int64(seconds))
    assert_equal(ts.nanos, Int32(nanos))


def test_pre_epoch_output() raises:
    """An instant before 1970 that is not a whole day is written on its own
    day: one second before the epoch is the last second of 1969-12-31."""
    assert_equal(_out(-1, 0), String("1969-12-31T23:59:59Z"))
    assert_equal(_out(-1, 500000000), String("1969-12-31T23:59:59.500Z"))
    assert_equal(_out(-1, 1), String("1969-12-31T23:59:59.000000001Z"))
    assert_equal(
        _out(-1, 999999999), String("1969-12-31T23:59:59.999999999Z")
    )
    assert_equal(_out(-3600, 0), String("1969-12-31T23:00:00Z"))
    assert_equal(_out(-86400, 0), String("1969-12-31T00:00:00Z"))
    assert_equal(_out(-86401, 0), String("1969-12-30T23:59:59Z"))
    assert_equal(_out(-1000000, 0), String("1969-12-20T10:13:20Z"))
    assert_equal(_out(-2208988800, 0), String("1900-01-01T00:00:00Z"))


def test_leap_day_output() raises:
    """29 February exists in years divisible by 4, except centuries not
    divisible by 400 (1900 and 2100 have none; 1600 and 2400 do)."""
    assert_equal(_out(1835395200, 0), String("2028-02-29T00:00:00Z"))
    assert_equal(_out(-2203891201, 0), String("1900-02-28T23:59:59Z"))
    assert_equal(_out(-2203891200, 0), String("1900-03-01T00:00:00Z"))
    assert_equal(_out(4107542399, 0), String("2100-02-28T23:59:59Z"))
    assert_equal(_out(4107542400, 0), String("2100-03-01T00:00:00Z"))
    assert_equal(_out(-11670998401, 0), String("1600-02-28T23:59:59Z"))
    assert_equal(_out(-11670998400, 0), String("1600-02-29T00:00:00Z"))
    assert_equal(_out(-11670825601, 0), String("1600-03-01T23:59:59Z"))
    assert_equal(_out(-62035891200, 0), String("0004-02-29T00:00:00Z"))
    assert_equal(_out(13574649599, 0), String("2400-02-29T23:59:59Z"))


def test_range_ends_output() raises:
    """The first and last instants of the range, and one past each."""
    assert_equal(_out(-62135596800, 0), String("0001-01-01T00:00:00Z"))
    assert_equal(_out(-62135596799, 0), String("0001-01-01T00:00:01Z"))
    assert_equal(_out(-62135510401, 0), String("0001-01-01T23:59:59Z"))
    assert_equal(
        _out(253402300799, 999999999),
        String("9999-12-31T23:59:59.999999999Z"),
    )
    assert_equal(_out(68255913599, 0), String("4132-12-10T23:59:59Z"))
    with assert_raises(contains="Timestamp"):
        _ = _out(-62135596801, 0)
    with assert_raises(contains="Timestamp"):
        _ = _out(253402300800, 0)


def test_nanos_output() raises:
    """The fraction is the shortest of 0, 3, 6 or 9 digits that is exact; nanos
    outside [0, 999999999] is refused."""
    assert_equal(_out(0, 0), String("1970-01-01T00:00:00Z"))
    assert_equal(_out(0, 1), String("1970-01-01T00:00:00.000000001Z"))
    assert_equal(_out(0, 1000), String("1970-01-01T00:00:00.000001Z"))
    assert_equal(_out(0, 10000000), String("1970-01-01T00:00:00.010Z"))
    assert_equal(_out(0, 120000000), String("1970-01-01T00:00:00.120Z"))
    assert_equal(_out(0, 123400000), String("1970-01-01T00:00:00.123400Z"))
    assert_equal(_out(0, 123456780), String("1970-01-01T00:00:00.123456780Z"))
    with assert_raises(contains="Timestamp"):
        _ = _out(0, -1)
    with assert_raises(contains="Timestamp"):
        _ = _out(0, 1000000000)


def test_pre_epoch_input() raises:
    """Reading is the inverse: a pre-1970 instant with a fraction is the
    second before it plus forward nanos."""
    _check_in(String("1969-12-31T23:59:59Z"), -1, 0)
    _check_in(String("1969-12-31T23:59:59.5Z"), -1, 500000000)
    _check_in(String("1969-12-30T23:59:59Z"), -86401, 0)
    _check_in(String("0001-01-01T00:00:00Z"), -62135596800, 0)
    _check_in(String("9999-12-31T23:59:59.999999999Z"), 253402300799, 999999999)
    _check_in(String("1600-02-29T00:00:00Z"), -11670998400, 0)
    _check_in(String("2400-02-29T23:59:59Z"), 13574649599, 0)


def test_offsets_input() raises:
    """An offset is applied (the instant is the local time minus the offset),
    across a day, a year and the range ends."""
    _check_in(String("1970-01-01T00:00:00+01:00"), -3600, 0)
    _check_in(String("1969-12-31T19:00:00-05:00"), 0, 0)
    _check_in(String("1970-01-01T00:59:59.25+01:00"), -1, 250000000)
    _check_in(String("2028-03-01T05:30:00+05:30"), 1835481600, 0)
    _check_in(String("0001-01-01T01:00:00+01:00"), -62135596800, 0)
    _check_in(
        String("9999-12-31T22:59:59.999999999-01:00"), 253402300799, 999999999
    )
    _check_in(String("1970-01-01T00:00:00-00:00"), 0, 0)
    # The range bounds the instant, not the written year: a year-0000 local
    # time whose offset lands it in 0001 is accepted.
    _check_in(String("0000-12-31T23:30:00-01:00"), -62135595000, 0)
    # The offset carries these outside the range.
    with assert_raises(contains="outside 0001..9999"):
        _ = Timestamp.from_proto3_json(String("0001-01-01T00:30:00+01:00"))
    with assert_raises(contains="outside 0001..9999"):
        _ = Timestamp.from_proto3_json(String("9999-12-31T23:00:00-01:00"))


def test_refused_input() raises:
    """A day that does not exist, a time out of range, a fraction of no
    digits or of more than nine, a missing zone and a lower-case `t` or `z`
    are refused, each naming the Timestamp."""
    var bad = List[String]()
    bad.append(String("2027-02-29T00:00:00Z"))
    bad.append(String("1900-02-29T00:00:00Z"))
    bad.append(String("2100-02-29T00:00:00Z"))
    bad.append(String("2027-04-31T00:00:00Z"))
    bad.append(String("2027-13-01T00:00:00Z"))
    bad.append(String("2027-00-01T00:00:00Z"))
    bad.append(String("2027-01-00T00:00:00Z"))
    bad.append(String("2027-01-01T24:00:00Z"))
    bad.append(String("2027-01-01T00:60:00Z"))
    bad.append(String("2027-01-01T23:59:60Z"))
    bad.append(String("2027-01-01T00:00:00.Z"))
    bad.append(String("2027-01-01T00:00:00.1234567890Z"))
    bad.append(String("2027-01-01T00:00:00"))
    bad.append(String("2027-01-01T00:00:00Zjunk"))
    bad.append(String("2027-01-01T00:00:00+24:00"))
    bad.append(String("2027-01-01T00:00:00+01"))
    bad.append(String("2027-01-01 00:00:00Z"))
    bad.append(String("2027-01-01"))
    bad.append(String(""))
    # `T` and `Z` must be upper case in the proto3 JSON form.
    bad.append(String("2027-01-01t00:00:00Z"))
    bad.append(String("2027-01-01T00:00:00z"))
    for i in range(len(bad)):
        with assert_raises(contains="Timestamp"):
            _ = Timestamp.from_proto3_json(bad[i])


def test_year_range_input() raises:
    """A well-formed instant before 0001 is refused by the range check, not
    by the parser."""
    with assert_raises(contains="outside 0001..9999"):
        _ = Timestamp.from_proto3_json(String("0000-12-31T23:59:59Z"))


def test_round_trip() raises:
    """Writing then reading is the identity across the range."""
    var secs = List[Int]()
    secs.append(-62135596800)
    secs.append(-11670998400)
    secs.append(-2203891201)
    secs.append(-86401)
    secs.append(-1)
    secs.append(0)
    secs.append(1835438400)
    secs.append(4107542399)
    secs.append(253402300799)
    var nanos = List[Int]()
    nanos.append(0)
    nanos.append(1)
    nanos.append(500000000)
    nanos.append(999999999)
    for i in range(len(secs)):
        for j in range(len(nanos)):
            var text = _out(secs[i], nanos[j])
            _check_in(text, secs[i], nanos[j])


def main() raises:
    test_pre_epoch_output()
    test_leap_day_output()
    test_range_ends_output()
    test_nanos_output()
    test_pre_epoch_input()
    test_offsets_input()
    test_refused_input()
    test_year_range_input()
    test_round_trip()
    print("test_wkt_timestamp_text: all tests passed")
