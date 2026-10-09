# =============================================================================
# test_zone_name.mojo -- the zone-name check that runs before a name becomes
# a path under the caller's zoneinfo directory
# =============================================================================

from std.testing import assert_equal

from komira_datetime import check_zone_name


def _refused(name: String, message: String) raises:
    var got = String()
    try:
        check_zone_name(name)
    except e:
        got = String(e)
    assert_equal(got, 'time zone name "' + name + '": ' + message)


def test_names_that_could_leave_the_directory() raises:
    _refused("..", "a . or .. component")
    _refused("../etc/passwd", "a . or .. component")
    _refused("America/../../etc", "a . or .. component")
    _refused(".", "a . or .. component")
    _refused("America/.", "a . or .. component")
    _refused("/etc/localtime", "an empty component")
    _refused("America//New_York", "an empty component")
    _refused("America/", "an empty component")


def test_other_shapes() raises:
    _refused("", "length 0 is outside 1..255")
    var long = String()
    for _ in range(256):
        long += "a"
    _refused(long, "length 256 is outside 1..255")
    _refused("-x", "a component starts with -")
    _refused("Etc/-x", "a component starts with -")
    _refused("New York", "byte 32 at 3 is not allowed")
    _refused("America\\New_York", "byte 92 at 7 is not allowed")
    _refused("Zone:1", "byte 58 at 4 is not allowed")


def test_the_shapes_the_release_uses() raises:
    check_zone_name("America/Argentina/Buenos_Aires")
    check_zone_name("Etc/GMT+5")
    check_zone_name("Etc/GMT-14")
    check_zone_name("America/Port-au-Prince")
    check_zone_name("GMT0")
    check_zone_name("..a")
    check_zone_name(".a")


def main() raises:
    test_names_that_could_leave_the_directory()
    test_other_shapes()
    test_the_shapes_the_release_uses()
    print("all zone-name tests passed")
