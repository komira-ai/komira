"""The Markdown summary: the check run's `output.summary`, `--summary-out`.

Sections, in order: the title line (total line and branch coverage, and the
changed lines' coverage), the caveat on what line coverage counts, the mode
and target, the annotations the check run left out (when it left any out),
a table of every measured package (touched packages first, each
group sorted; in a report, then a total row), the findings, the information
of test-only packages (when one was measured with a finding; analyze.mojo,
step 8), the exemptions (each needs approval), the
changed lines (informational; at most 200 uncovered ranges are listed, the
rest are counted: the --annotations-out file lists them all) and what was set aside.

GitHub refuses a summary over 65535 characters: `truncate_summary` cuts
the text at a line end and says how many bytes were left out.
"""

from covcheck.analyze import Analysis
from covcheck.annotate import DiffCoverage
from covcheck.stats import BELOW_TARGET, MODE_CENSUS, Finding, PackageStats
from covcheck.text import basis_points, render_bp, render_bp_or_na

comptime MAX_SUMMARY: Int = 65535
comptime MAX_RANGES: Int = 200

comptime CAVEAT = "Line coverage counts the lines the compiler emitted code for, and every executable line of a package's source file that no test binary compiled (`UnmeasuredFile`). Still missing: a function no test reaches inside a compiled file emits no lines at all, so these numbers are upper bounds; the result JSON lists the functions none of whose lines has a record (`unrecorded_functions`) without counting them."


def md_code(s: String) -> String:
    """`s` as a Markdown code span that is safe in a table cell."""
    var body = s.replace("|", "\\|")
    if body.find("`") >= 0:
        return String("`` ") + body + String(" ``")
    return String("`") + body + String("`")


def _ratio(hit: Int, found: Int) -> String:
    """`87.34% (hit/found)`, or `n/a`."""
    if found <= 0:
        return String("n/a")
    return render_bp(basis_points(hit, found)) + String(" (") + String(hit) + String("/") + String(found) + String(")")


def _branch_ratio(hit: Int, found: Int) -> String:
    """`_ratio` of branches, `not measured` when none was found: no report
    gave a branch record (kcov's Cobertura has none), which is not 100%."""
    if found <= 0:
        return String("not measured")
    return _ratio(hit, found)


def _floor(p: PackageStats) -> String:
    if not p.has_row:
        return String("-")
    return render_bp(p.line_floor) + String(" / ") + (render_bp(p.branch_floor) if p.branch_floor >= 0 else String("-"))


def _mutants(p: PackageStats) -> String:
    if p.mutants == 0:
        return String("-")
    var s = String(p.killed) + String("/") + String(p.mutants)
    if p.timeout > 0 or p.error > 0:
        s += String(" (") + String(p.timeout) + String(" timeout, ") + String(p.error) + String(" error)")
    return s^


def _kinds(fs: List[Finding], package: String) -> String:
    """The kinds of `package`'s findings in `fs`, each once, or empty."""
    var kinds = List[String]()
    for i in range(len(fs)):
        if fs[i].package != package:
            continue
        var seen = False
        for k in range(len(kinds)):
            if kinds[k] == fs[i].kind:
                seen = True
        if not seen:
            kinds.append(fs[i].kind)
    var s = String("")
    for k in range(len(kinds)):
        if k > 0:
            s += String(", ")
        s += kinds[k]
    return s^


def _status(a: Analysis, package: String) -> String:
    """`ok` or the kinds of its findings; for a test-only package `info`,
    with the kinds of its information."""
    if _is_in(a.info_packages, package):
        var k = _kinds(a.info_findings, package)
        return String("info") if k.byte_length() == 0 else String("info: ") + k
    var k = _kinds(a.findings, package)
    return String("ok") if k.byte_length() == 0 else k


def _finding_line(f: Finding, census: Bool) -> String:
    """One finding as a list item; `census` tags a BelowTarget."""
    var s = String("- **") + f.kind + String("**")
    if f.kind == String(BELOW_TARGET) and census:
        s += String(" (census)")
    s += String(" ") + md_code(f.package)
    if f.path.byte_length() > 0 and f.line > 0:
        s += String(" ") + md_code(f.path + String(":") + String(f.line))
    elif f.path.byte_length() > 0:
        s += String(" ") + md_code(f.path)
    return s + String(": ") + f.message + String("\n")


def _row(a: Analysis, p: PackageStats, touched: Bool) -> String:
    var name = md_code(p.package) + (String(" (touched)") if touched else String(""))
    return (
        String("| ") + name + String(" | ") + _ratio(p.line_hit, p.line_found) + String(" | ")
        + _branch_ratio(p.branch_hit, p.branch_found) + String(" | ") + _mutants(p) + String(" | ")
        + _floor(p) + String(" | ") + _status(a, p.package) + String(" |\n")
    )


def _is_in(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def render_summary(
    a: Analysis, touched: List[String], d: DiffCoverage, with_diff: Bool, scope: String, note: String = String("")
) -> String:
    """The summary of `a`. `scope` names what was measured in the title
    (empty: every package); without `with_diff` there is no changed-lines
    section (the build gate has no change); a `note` (the annotations the
    check run leaves out) is a paragraph after the mode, so truncation
    never cuts it."""
    var s = String("## Coverage")
    if scope.byte_length() > 0:
        s += String(" of ") + md_code(scope)
    s += String(": line ") + _ratio(a.total.line_hit, a.total.line_found)
    s += String(", branch ") + _branch_ratio(a.total.branch_hit, a.total.branch_found)
    if with_diff:
        s += String("; changed lines ") + _ratio(d.covered, d.covered + d.uncovered)
    s += String("\n\n") + String(CAVEAT) + String("\n\n")
    s += String("Mode: **") + a.mode + String("**, conclusion **") + a.conclusion + String("**. Target: ")
    s += render_bp(a.target_bp) + String(" line and branch coverage per package")
    if len(a.info_dirs) > 0:
        s += String(", except a test-only package (")
        for i in range(len(a.info_dirs)):
            if i > 0:
                s += String(", ")
            s += md_code(a.info_dirs[i])
        s += String(" and under): measured and shown, held to no target, its findings information that never fails")
    s += String(".\n\n")
    if note.byte_length() > 0:
        s += String("**Annotations**: ") + note + String(".\n\n")

    s += String("### Packages\n\n")
    if len(a.packages) == 0:
        s += String("No package was measured.\n\n")
    else:
        s += String("| package | line % (hit/found) | branch % (hit/found) | mutants killed/total | floor line / branch | status |\n")
        s += String("|---|---|---|---|---|---|\n")
        for i in range(len(a.packages)):
            if _is_in(touched, a.packages[i].package):
                s += _row(a, a.packages[i], True)
        for i in range(len(a.packages)):
            if not _is_in(touched, a.packages[i].package):
                s += _row(a, a.packages[i], False)
        if scope.byte_length() == 0:
            s += String("| **total** | ") + _ratio(a.total.line_hit, a.total.line_found) + String(" | ")
            s += _branch_ratio(a.total.branch_hit, a.total.branch_found) + String(" | ") + _mutants(a.total) + String(" | - | - |\n")
        s += String("\n")

    s += String("### Findings (") + String(len(a.findings)) + String(")\n\n")
    if len(a.findings) == 0:
        s += String("None.\n\n")
    else:
        for i in range(len(a.findings)):
            s += _finding_line(a.findings[i], a.mode == String(MODE_CENSUS))
        s += String("\n")
    if len(a.info_findings) > 0:
        s += String("### Info: test-only packages, declaration-only files (") + String(len(a.info_findings)) + String(")\n\n")
        s += String("What the policy would find in a package held to no target, and files no test compiled that emit no code; none of it counts.\n\n")
        for i in range(len(a.info_findings)):
            s += _finding_line(a.info_findings[i], False)
        s += String("\n")

    s += String("### Exemptions (need approval) (") + String(len(a.exemptions)) + String(")\n\n")
    if len(a.exemptions) == 0:
        s += String("None.\n\n")
    else:
        for i in range(len(a.exemptions)):
            ref e = a.exemptions[i]
            s += String("- ") + md_code(e.path + String(":") + String(e.line)) + String(" (") + e.status + String("): ")
            s += (e.reason if e.reason.byte_length() > 0 else String("(no reason given)")) + String("\n")
        s += String("\n")

    if with_diff:
        s += String("### Changed lines (informational)\n\n")
        s += String("Covered ") + String(d.covered) + String(", uncovered ") + String(d.uncovered)
        s += String(", not instrumented ") + String(d.not_instrumented) + String(", exempt ") + String(d.exempt) + String(".\n\n")
        if len(d.ranges) > 0:
            s += String("Uncovered changed lines:\n\n")
            var shown = min(len(d.ranges), MAX_RANGES)
            var i = 0
            while i < shown:
                var path = d.ranges[i].path
                s += String("- ") + md_code(path) + String(": ")
                var first = True
                while i < shown and d.ranges[i].path == path:
                    if not first:
                        s += String(", ")
                    first = False
                    s += String(d.ranges[i].start)
                    if d.ranges[i].end != d.ranges[i].start:
                        s += String("-") + String(d.ranges[i].end)
                    i += 1
                s += String("\n")
            if len(d.ranges) > shown:
                s += String("- and ") + String(len(d.ranges) - shown) + String(" more ranges, omitted here (the --annotations-out file lists every one)\n")
            s += String("\n")

    s += String("### Set aside\n\n")
    s += String("- ") + String(a.ignored_files) + String(" report files outside the repository (the Mojo standard library, other code not in the repository)\n")
    s += String("- ") + String(a.excluded_test_files) + String(" test source files (`<package>/tests/` and each `--test-source`; `--include-tests` counts them)\n")
    s += String("- ") + String(a.ignored_mutants) + String(" mutants outside the repository, ") + String(a.excluded_test_mutants) + String(" in test sources\n")
    return s^


def truncate_summary(s: String, limit: Int = MAX_SUMMARY) -> String:
    """`s` when it fits in `limit` bytes; else `s` cut at the last line end
    that leaves room for a closing line saying how many bytes were left
    out. The same text always gives the same result."""
    var n = s.byte_length()
    if n <= limit:
        return s
    var cut = max(limit - 200, 0)
    var b = s.as_bytes()
    var at = cut
    while at > 0 and b[at - 1] != UInt8(10):
        at -= 1
    if at > 0:
        cut = at
    else:
        # No line end: cut inside a UTF-8 sequence never.
        while cut > 0 and (Int(b[cut]) & 0xC0) == 0x80:
            cut -= 1
    return String(s[byte=0:cut]) + String("\n**Summary truncated**: ") + String(n - cut) + String(
        " bytes left out; the full summary is the --summary-out file; the result JSON holds every number.\n"
    )
