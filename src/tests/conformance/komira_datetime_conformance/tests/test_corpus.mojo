# =============================================================================
# test_corpus.mojo -- every zone of the pinned release
# =============================================================================
#
# - The pin: tzdata.zi's first line names the IANA release the goldens were
#   made from, and the package lists exactly ZONE_COUNT zones.
# - Every listed zone loads (parse_tzif accepts all of them).
# - RFC 8536 section 3.3: a footer must agree with the last listed
#   transition's type. For every zone with both, the footer read on its own
#   (parse_posix_tz) gives the same type at that instant as the file does, so
#   each of the release's footers is parsed and evaluated once against data
#   zic wrote independently of it.
# - goldens/footer.txt (zdump -v, UT years 2037 to 2040, where the slim files
#   leave everything to the footer): for every zone, walking next_transition
#   over those years yields exactly zdump's changes, and none for a zone
#   zdump shows none for.
# - load_zone refuses an unknown zone and a name that could leave the
#   directory, each with its exact message.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_datetime import check_zone_name, load_zone, parse_posix_tz, seconds_from_fields
from komira_datetime_conformance import (
    FOOTER_GOLDENS,
    GoldenChange,
    IANA_VERSION_LINE,
    ZONE_COUNT,
    ZONES_LIST,
    first_line,
    read_goldens,
    read_lines,
    show_transition,
    zoneinfo_dir,
)


def test_the_pin() raises:
    assert_equal(first_line("tzdata/src/tzdata/zoneinfo/tzdata.zi"), IANA_VERSION_LINE)
    assert_equal(len(read_lines(ZONES_LIST)), ZONE_COUNT)


def test_every_zone_loads_and_its_footer_agrees() raises:
    var dir = zoneinfo_dir()
    var names = read_lines(ZONES_LIST)
    var with_footer = 0
    var compared = 0
    for ref name in names:
        var z = load_zone(dir, name)
        assert_equal(z.name, name)
        var footer = z.footer()
        if footer.byte_length() == 0:
            continue
        with_footer += 1
        var last = z.last_listed_transition()
        if not last:
            continue
        var at = last.value()
        var from_footer = parse_posix_tz(footer).offset_at(at)
        var from_file = z.offset_at(at)
        assert_true(
            from_footer == from_file,
            name + ": footer " + footer + " gives " + from_footer.abbreviation
            + " at the last transition " + String(at) + ", the file "
            + from_file.abbreviation,
        )
        compared += 1
    # zic writes a footer for every zone.
    assert_equal(with_footer, ZONE_COUNT)
    print(
        "  corpus: " + String(len(names)) + " zones loaded; footer agrees with "
        + String(compared) + " last transitions"
    )


def test_footer_years_match_zdump() raises:
    var goldens = read_goldens(FOOTER_GOLDENS)
    var dir = zoneinfo_dir()
    var names = read_lines(ZONES_LIST)
    var start = seconds_from_fields(2037, 1, 1) - 1
    var end = seconds_from_fields(2041, 1, 1)
    var g = 0
    var zones_changing = 0
    for ref name in names:
        var z = load_zone(dir, name)
        var t = start
        var found = 0
        while True:
            var nxt = z.next_transition(t)
            if not nxt or nxt.value().at >= end:
                break
            var tr = nxt.value().copy()
            assert_true(
                g < len(goldens) and goldens[g].zone == name,
                name + ": a change zdump does not have: " + show_transition(tr),
            )
            assert_true(
                goldens[g].matches(tr),
                name + ": got " + show_transition(tr) + ", zdump has " + goldens[g].show(),
            )
            g += 1
            found += 1
            t = tr.at
        if g < len(goldens):
            assert_true(
                goldens[g].zone != name,
                name + ": zdump has a change not found: " + goldens[g].show(),
            )
        if found > 0:
            zones_changing += 1
    assert_equal(g, len(goldens), "every footer golden line was matched in order")
    print(
        "  footer years: " + String(g) + " changes in " + String(zones_changing)
        + " zones match zdump"
    )


def _refused(dir: String, name: String, message: String) raises:
    var got = String()
    try:
        _ = load_zone(dir, name)
    except e:
        got = String(e)
    assert_equal(got, message)


def test_lookup_refusals() raises:
    var dir = zoneinfo_dir()
    _refused(
        dir,
        "Mars/Olympus_Mons",
        'unknown time zone "Mars/Olympus_Mons": no file of that name in the zoneinfo directory',
    )
    # A directory is not a zone.
    _refused(
        dir,
        "America",
        'unknown time zone "America": no file of that name in the zoneinfo directory',
    )
    _refused(dir, "../zones", 'time zone name "../zones": a . or .. component')
    _refused(dir, "America/./New_York", 'time zone name "America/./New_York": a . or .. component')
    _refused(dir, "/etc/localtime", 'time zone name "/etc/localtime": an empty component')
    _refused(dir, "America//New_York", 'time zone name "America//New_York": an empty component')
    _refused(dir, "America/", 'time zone name "America/": an empty component')
    _refused(dir, "", 'time zone name "": length 0 is outside 1..255')
    _refused(dir, "-x", 'time zone name "-x": a component starts with -')
    _refused(dir, "New York", 'time zone name "New York": byte 32 at 3 is not allowed')
    # Names of every shape the release uses pass the check.
    check_zone_name("America/Argentina/Buenos_Aires")
    check_zone_name("Etc/GMT+5")
    check_zone_name("Etc/GMT-14")
    check_zone_name("America/Port-au-Prince")
    check_zone_name("GMT0")


def main() raises:
    test_the_pin()
    test_every_zone_loads_and_its_footer_agrees()
    test_footer_years_match_zdump()
    test_lookup_refusals()
    print("all corpus tests passed")
