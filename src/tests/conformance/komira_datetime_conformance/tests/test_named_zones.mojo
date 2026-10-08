# =============================================================================
# test_named_zones.mojo -- the plan's zones against zdump, 1800 to 2100
# =============================================================================
#
# goldens/named.txt is zdump -v (glibc's reading of the same pinned TZif
# files, an implementation that shares no code with komira_datetime) for New York
# (the 2007 US rule change), London, Lord Howe (a 30-minute DST), Kathmandu
# (+5:45), Sao Paulo (DST abolished in 2019) and Apia (30 December 2011
# skipped), every change from 1800 to 2100: the later ones, past the files'
# last listed transition and past 2038, come from the footer's POSIX TZ
# string.
#
# For each zone: walking `next_transition` from 1800-01-01 yields exactly the
# golden changes in order, nothing more; at each change T, `offset_at(T - 1)`
# is the type before and `offset_at(T)` the type after. Then, at every change
# with no other change within three days, local times at and around its gap
# or fold resolve to the instants the offsets imply (`_check_local`).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_datetime import (
    FoldPolicy,
    GapPolicy,
    LocalKind,
    Zone,
    load_zone,
    seconds_from_fields,
)
from komira_datetime_conformance import (
    GoldenChange,
    NAMED_GOLDENS,
    read_goldens,
    show_transition,
    zoneinfo_dir,
)

comptime _NEAR = 3 * 86400


def _expect(z: Zone, local: Int, kind: LocalKind, earlier: Int, later: Int, what: String) raises:
    var r = z.resolve(local)
    var where = z.name + " " + what + " local " + String(local)
    assert_true(r.kind == kind, where + ": kind " + r.kind.name() + ", expected " + kind.name())
    assert_equal(r.earlier, earlier, where + ": earlier")
    assert_equal(r.later, later, where + ": later")


def _check_local(z: Zone, g: GoldenChange) raises:
    var t = g.at
    var ob = g.before.utc_offset
    var oa = g.after.utc_offset
    if oa > ob:
        # A gap: [t + ob, t + oa) local never shows.
        _expect(z, t + ob, LocalKind.GAP, t + ob - oa, t, "gap start")
        _expect(z, t + oa - 1, LocalKind.GAP, t - 1, t + oa - ob - 1, "gap end")
        _expect(z, t + oa, LocalKind.UNIQUE, t, t, "after the gap")
        _expect(z, t + ob - 1, LocalKind.UNIQUE, t - 1, t - 1, "before the gap")
        assert_equal(z.to_utc(t + ob, GapPolicy.SHIFT_FORWARD, FoldPolicy.REFUSE), t)
        assert_equal(
            z.to_utc(t + ob, GapPolicy.SHIFT_BACKWARD, FoldPolicy.REFUSE), t + ob - oa
        )
    elif oa < ob:
        # A fold: [t + oa, t + ob) local shows twice.
        _expect(z, t + oa, LocalKind.FOLD, t + oa - ob, t, "fold start")
        _expect(z, t + ob - 1, LocalKind.FOLD, t - 1, t + ob - oa - 1, "fold end")
        _expect(z, t + ob, LocalKind.UNIQUE, t + ob - oa, t + ob - oa, "after the fold")
        _expect(z, t + oa - 1, LocalKind.UNIQUE, t + oa - ob - 1, t + oa - ob - 1, "before the fold")
        assert_equal(
            z.to_utc(t + oa, GapPolicy.REFUSE, FoldPolicy.EARLIER), t + oa - ob
        )
        assert_equal(z.to_utc(t + oa, GapPolicy.REFUSE, FoldPolicy.LATER), t)
    else:
        _expect(z, t + ob, LocalKind.UNIQUE, t, t, "same offset")


def test_named_zones_match_zdump() raises:
    var goldens = read_goldens(NAMED_GOLDENS)
    var names = [
        "America/New_York",
        "Europe/London",
        "Australia/Lord_Howe",
        "Asia/Kathmandu",
        "America/Sao_Paulo",
        "Pacific/Apia",
    ]
    var dir = zoneinfo_dir()
    var start = seconds_from_fields(1800, 1, 1)
    var end = seconds_from_fields(2101, 1, 1)
    var total = 0
    var local_checked = 0
    for name in names:
        var z = load_zone(dir, name)
        var expected = List[GoldenChange]()
        for ref g in goldens:
            if g.zone == name:
                expected.append(g.copy())
        assert_true(len(expected) > 0, name + ": no golden lines")
        var t = start
        var i = 0
        while True:
            var nxt = z.next_transition(t)
            if not nxt or nxt.value().at >= end:
                break
            var tr = nxt.value().copy()
            assert_true(
                i < len(expected), name + ": a change zdump does not have: " + show_transition(tr)
            )
            assert_true(
                expected[i].matches(tr),
                name + ": got " + show_transition(tr) + ", zdump has " + expected[i].show(),
            )
            assert_true(z.offset_at(tr.at - 1) == expected[i].before, expected[i].show() + ": before")
            assert_true(z.offset_at(tr.at) == expected[i].after, expected[i].show() + ": after")
            t = tr.at
            i += 1
        assert_equal(i, len(expected), name + ": changes found vs zdump's")
        for k in range(len(expected)):
            var near_prev = k > 0 and expected[k].at - expected[k - 1].at < _NEAR
            var near_next = k + 1 < len(expected) and expected[k + 1].at - expected[k].at < _NEAR
            if not near_prev and not near_next:
                _check_local(z, expected[k])
                local_checked += 1
        total += len(expected)
    assert_equal(total, len(goldens), "every golden line belongs to a named zone")
    print(
        "  named zones: " + String(total) + " changes match zdump; local times checked at "
        + String(local_checked)
    )


def main() raises:
    test_named_zones_match_zdump()
    print("all named-zone tests passed")
