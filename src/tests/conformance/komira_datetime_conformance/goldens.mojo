# =============================================================================
# goldens.mojo -- the pinned tz release and zdump's reading of it, as data
# =============================================================================
#
# Where a test finds things (its test_data, BUCK):
#   tzdata/src/tzdata/zoneinfo/<zone>  the pinned TZif files
#   tzdata/src/tzdata/zones            the package's list of zone names
#   goldens/named.txt                  zdump -v, the plan's zones, 1800..2100
#   goldens/footer.txt                 zdump -v, every zone, UT years 2037..2040
#
# A golden line is one change of local time (regen_goldens.sh):
#   <zone> <utc seconds> <offset before> <isdst before> <abbr before>
#          <offset after> <isdst after> <abbr after>
# =============================================================================

from std.pathlib import Path

from komira_runtime_paths import data_path
from komira_datetime import Transition, ZoneOffset

comptime ZONEINFO_DATA_DIR = "tzdata/src/tzdata/zoneinfo"
comptime ZONES_LIST = "tzdata/src/tzdata/zones"
comptime NAMED_GOLDENS = "goldens/named.txt"
comptime FOOTER_GOLDENS = "goldens/footer.txt"

# The pinned release (third_party/tzdata/BUCK): its IANA version and its
# number of zone names. A new pin changes both, and the goldens with them.
comptime IANA_VERSION_LINE = "# version 2026e"
comptime ZONE_COUNT = 598


@fieldwise_init
struct GoldenChange(Copyable, Movable):
    """One golden line."""

    var zone: String
    var at: Int
    var before: ZoneOffset
    var after: ZoneOffset

    def matches(self, t: Transition) -> Bool:
        return t.at == self.at and t.before == self.before and t.after == self.after

    def show(self) -> String:
        return (
            self.zone + " " + String(self.at) + " " + _show(self.before) + " -> "
            + _show(self.after)
        )


def _show(o: ZoneOffset) -> String:
    return o.abbreviation + "(" + String(o.utc_offset) + (" dst)" if o.is_dst else ")")


def show_transition(t: Transition) -> String:
    """A transition in the form `GoldenChange.show` writes, for messages."""
    return String(t.at) + " " + _show(t.before) + " -> " + _show(t.after)


def zoneinfo_dir() raises -> String:
    """The extracted zoneinfo tree beside the test executable."""
    return data_path(ZONEINFO_DATA_DIR)


def _int(word: String, line: String) raises -> Int:
    var b = word.as_bytes()
    var n = len(b)
    var i = 0
    var sign = 1
    if n > 0 and Int(b[0]) == ord("-"):
        sign = -1
        i = 1
    if i >= n:
        raise Error("golden line `" + line + "`: `" + word + "` is not an integer")
    var v = 0
    while i < n:
        var c = Int(b[i])
        if c < ord("0") or c > ord("9"):
            raise Error("golden line `" + line + "`: `" + word + "` is not an integer")
        v = v * 10 + (c - ord("0"))
        i += 1
    return sign * v


def _words(line: String) -> List[String]:
    var out = List[String]()
    var cur = String()
    var b = line.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c == ord(" ") or c == ord("\t"):
            if cur.byte_length() > 0:
                out.append(cur.copy())
                cur = String()
        else:
            cur += chr(c)
    if cur.byte_length() > 0:
        out.append(cur^)
    return out^


def read_lines(rel: String) raises -> List[String]:
    """The lines of a declared data file that are neither empty nor `#`
    comments."""
    var text = Path(data_path(rel)).read_text()
    var out = List[String]()
    var parts = text.split("\n")
    for i in range(len(parts)):
        var line = String(parts[i])
        if line.byte_length() == 0 or line.startswith("#"):
            continue
        out.append(line^)
    return out^


def read_goldens(rel: String) raises -> List[GoldenChange]:
    """Every line of a goldens file, in file order."""
    var out = List[GoldenChange]()
    var lines = read_lines(rel)
    for ref line in lines:
        var w = _words(line)
        if len(w) != 8:
            raise Error("golden line `" + line + "`: not 8 fields")
        out.append(
            GoldenChange(
                w[0].copy(),
                _int(w[1], line),
                ZoneOffset(_int(w[2], line), _int(w[3], line) == 1, w[4].copy()),
                ZoneOffset(_int(w[5], line), _int(w[6], line) == 1, w[7].copy()),
            )
        )
    return out^


def first_line(rel: String) raises -> String:
    """The first line of a declared data file."""
    var text = Path(data_path(rel)).read_text()
    var at = text.find("\n")
    if at < 0:
        return text
    return String(text[byte=0:at])
