# =============================================================================
# src/kci_publish/release_version.mojo -- the `--release-version` file: what
#   the publish job derived for the release commit, read and checked.
# =============================================================================
#
# The file is the verbatim stdout of `tools/build/package/release_version.sh
# <release commit>`, run by the PUBLISH job at a clean full-history checkout.
# kci runs no git and no repo script: it ships, the job derives. The lines are
# `key=value`:
#
#   version=<the pinned Mojo compiler version>
#   build_number=<N, a decimal integer >= 0>
#   build=<the conda build string>
#   commit=<the release commit, 40 or 64 lowercase hex>
#   buck_args=<...>          ignored: a build-time stamp, not a publish input
#
# Refused, naming the file and the key: a line with no `=`, an unknown key, a
# key given twice, a missing key, an EMPTY value, a `build_number` that is not
# a decimal integer, a `commit` that is not lowercase hex of a commit's length.
# Blank lines (the trailing newline) are ignored.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.pathlib import Path


struct ReleaseVersion(Copyable, Movable):
    """The four values publish checks every member against.

    Layout: owned Strings and an Int. No pointer field."""

    var source: String
    var version: String
    var build_number: Int
    var build: String
    var commit: String

    def __init__(out self, var source: String):
        self.source = source^
        self.version = String("")
        self.build_number = -1
        self.build = String("")
        self.commit = String("")


def _refuse(source: String, why: String) raises:
    raise Error(String("release version '") + source + String("': ") + why)


def _is_lower_hex(s: String) -> Bool:
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        var digit = c >= UInt8(48) and c <= UInt8(57)
        var lower = c >= UInt8(97) and c <= UInt8(102)
        if not (digit or lower):
            return False
    return True


def _decimal(source: String, key: String, value: String) raises -> Int:
    var b = value.as_bytes()
    if len(b) == 0 or len(b) > 9 or (len(b) > 1 and b[0] == UInt8(48)):
        _refuse(source, key + String(" is not a decimal integer: '") + value + String("'"))
    var n = 0
    for i in range(len(b)):
        var c = b[i]
        if c < UInt8(48) or c > UInt8(57):
            _refuse(source, key + String(" is not a decimal integer: '") + value + String("'"))
        n = n * 10 + Int(c - UInt8(48))
    return n


def parse_release_version(text: String, source: String) raises -> ReleaseVersion:
    """Parse the file's text (see the file header). RAISES on the first
    refusal, naming `source`."""
    var rv = ReleaseVersion(source.copy())
    var seen = List[String]()
    var lines = text.split(String("\n"))
    for i in range(len(lines)):
        var line = String(lines[i])
        if line.byte_length() == 0:
            continue
        var eq = line.find(String("="))
        if eq <= 0:
            _refuse(source, String("line ") + String(i + 1) + String(" is not key=value: '") + line + String("'"))
        var key = String(line[byte=:eq])
        var value = String(line[byte = eq + 1 :])
        for j in range(len(seen)):
            if seen[j] == key:
                _refuse(source, key + String(" is given twice"))
        seen.append(key.copy())
        if key == String("buck_args"):
            continue
        if value.byte_length() == 0:
            _refuse(source, key + String(" is EMPTY"))
        if key == String("version"):
            rv.version = value^
        elif key == String("build_number"):
            rv.build_number = _decimal(source, key, value)
        elif key == String("build"):
            rv.build = value^
        elif key == String("commit"):
            var n = value.byte_length()
            if not ((n == 40 or n == 64) and _is_lower_hex(value)):
                _refuse(
                    source,
                    String("commit is not 40 or 64 lowercase hex characters: '")
                    + value
                    + String("'"),
                )
            rv.commit = value^
        else:
            _refuse(
                source,
                String("unknown key '")
                + key
                + String("' (known: version, build_number, build, commit, buck_args)"),
            )
    var missing = List[String]()
    if rv.version.byte_length() == 0:
        missing.append(String("version"))
    if rv.build_number < 0:
        missing.append(String("build_number"))
    if rv.build.byte_length() == 0:
        missing.append(String("build"))
    if rv.commit.byte_length() == 0:
        missing.append(String("commit"))
    if len(missing) > 0:
        _refuse(source, String("missing key(s): ") + String(", ").join(missing))
    return rv^


def read_release_version(path: String) raises -> ReleaseVersion:
    """Read and parse the `--release-version` file at `path`."""
    var text: String
    try:
        text = Path(path).read_text()
    except e:
        raise Error(String("release version '") + path + String("' cannot be read: ") + String(e))
    return parse_release_version(text, path)
