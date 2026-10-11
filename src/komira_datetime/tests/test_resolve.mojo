# =============================================================================
# test_resolve.mojo -- local time to UTC: unique, gap, fold, and the policies
# =============================================================================
#
# Zones from POSIX TZ strings alone (posix_zone), so every instant follows
# from the rule and a printed calendar: 1 March 2030 is a Friday, so the US
# change is Sunday 10 March (02:00 EST, 07:00Z) and Sunday 3 November (02:00
# EDT, 06:00Z); 1 October 2030 is a Tuesday and 1 April a Monday, so Lord
# Howe moves on Sunday 6 October and Sunday 7 April. Expected instants are
# built with seconds_from_fields (komira_datetime), not with this package.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_datetime import (
    FoldPolicy,
    GapPolicy,
    LocalKind,
    Zone,
    ZoneOffset,
    format_local,
    local_seconds,
    parse_posix_tz,
    posix_zone,
    seconds_from_fields,
    utc_zone,
)



def test_us_gap() raises:
    var z = posix_zone("America/New_York", "EST5EDT,M3.2.0,M11.1.0")
    var l = local_seconds(2030, 3, 10, 2, 30)
    var r = z.resolve(l)
    assert_true(r.kind == LocalKind.GAP)
    assert_equal(r.earlier, seconds_from_fields(2030, 3, 10, 6, 30))
    assert_equal(r.later, seconds_from_fields(2030, 3, 10, 7, 30))
    var forward = z.to_utc(l, GapPolicy.SHIFT_FORWARD, FoldPolicy.REFUSE)
    assert_equal(forward, seconds_from_fields(2030, 3, 10, 7, 30))
    assert_equal(z.local_fields(forward).hour, 3)
    assert_equal(z.local_fields(forward).minute, 30)
    assert_equal(z.offset_at(forward).abbreviation, "EDT")
    var backward = z.to_utc(l, GapPolicy.SHIFT_BACKWARD, FoldPolicy.REFUSE)
    assert_equal(backward, seconds_from_fields(2030, 3, 10, 6, 30))
    assert_equal(z.local_fields(backward).hour, 1)
    assert_equal(z.offset_at(backward).abbreviation, "EST")
    var got = String()
    try:
        _ = z.to_utc(l, GapPolicy.REFUSE, FoldPolicy.EARLIER)
    except e:
        got = String(e)
    assert_equal(
        got,
        "zone America/New_York: local time 2030-03-10T02:30:00 does not exist"
        " (the clock skipped it)",
    )
    # The gap is [02:00, 03:00): its first second is in it, 03:00 is not.
    assert_true(z.resolve(local_seconds(2030, 3, 10, 2)).kind == LocalKind.GAP)
    var three = z.resolve(local_seconds(2030, 3, 10, 3))
    assert_true(three.kind == LocalKind.UNIQUE)
    assert_equal(three.earlier, seconds_from_fields(2030, 3, 10, 7))
    var before = z.resolve(local_seconds(2030, 3, 10, 1, 59, 59))
    assert_true(before.kind == LocalKind.UNIQUE)
    assert_equal(before.earlier, seconds_from_fields(2030, 3, 10, 6, 59, 59))


def test_us_fold() raises:
    var z = posix_zone("America/New_York", "EST5EDT,M3.2.0,M11.1.0")
    var l = local_seconds(2030, 11, 3, 1, 30)
    var r = z.resolve(l)
    assert_true(r.kind == LocalKind.FOLD)
    assert_equal(r.earlier, seconds_from_fields(2030, 11, 3, 5, 30))
    assert_equal(r.later, seconds_from_fields(2030, 11, 3, 6, 30))
    assert_equal(
        z.to_utc(l, GapPolicy.REFUSE, FoldPolicy.EARLIER),
        seconds_from_fields(2030, 11, 3, 5, 30),
    )
    assert_equal(
        z.to_utc(l, GapPolicy.REFUSE, FoldPolicy.LATER),
        seconds_from_fields(2030, 11, 3, 6, 30),
    )
    assert_equal(z.offset_at(r.earlier).abbreviation, "EDT")
    assert_equal(z.offset_at(r.later).abbreviation, "EST")
    var got = String()
    try:
        _ = z.to_utc(l, GapPolicy.SHIFT_FORWARD, FoldPolicy.REFUSE)
    except e:
        got = String(e)
    assert_equal(
        got,
        "zone America/New_York: local time 2030-11-03T01:30:00 is ambiguous"
        " (the clock showed it twice)",
    )
    # The fold is [01:00, 02:00).
    var one = z.resolve(local_seconds(2030, 11, 3, 1))
    assert_true(one.kind == LocalKind.FOLD)
    assert_equal(one.earlier, seconds_from_fields(2030, 11, 3, 5))
    assert_equal(one.later, seconds_from_fields(2030, 11, 3, 6))
    var two = z.resolve(local_seconds(2030, 11, 3, 2))
    assert_true(two.kind == LocalKind.UNIQUE)
    assert_equal(two.earlier, seconds_from_fields(2030, 11, 3, 7))
    var just_before = z.resolve(local_seconds(2030, 11, 3, 0, 59, 59))
    assert_true(just_before.kind == LocalKind.UNIQUE)
    assert_equal(just_before.earlier, seconds_from_fields(2030, 11, 3, 4, 59, 59))


def test_unique_ignores_the_policies() raises:
    var z = posix_zone("America/New_York", "EST5EDT,M3.2.0,M11.1.0")
    var l = local_seconds(2030, 7, 4, 12)
    assert_equal(
        z.to_utc(l, GapPolicy.REFUSE, FoldPolicy.REFUSE),
        seconds_from_fields(2030, 7, 4, 16),
    )


def test_half_hour_gap_and_fold() raises:
    var z = posix_zone("Australia/Lord_Howe", "<+1030>-10:30<+11>-11,M10.1.0,M4.1.0")
    # Gap [02:00, 02:30) on 6 October 2030.
    var g = local_seconds(2030, 10, 6, 2, 15)
    var r = z.resolve(g)
    assert_true(r.kind == LocalKind.GAP)
    assert_equal(r.earlier, g - 39600)
    assert_equal(r.later, g - 37800)
    var forward = z.to_utc(g, GapPolicy.SHIFT_FORWARD, FoldPolicy.REFUSE)
    assert_equal(z.local_fields(forward).hour, 2)
    assert_equal(z.local_fields(forward).minute, 45)
    var back = z.to_utc(g, GapPolicy.SHIFT_BACKWARD, FoldPolicy.REFUSE)
    assert_equal(z.local_fields(back).hour, 1)
    assert_equal(z.local_fields(back).minute, 45)
    assert_true(z.resolve(local_seconds(2030, 10, 6, 2, 30)).kind == LocalKind.UNIQUE)
    # Fold [01:30, 02:00) on 7 April 2030.
    var f = local_seconds(2030, 4, 7, 1, 45)
    var fr = z.resolve(f)
    assert_true(fr.kind == LocalKind.FOLD)
    assert_equal(fr.earlier, f - 39600)
    assert_equal(fr.later, f - 37800)
    assert_true(z.resolve(local_seconds(2030, 4, 7, 2)).kind == LocalKind.UNIQUE)
    assert_true(z.resolve(local_seconds(2030, 4, 7, 1, 29, 59)).kind == LocalKind.UNIQUE)


def test_utc() raises:
    var z = utc_zone()
    assert_equal(z.name, "UTC")
    var l = local_seconds(2030, 3, 10, 2, 30)
    var r = z.resolve(l)
    assert_true(r.kind == LocalKind.UNIQUE)
    assert_equal(r.earlier, l)
    assert_equal(z.offset_at(l).abbreviation, "UTC")
    assert_true(not z.next_transition(0))


def test_dst_all_year_zone() raises:
    # RFC 8536 section 3.3.1: DST all year (-4h, EDT). Every rule edge
    # changes nothing, so next_transition must find none and return, and
    # resolve and to_utc, which walk next_transition, must return too.
    var z = posix_zone("x", "EST5EDT4,0/0,J365/25")
    assert_false(Bool(z.next_transition(seconds_from_fields(2040, 1, 1))))
    var l = local_seconds(2040, 1, 1, 0, 30)
    var r = z.resolve(l)
    assert_true(r.kind == LocalKind.UNIQUE)
    assert_equal(r.earlier, seconds_from_fields(2040, 1, 1, 4, 30))
    assert_equal(r.later, r.earlier)
    assert_equal(z.offset_at(r.earlier).abbreviation, "EDT")
    assert_equal(
        z.to_utc(l, GapPolicy.REFUSE, FoldPolicy.REFUSE),
        seconds_from_fields(2040, 1, 1, 4, 30),
    )


def test_format_local_and_fields() raises:
    assert_equal(format_local(local_seconds(2030, 3, 10, 2, 30)), "2030-03-10T02:30:00")
    assert_equal(format_local(local_seconds(1883, 11, 18, 12, 3, 58)), "1883-11-18T12:03:58")
    # Years below 1000 keep four digits.
    assert_equal(format_local(local_seconds(999, 12, 31, 23, 59, 59)), "0999-12-31T23:59:59")
    assert_equal(format_local(local_seconds(5, 1, 2, 3, 4, 5)), "0005-01-02T03:04:05")
    var got = String()
    try:
        _ = local_seconds(2030, 2, 29)
    except e:
        got = String(e)
    assert_equal(got, "day 29 does not exist in month 2 of year 2030")


def test_no_instant_and_no_gap_in_reach() raises:
    # Zone takes its parts as given; the TZif reader bounds an offset to 26 h,
    # and resolve looks for instants within 26 h of the local time. With a
    # +30 h type, 28:00 on 1 January 1970 lies in the gap the transition at 0
    # opens ([0 h, 30 h) local), but that transition is 28 h away: resolve
    # finds neither an instant nor a gap and says so, as does to_utc.
    var types = List[ZoneOffset]()
    types.append(ZoneOffset(0, False, "AAA"))
    types.append(ZoneOffset(30 * 3600, False, "FAR"))
    var z = Zone("far", [0], [1], types^, False, parse_posix_tz("AAA0"))
    var l = local_seconds(1970, 1, 2, 4)
    var want = (
        "zone far: local time 1970-01-02T04:00:00 has no instant and lies in no gap"
    )
    var got = String()
    try:
        _ = z.resolve(l)
    except e:
        got = String(e)
    assert_equal(got, want)
    got = String()
    try:
        _ = z.to_utc(l, GapPolicy.SHIFT_FORWARD, FoldPolicy.EARLIER)
    except e:
        got = String(e)
    assert_equal(got, want)


def main() raises:
    test_us_gap()
    test_us_fold()
    test_unique_ignores_the_policies()
    test_half_hour_gap_and_fold()
    test_utc()
    test_dst_all_year_zone()
    test_format_local_and_fields()
    test_no_instant_and_no_gap_in_reach()
    print("all resolve tests passed")
