# =============================================================================
# test_plan_vectors.mojo -- the calendar plan's named cases, read off the
# pinned tz release one by one
# =============================================================================
#
# Each expected instant is written from the published rule it tests and built
# with seconds_from_fields (komira_datetime), so a reader can check it
# without zdump: test_named_zones holds the same zones to zdump wholesale.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_datetime import (
    FoldPolicy,
    GapPolicy,
    LocalKind,
    load_zone,
    local_seconds,
    seconds_from_fields,
)
from komira_datetime_conformance import zoneinfo_dir


def test_us_2007_rule_change() raises:
    # Until 2006 DST started the first Sunday of April and ended the last
    # Sunday of October; from 2007, the second Sunday of March to the first
    # Sunday of November, at 02:00 local each time.
    var z = load_zone(zoneinfo_dir(), "America/New_York")
    assert_equal(
        z.next_transition(seconds_from_fields(2006, 1, 1)).value().at,
        seconds_from_fields(2006, 4, 2, 7),
    )
    assert_equal(
        z.next_transition(seconds_from_fields(2006, 4, 2, 7)).value().at,
        seconds_from_fields(2006, 10, 29, 6),
    )
    var s2007 = z.next_transition(seconds_from_fields(2007, 1, 1)).value().copy()
    assert_equal(s2007.at, seconds_from_fields(2007, 3, 11, 7))
    assert_equal(s2007.before.abbreviation, "EST")
    assert_equal(s2007.after.abbreviation, "EDT")
    assert_equal(
        z.next_transition(s2007.at).value().at, seconds_from_fields(2007, 11, 4, 6)
    )
    assert_equal(z.offset_at(seconds_from_fields(2006, 3, 20)).abbreviation, "EST")
    assert_equal(z.offset_at(seconds_from_fields(2007, 3, 20)).abbreviation, "EDT")
    # 02:30 on 11 March 2007 did not exist.
    var l = local_seconds(2007, 3, 11, 2, 30)
    assert_true(z.resolve(l).kind == LocalKind.GAP)
    assert_equal(
        z.to_utc(l, GapPolicy.SHIFT_FORWARD, FoldPolicy.REFUSE),
        seconds_from_fields(2007, 3, 11, 7, 30),
    )
    assert_equal(
        z.to_utc(l, GapPolicy.SHIFT_BACKWARD, FoldPolicy.REFUSE),
        seconds_from_fields(2007, 3, 11, 6, 30),
    )


def test_london() raises:
    # BST from 01:00Z the last Sunday of March to 01:00Z the last Sunday of
    # October; 2040 is past the file's listed transitions and past 2038.
    var z = load_zone(zoneinfo_dir(), "Europe/London")
    var start = z.next_transition(seconds_from_fields(2040, 1, 1)).value().copy()
    assert_equal(start.at, seconds_from_fields(2040, 3, 25, 1))
    assert_equal(start.after.abbreviation, "BST")
    assert_equal(start.after.utc_offset, 3600)
    var end = z.next_transition(start.at).value().copy()
    assert_equal(end.at, seconds_from_fields(2040, 10, 28, 1))
    assert_equal(end.after.abbreviation, "GMT")
    # 01:30 on 28 October 2040 shows twice: 00:30Z in BST, 01:30Z in GMT.
    var l = local_seconds(2040, 10, 28, 1, 30)
    var r = z.resolve(l)
    assert_true(r.kind == LocalKind.FOLD)
    assert_equal(r.earlier, seconds_from_fields(2040, 10, 28, 0, 30))
    assert_equal(r.later, seconds_from_fields(2040, 10, 28, 1, 30))


def test_lord_howe_half_hour() raises:
    # +10:30 standard, +11 daylight: the clock moves 30 minutes. 7 October
    # 2040 is the first Sunday: 02:00-02:30 local is skipped.
    var z = load_zone(zoneinfo_dir(), "Australia/Lord_Howe")
    assert_equal(z.offset_at(seconds_from_fields(2040, 6, 1)).utc_offset, 37800)
    assert_equal(z.offset_at(seconds_from_fields(2040, 12, 1)).utc_offset, 39600)
    var l = local_seconds(2040, 10, 7, 2, 15)
    var r = z.resolve(l)
    assert_true(r.kind == LocalKind.GAP)
    assert_equal(r.later - r.earlier, 1800)
    assert_equal(
        z.to_utc(l, GapPolicy.SHIFT_FORWARD, FoldPolicy.REFUSE),
        seconds_from_fields(2040, 10, 6, 15, 45),
    )


def test_kathmandu_quarter_hour() raises:
    # +5:30 until 1986-01-01 00:00 local, then +5:45: 00:00-00:15 skipped.
    var z = load_zone(zoneinfo_dir(), "Asia/Kathmandu")
    assert_equal(z.offset_at(seconds_from_fields(1985, 6, 1)).utc_offset, 19800)
    assert_equal(z.offset_at(seconds_from_fields(2030, 6, 1)).utc_offset, 20700)
    assert_equal(z.offset_at(seconds_from_fields(2030, 6, 1)).abbreviation, "+0545")
    var t = z.next_transition(seconds_from_fields(1985, 1, 1)).value().copy()
    assert_equal(t.at, seconds_from_fields(1985, 12, 31, 18, 30))
    var r = z.resolve(local_seconds(1986, 1, 1, 0, 10))
    assert_true(r.kind == LocalKind.GAP)
    assert_equal(r.earlier, seconds_from_fields(1985, 12, 31, 18, 25))
    assert_equal(r.later, seconds_from_fields(1985, 12, 31, 18, 40))
    assert_false(Bool(z.next_transition(t.at)))


def test_sao_paulo_dst_abolished() raises:
    # The last DST ended 17 February 2019 (00:00 local -02, 02:00Z); none
    # followed, so the summer of 2019-2020 stays at -03 for ever after.
    var z = load_zone(zoneinfo_dir(), "America/Sao_Paulo")
    assert_equal(z.offset_at(seconds_from_fields(2019, 1, 15)).utc_offset, -7200)
    assert_true(z.offset_at(seconds_from_fields(2019, 1, 15)).is_dst)
    assert_equal(z.offset_at(seconds_from_fields(2020, 1, 15)).utc_offset, -10800)
    assert_equal(z.offset_at(seconds_from_fields(2050, 1, 15)).utc_offset, -10800)
    var last = z.next_transition(seconds_from_fields(2019, 1, 1)).value().copy()
    assert_equal(last.at, seconds_from_fields(2019, 2, 17, 2))
    assert_false(Bool(z.next_transition(last.at)))


def test_apia_skipped_day() raises:
    # Samoa crossed the date line: 29 December 2011 23:59:59 at -10 was
    # followed by 31 December 00:00 at +14, at 10:00Z on the 30th.
    var z = load_zone(zoneinfo_dir(), "Pacific/Apia")
    var t = z.next_transition(seconds_from_fields(2011, 12, 1)).value().copy()
    assert_equal(t.at, seconds_from_fields(2011, 12, 30, 10))
    assert_equal(t.before.utc_offset, -36000)
    assert_equal(t.after.utc_offset, 50400)
    var noon = local_seconds(2011, 12, 30, 12)
    var r = z.resolve(noon)
    assert_true(r.kind == LocalKind.GAP)
    assert_equal(r.earlier, seconds_from_fields(2011, 12, 29, 22))
    assert_equal(r.later, seconds_from_fields(2011, 12, 30, 22))
    var forward = z.to_utc(noon, GapPolicy.SHIFT_FORWARD, FoldPolicy.REFUSE)
    assert_equal(z.local_fields(forward).day, 31)
    assert_equal(z.local_fields(forward).hour, 12)
    var got = String()
    try:
        _ = z.to_utc(noon, GapPolicy.REFUSE, FoldPolicy.REFUSE)
    except e:
        got = String(e)
    assert_equal(
        got,
        "zone Pacific/Apia: local time 2011-12-30T12:00:00 does not exist"
        " (the clock skipped it)",
    )
    var before = z.resolve(local_seconds(2011, 12, 29, 23, 59, 59))
    assert_true(before.kind == LocalKind.UNIQUE)
    assert_equal(before.earlier, seconds_from_fields(2011, 12, 30, 9, 59, 59))
    var after = z.resolve(local_seconds(2011, 12, 31))
    assert_true(after.kind == LocalKind.UNIQUE)
    assert_equal(after.earlier, seconds_from_fields(2011, 12, 30, 10))
    # DST was abolished in 2021: no change after April 2021.
    assert_false(Bool(z.next_transition(seconds_from_fields(2021, 4, 5))))


def test_after_2038() raises:
    # Past 2038-01-19T03:14:07Z, where a 32-bit time ends: the footer's rules
    # keep going.
    var z = load_zone(zoneinfo_dir(), "America/New_York")
    assert_equal(
        z.next_transition(seconds_from_fields(2038, 3, 1)).value().at,
        seconds_from_fields(2038, 3, 14, 7),
    )
    assert_equal(
        z.next_transition(seconds_from_fields(2099, 1, 1)).value().at,
        seconds_from_fields(2099, 3, 8, 7),
    )
    assert_equal(z.offset_at(seconds_from_fields(2100, 7, 1)).abbreviation, "EDT")


def main() raises:
    test_us_2007_rule_change()
    test_london()
    test_lord_howe_half_hour()
    test_kathmandu_quarter_hour()
    test_sao_paulo_dst_abolished()
    test_apia_skipped_day()
    test_after_2038()
    print("all plan-vector tests passed")
