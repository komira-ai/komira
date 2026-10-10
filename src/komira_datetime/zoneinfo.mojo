# =============================================================================
# zoneinfo.mojo -- a zone by IANA name from a zoneinfo directory
# =============================================================================
#
# A zoneinfo directory holds one TZif file per zone name, at the name's path
# (`America/New_York`), as zic writes it. The caller names the directory;
# this module bundles no zone data and reads no environment variable.
#
# A zone name is checked before it becomes a path, so a name cannot leave the
# directory: 1..255 bytes of `/`-separated components, each non-empty, not
# `.` or `..`, not starting with `-`, of letters, digits, `.`, `_`, `+` and
# `-` (the characters the tz database's names use).
# =============================================================================

from std.os.path import isfile
from std.pathlib import Path

from .tzif import parse_tzif
from .zone import Zone


def check_zone_name(name: String) raises:
    """Raises unless `name` has the shape of a tz database name (module
    header)."""
    var n = name.byte_length()
    if n == 0 or n > 255:
        raise Error(
            'time zone name "' + name + '": length ' + String(n) + " is outside 1..255"
        )
    var b = name.as_bytes()
    var start = 0
    for i in range(n + 1):
        if i < n and Int(b[i]) != ord("/"):
            var c = Int(b[i])
            var ok = (
                (c >= ord("A") and c <= ord("Z"))
                or (c >= ord("a") and c <= ord("z"))
                or (c >= ord("0") and c <= ord("9"))
                or c == ord(".")
                or c == ord("_")
                or c == ord("+")
                or c == ord("-")
            )
            if not ok:
                raise Error(
                    'time zone name "' + name + '": byte ' + String(c)
                    + " at " + String(i) + " is not allowed"
                )
            continue
        var len_c = i - start
        if len_c == 0:
            raise Error('time zone name "' + name + '": an empty component')
        if Int(b[start]) == ord("-"):
            raise Error('time zone name "' + name + '": a component starts with -')
        if Int(b[start]) == ord(".") and (
            len_c == 1 or (len_c == 2 and Int(b[start + 1]) == ord("."))
        ):
            raise Error('time zone name "' + name + '": a . or .. component')
        start = i + 1


def load_zone(zoneinfo_dir: String, name: String) raises -> Zone:
    """The zone `name` read from `<zoneinfo_dir>/<name>`. Raises for a name
    of the wrong shape, an unknown zone (no such file) and a file that is
    not valid TZif."""
    check_zone_name(name)
    var path = zoneinfo_dir + "/" + name
    if not isfile(path):
        raise Error(
            'unknown time zone "' + name + '": no file of that name in the zoneinfo directory'
        )
    var data = Path(path).read_bytes()
    return parse_tzif(Span(data), name)
