"""The ratchet: per-package coverage floors that may only rise.

The file (ratchet.tsv): lines starting with `#` are comments; every other
line is a row `<package>\\t<line floor>\\t<branch floor>`, floors in basis
points (0 to 10000), the branch floor `-` when the package has none, or a
pinned row with a fourth field, its reason (`\\t<reason>`): a floor set by
hand below what was measured (a line run only on some runs, say), which the
proposal keeps as written. Rows are sorted by package in byte order, each
package once.

Refused, naming `<origin>:<line>`: a carriage return, an empty line, a row
with another number of fields, a pinned row with an empty reason, an empty package, a floor that is not a
number from 0 to 10000 (or `-` for the branch floor), a row out of order
and a repeated package.

Comparing measured packages with the rows gives, per package:
`Regression` (a measured value below its floor, or a floor above 0 whose
value was not measured: no line record and no exempted line for a line
floor, no branch record for a branch floor; `measured` is then -1),
`MissingRow` (lines were measured and the file has no row),
`BranchFloorMissing` (branches were measured and the row's branch floor is
`-`); and per row, `ExtraRow` (the row's package has no BUCK file in the
repository) and, when every row is compared, `Regression` for a row whose
package has a BUCK file and a floor above 0 but no data at all (its report
or its tests were removed). A floor can therefore not be escaped by
dropping the data. The gate (not every row) finds no unmeasured floor for
its package when the package has no executable line and no exempted one:
the gate counts every source of its library, so that library has nothing to
cover (one whose sources are all generated, next to another library of the
same directory whose numbers set the row). A value above its floor is no finding: the proposed
file raises the floor (`propose`).
"""

from covcheck.paths import RepoFiles
from covcheck.stats import (
    BRANCH_FLOOR_MISSING,
    EXTRA_ROW,
    MISSING_ROW,
    NO_FLOOR,
    REGRESSION,
    Finding,
    PackageStats,
)
from covcheck.text import bytes_less, has_byte, parse_count, render_bp, split_lines, split_on


struct Row(Copyable, Movable):
    var package: String
    var line_floor: Int
    var branch_floor: Int
    # Empty, or the reason of a pinned row.
    var reason: String

    def __init__(out self, package: String, line_floor: Int, branch_floor: Int, reason: String = String("")):
        self.package = package
        self.line_floor = line_floor
        self.branch_floor = branch_floor
        self.reason = reason


struct Ratchet(Copyable, Movable):
    """The comment lines of the file, in order, and its rows."""

    var comments: List[String]
    var rows: List[Row]

    def __init__(out self):
        self.comments = List[String]()
        self.rows = List[Row]()

    def find(self, package: String) -> Int:
        """The index of `package`'s row, or -1."""
        for i in range(len(self.rows)):
            if self.rows[i].package == package:
                return i
        return -1


def _fail(origin: String, line_no: Int, why: String) raises:
    raise Error(origin + String(":") + String(line_no) + String(": ") + why)


def _floor(origin: String, line_no: Int, field: String, what: String) raises -> Int:
    var v = parse_count(field)
    if v < 0 or v > 10000:
        _fail(origin, line_no, what + String(" '") + field + String("' is not a number of basis points from 0 to 10000"))
    return v


def parse_ratchet(text: String, origin: String) raises -> Ratchet:
    var r = Ratchet()
    var lines = split_lines(text)
    for i in range(len(lines)):
        var n = i + 1
        var line = lines[i]
        if has_byte(line, 13):
            _fail(origin, n, String("carriage return (the file must use LF line ends)"))
        if line.startswith("#"):
            r.comments.append(line)
            continue
        if line.byte_length() == 0:
            _fail(origin, n, String("an empty line (a comment starts with '#')"))
        var f = split_on(line, 9)
        if len(f) != 3 and len(f) != 4:
            _fail(origin, n, String("a row has 3 tab-separated fields (package, line floor, branch floor), or 4 (a pinned row's reason), not ") + String(len(f)))
        var reason = String("")
        if len(f) == 4:
            reason = f[3]
            if reason.byte_length() == 0:
                _fail(origin, n, String("a pinned row has an empty reason"))
        if f[0].byte_length() == 0:
            _fail(origin, n, String("an empty package"))
        var lf = _floor(origin, n, f[1], String("line floor"))
        var bf = NO_FLOOR
        if f[2] != String("-"):
            bf = _floor(origin, n, f[2], String("branch floor"))
        if len(r.rows) > 0:
            var prev = r.rows[len(r.rows) - 1].package
            if prev == f[0]:
                _fail(origin, n, String("package ") + f[0] + String(" has a second row"))
            if not bytes_less(prev, f[0]):
                _fail(origin, n, String("rows are not sorted: ") + f[0] + String(" after ") + prev)
        r.rows.append(Row(f[0], lf, bf, reason))
    return r^


def _bp(v: Int) -> String:
    return render_bp(v)


def _unmeasured(package: String, metric: String, floor: Int) -> Finding:
    return Finding(
        String(REGRESSION), package, metric, -1, floor, String(""), 0,
        metric + String(" was not measured; its floor is ") + _bp(floor),
    )


def compare(r: Ratchet, packages: List[PackageStats], repo: RepoFiles, all_rows: Bool) -> List[Finding]:
    """The ratchet findings of the `packages` (sorted by package), then the
    rows': `ExtraRow` for a row whose package has no BUCK file and, when
    `all_rows`, `Regression` for a row with a floor above 0 whose package
    has a BUCK file but is not in `packages`. Without `all_rows` (the gate)
    only the rows of `packages` are checked."""
    var out = List[Finding]()
    for i in range(len(packages)):
        ref p = packages[i]
        var lbp = p.line_bp()
        var bbp = p.branch_bp()
        var k = r.find(p.package)
        if k < 0:
            if lbp >= 0:
                out.append(Finding(
                    String(MISSING_ROW), p.package, String("line"), lbp, -1, String(""), 0,
                    String("no ratchet row; measured line ") + _bp(lbp),
                ))
            continue
        ref row = r.rows[k]
        # The gate counts every source of its library: no line, nothing to cover.
        var nothing = not all_rows and p.line_found == 0 and p.exempt_lines == 0
        if lbp >= 0 and lbp < row.line_floor:
            out.append(Finding(
                String(REGRESSION), p.package, String("line"), lbp, row.line_floor, String(""), 0,
                String("line ") + _bp(lbp) + String(" is below its floor ") + _bp(row.line_floor),
            ))
        elif lbp < 0 and p.exempt_lines == 0 and row.line_floor > 0 and not nothing:
            out.append(_unmeasured(p.package, String("line"), row.line_floor))
        if bbp < 0 and row.branch_floor > 0 and not nothing:
            out.append(_unmeasured(p.package, String("branch"), row.branch_floor))
        if bbp >= 0:
            if row.branch_floor == NO_FLOOR:
                out.append(Finding(
                    String(BRANCH_FLOOR_MISSING), p.package, String("branch"), bbp, -1, String(""), 0,
                    String("branch ") + _bp(bbp) + String(" is measured and the row's branch floor is '-'"),
                ))
            elif bbp < row.branch_floor:
                out.append(Finding(
                    String(REGRESSION), p.package, String("branch"), bbp, row.branch_floor, String(""), 0,
                    String("branch ") + _bp(bbp) + String(" is below its floor ") + _bp(row.branch_floor),
                ))
    for i in range(len(r.rows)):
        ref row = r.rows[i]
        var measured = False
        for j in range(len(packages)):
            if packages[j].package == row.package:
                measured = True
        if not all_rows and not measured:
            continue
        if not repo.has_buck(row.package):
            out.append(Finding(
                String(EXTRA_ROW), row.package, String(""), -1, -1, String(""), 0,
                String("the ratchet has a row for a directory with no BUCK file"),
            ))
        elif not measured:
            if row.line_floor > 0:
                out.append(_unmeasured(row.package, String("line"), row.line_floor))
            if row.branch_floor > 0:
                out.append(_unmeasured(row.package, String("branch"), row.branch_floor))
    return out^


def propose(r: Ratchet, packages: List[PackageStats], repo: RepoFiles) -> Ratchet:
    """The ratchet with every floor raised to what was measured (a pinned
    row kept as written), a row for
    every measured package that had none, and no row for a package without
    a BUCK file. Rows sorted by package."""
    var out = Ratchet()
    out.comments = r.comments.copy()
    var i = 0
    var j = 0
    # Both lists are sorted by package: merge them.
    while i < len(r.rows) or j < len(packages):
        var take_row: Bool
        var take_pkg: Bool
        if i >= len(r.rows):
            take_row = False
            take_pkg = True
        elif j >= len(packages):
            take_row = True
            take_pkg = False
        elif r.rows[i].package == packages[j].package:
            take_row = True
            take_pkg = True
        else:
            take_row = bytes_less(r.rows[i].package, packages[j].package)
            take_pkg = not take_row
        if take_row and take_pkg:
            ref row = r.rows[i]
            ref p = packages[j]
            if row.reason.byte_length() > 0:
                if repo.has_buck(row.package):
                    out.rows.append(row.copy())
                i += 1
                j += 1
                continue
            var lf = max(row.line_floor, p.line_bp())
            var bf = row.branch_floor
            if p.branch_bp() >= 0:
                bf = max(bf, p.branch_bp())
            if repo.has_buck(row.package):
                out.rows.append(Row(row.package, lf, bf))
            i += 1
            j += 1
        elif take_row:
            if repo.has_buck(r.rows[i].package):
                out.rows.append(r.rows[i].copy())
            i += 1
        else:
            ref p = packages[j]
            if p.line_bp() >= 0:
                out.rows.append(Row(p.package, p.line_bp(), p.branch_bp() if p.branch_bp() >= 0 else NO_FLOOR))
            j += 1
    return out^


def render_ratchet(r: Ratchet) -> String:
    """The file's text: the comment lines, then the rows."""
    var out = String("")
    for i in range(len(r.comments)):
        out += r.comments[i] + String("\n")
    for i in range(len(r.rows)):
        ref row = r.rows[i]
        out += row.package + String("\t") + String(row.line_floor) + String("\t")
        out += String("-") if row.branch_floor == NO_FLOOR else String(row.branch_floor)
        if row.reason.byte_length() > 0:
            out += String("\t") + row.reason
        out += String("\n")
    return out^
