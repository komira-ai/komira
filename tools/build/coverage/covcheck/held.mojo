"""The holds: the metrics a package keeps at the target once it reached it.

A package's marker is `<package>/coverage_held` (README.md, "The 99%
threshold and holds"): lines starting with `#` are comments; every other line
names one metric the package holds, `line` or `branch`, with nothing else on
it (no number: the target is policy.bzl's, one for every package). A marker
with no metric line holds nothing. A held metric below the target, or not
measured, is a `Regression` (analyze.mojo, step 7), which fails the gate in
every mode; a metric not held below the target is `BelowTarget`, which
fails only in enforce mode.

Refused, naming `<origin>:<line>`: a carriage return, an empty line, a line
that is not exactly `line` or `branch` (a number, a second word, a
misspelling), a metric named twice, and a held metric of a test-only
package (one of `--info-package`'s directories or under one, which is held
to no target; a marker of it that holds nothing, the gate's default, is
accepted).
"""

from covcheck.stats import is_info_package
from covcheck.text import has_byte, split_lines


struct Hold(Copyable, Movable):
    """The metrics one package holds."""

    var line: Bool
    var branch: Bool

    def __init__(out self):
        self.line = False
        self.branch = False


struct Held(Copyable, Movable):
    """The holds of the packages given one (`--held`), by package."""

    var packages: Dict[String, Hold]

    def __init__(out self):
        self.packages = Dict[String, Hold]()

    def line(self, package: String) -> Bool:
        if package in self.packages:
            return self.packages.get(package, Hold()).line
        return False

    def branch(self, package: String) -> Bool:
        if package in self.packages:
            return self.packages.get(package, Hold()).branch
        return False


def _fail(origin: String, line_no: Int, why: String) raises:
    raise Error(origin + String(":") + String(line_no) + String(": ") + why)


def parse_hold(text: String, origin: String, package: String, info_dirs: List[String]) raises -> Hold:
    """The metrics of `package`'s marker `text` (read from `origin`)."""
    var h = Hold()
    var lines = split_lines(text)
    for i in range(len(lines)):
        var n = i + 1
        var l = lines[i]
        if has_byte(l, 13):
            _fail(origin, n, String("carriage return (the file must use LF line ends)"))
        if l.startswith("#"):
            continue
        if l.byte_length() == 0:
            _fail(origin, n, String("an empty line (a comment starts with '#')"))
        var seen: Bool
        if l == String("line"):
            seen = h.line
            h.line = True
        elif l == String("branch"):
            seen = h.branch
            h.branch = True
        else:
            _fail(origin, n, String("'") + l + String("' is not a held metric: a line holds exactly `line` or `branch`, with no number"))
            seen = False
        if seen:
            _fail(origin, n, l + String(" is held twice"))
        if is_info_package(package, info_dirs):
            _fail(origin, n, package + String(" is a test-only package (--info-package), held to no target: it holds no metric"))
    return h^


def add_hold(mut held: Held, package: String, text: String, origin: String, info_dirs: List[String]) raises:
    """Adds `package`'s marker to `held`; a package given two is refused."""
    if package in held.packages:
        raise Error(origin + String(": a second coverage_held for ") + package)
    held.packages[package] = parse_hold(text, origin, package, info_dirs)
