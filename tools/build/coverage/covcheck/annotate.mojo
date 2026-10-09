"""What the PR check adds to `analyze`: the packages a change touches, the
coverage of its changed lines (informational), and the annotations.

Touched packages: the package of every path the diff names (old and new
paths; a path with no BUCK file above it and none at the top touches
nothing), kept when the run measured it.

Diff coverage counts the changed lines of every changed file that is in a
measured package, is not a left-out test source, and whose extension is one
of the measured files' (so a README in a package is not counted): a line
with a record is covered (hits > 0) or uncovered, a line an exemption
removed is exempt, any other line is not instrumented and never counted as
covered. A file of a measured package that no report names has a record
(0 hits) for each of its executable lines (see analyze.mojo), so its
changed executable lines are uncovered and its other changed lines not
instrumented. Uncovered changed lines
are merged into ranges where their numbers are consecutive.

Annotations cover every measured file of every touched package, the changed
files first (each group by path, then line):

- `Line not covered`: a run of uncovered lines, merged while no covered or
  exempt line comes between them (lines with no record do not break a run);
- `File not compiled into any test`: in a file no report names, one per
  run of consecutive executable lines (a blank, comment, docstring or
  import line, or an exempt line, breaks a run);
- `Branch not covered`: a line some of whose branches were never taken,
  `k of n branches taken on this line`;
- `Mutant survived`: one per surviving mutant;
- `Coverage exemption` (level `notice`): one per marker.

Level `warning` in census and neutral mode, `failure` in enforce mode;
`notice` in every mode for a file of a test-only package (`--info-package`,
analyze.mojo step 8), whose findings are information.

The list can be long (a package's first run, a file nobody tests), so the
check run carries at most `--max-annotations` of them (`cap_annotations`):
the first ones in this order, which is why changed files come first: the
cap must never empty the "Files changed" view, where a reviewer reads the
annotations. The full list can be written apart (`annotations_json`).
"""

from covcheck.analyze import Analysis
from covcheck.diff import Diff
from covcheck.jsonw import JsonOut
from covcheck.exempt import STATUS_EXEMPT
from covcheck.model import FileCov, branch_line
from covcheck.mutants import SURVIVED
from covcheck.paths import RepoFiles, is_test_source, package_of
from covcheck.stats import MODE_ENFORCE, is_info_package
from covcheck.text import line_key, pad_int, sort_by_keys, sort_ints, sort_strings, suffix

comptime TITLE_LINE = "Line not covered"
comptime TITLE_BRANCH = "Branch not covered"
comptime TITLE_MUTANT = "Mutant survived"
comptime TITLE_EXEMPTION = "Coverage exemption"
comptime TITLE_UNMEASURED = "File not compiled into any test"

comptime DEFAULT_MAX_ANNOTATIONS: Int = 1000


struct Annotation(Copyable, Movable):
    var path: String
    var start_line: Int
    var end_line: Int
    var level: String
    var title: String
    var message: String

    def __init__(out self, path: String, start_line: Int, end_line: Int, level: String, title: String, message: String):
        self.path = path
        self.start_line = start_line
        self.end_line = end_line
        self.level = level
        self.title = title
        self.message = message


struct LineRange(Copyable, Movable):
    var start: Int
    var end: Int

    def __init__(out self, start: Int, end: Int):
        self.start = start
        self.end = end


struct PathRange(Copyable, Movable):
    var path: String
    var start: Int
    var end: Int

    def __init__(out self, path: String, start: Int, end: Int):
        self.path = path
        self.start = start
        self.end = end


struct DiffCoverage(Copyable, Movable):
    var covered: Int
    var uncovered: Int
    var not_instrumented: Int
    var exempt: Int
    var ranges: List[PathRange]

    def __init__(out self):
        self.covered = 0
        self.uncovered = 0
        self.not_instrumented = 0
        self.exempt = 0
        self.ranges = List[PathRange]()


def merge_consecutive(lines: List[Int]) -> List[LineRange]:
    """Ascending `lines` as ranges of consecutive numbers."""
    var out = List[LineRange]()
    for i in range(len(lines)):
        var n = len(out)
        if n > 0 and out[n - 1].end + 1 == lines[i]:
            out[n - 1].end = lines[i]
        else:
            out.append(LineRange(lines[i], lines[i]))
    return out^


def _exempt_lines(a: Analysis, path: String) -> List[Int]:
    var out = List[Int]()
    for i in range(len(a.exemptions)):
        if a.exemptions[i].path == path and a.exemptions[i].status == String(STATUS_EXEMPT):
            out.append(a.exemptions[i].line)
    return out^


def uncovered_ranges(f: FileCov, exempt: List[Int]) -> List[LineRange]:
    """The uncovered lines of `f` as runs: a run continues while no covered
    or `exempt` line comes between two uncovered lines."""
    var all = f.lines()
    for i in range(len(exempt)):
        all.append(exempt[i])
    sort_ints(all)
    var out = List[LineRange]()
    var open = False
    for i in range(len(all)):
        var ln = all[i]
        var uncovered = ln in f.hits and f.hits.get(ln, 1) == 0
        if uncovered:
            if open:
                out[len(out) - 1].end = ln
            else:
                out.append(LineRange(ln, ln))
                open = True
        else:
            open = False
    return out^


def _extension(path: String) -> String:
    var slash = path.rfind("/")
    var dot = path.rfind(".")
    if dot <= slash + 1:
        return String("")
    return suffix(path, dot)


def _package_or_empty(path: String, repo: RepoFiles) -> String:
    try:
        return package_of(path, repo)
    except:
        return String("")


def touched_packages(a: Analysis, d: Diff, repo: RepoFiles) -> List[String]:
    """The measured packages the diff names a path in, sorted."""
    var seen = Dict[String, Bool]()
    for i in range(len(d.paths)):
        var pkg = _package_or_empty(d.paths[i], repo)
        if pkg.byte_length() > 0 and a.package_index(pkg) >= 0:
            seen[pkg] = True
    var out = List[String]()
    for e in seen.items():
        out.append(e.key)
    sort_strings(out)
    return out^


def diff_coverage(a: Analysis, d: Diff, repo: RepoFiles, include_tests: Bool) raises -> DiffCoverage:
    var out = DiffCoverage()
    var exts = Dict[String, Bool]()
    for i in range(len(a.files)):
        exts[_extension(a.files[i].path)] = True
    var keys = List[String]()
    var ranges = List[PathRange]()
    for i in range(len(d.files)):
        ref cf = d.files[i]
        var pkg = _package_or_empty(cf.path, repo)
        if pkg.byte_length() == 0 or a.package_index(pkg) < 0:
            continue
        if not include_tests and is_test_source(cf.path, pkg):
            continue
        if _extension(cf.path) not in exts:
            continue
        var fi = a.file_index(cf.path)
        var exempt = _exempt_lines(a, cf.path)
        var missed = List[Int]()
        for k in range(len(cf.lines)):
            var ln = cf.lines[k]
            var is_exempt = False
            for x in range(len(exempt)):
                if exempt[x] == ln:
                    is_exempt = True
            if is_exempt:
                out.exempt += 1
            elif fi >= 0 and ln in a.files[fi].hits:
                if a.files[fi].hits[ln] > 0:
                    out.covered += 1
                else:
                    out.uncovered += 1
                    missed.append(ln)
            else:
                out.not_instrumented += 1
        sort_ints(missed)
        var rs = merge_consecutive(missed)
        for k in range(len(rs)):
            keys.append(line_key(cf.path, rs[k].start))
            ranges.append(PathRange(cf.path, rs[k].start, rs[k].end))
    var order = sort_by_keys(keys)
    for i in range(len(order)):
        out.ranges.append(ranges[order[i]].copy())
    return out^


def line_message(start: Int, end: Int) -> String:
    if start == end:
        return String("Line ") + String(start) + String(" is not executed by any test")
    return String("Lines ") + String(start) + String("-") + String(end) + String(" are not executed by any test")


def unmeasured_message(start: Int, end: Int) -> String:
    var tail = String(" in a file no test binary compiled, so not executed by any test")
    if start == end:
        return String("Line ") + String(start) + String(" is") + tail
    return String("Lines ") + String(start) + String("-") + String(end) + String(" are") + tail


def _file_annotations(a: Analysis, path: String, level: String) -> List[Annotation]:
    """The annotations of one file, by line (lines, then branches, mutants,
    exemptions on the same line)."""
    var anns = List[Annotation]()
    var keys = List[String]()
    var fi = a.file_index(path)
    if fi >= 0:
        ref f = a.files[fi]
        if a.unmeasured[fi]:
            var rs = merge_consecutive(f.lines())
            for k in range(len(rs)):
                keys.append(pad_int(rs[k].start, 12) + String("0"))
                anns.append(Annotation(path, rs[k].start, rs[k].end, level, String(TITLE_UNMEASURED), unmeasured_message(rs[k].start, rs[k].end)))
        else:
            var rs = uncovered_ranges(f, _exempt_lines(a, path))
            for k in range(len(rs)):
                keys.append(pad_int(rs[k].start, 12) + String("0"))
                anns.append(Annotation(path, rs[k].start, rs[k].end, level, String(TITLE_LINE), line_message(rs[k].start, rs[k].end)))
        var found = Dict[Int, Int]()
        var taken = Dict[Int, Int]()
        for e in f.branches.items():
            var ln = branch_line(e.key)
            found[ln] = found.get(ln, 0) + 1
            taken[ln] = taken.get(ln, 0) + (1 if e.value > 0 else 0)
        for e in found.items():
            var k = taken.get(e.key, 0)
            if k < e.value:
                keys.append(pad_int(e.key, 12) + String("1"))
                anns.append(Annotation(
                    path, e.key, e.key, level, String(TITLE_BRANCH),
                    String(k) + String(" of ") + String(e.value) + String(" branches taken on this line"),
                ))
    for i in range(len(a.mutants)):
        ref m = a.mutants[i]
        if m.path == path and m.status == String(SURVIVED):
            var msg = m.operator
            if m.description.byte_length() > 0:
                msg += String(": ") + m.description
            keys.append(pad_int(m.line, 12) + String("2"))
            anns.append(Annotation(path, m.line, m.line, level, String(TITLE_MUTANT), msg + String("; no test failed")))
    for i in range(len(a.exemptions)):
        ref e = a.exemptions[i]
        if e.path == path:
            var why = e.reason if e.reason.byte_length() > 0 else String("(no reason given)")
            keys.append(pad_int(e.line, 12) + String("3"))
            anns.append(Annotation(
                path, e.line, e.line, String("notice"), String(TITLE_EXEMPTION),
                String("Exempt from coverage (") + e.status + String("): ") + why + String(". Every exemption needs a reviewer's approval."),
            ))
    var order = sort_by_keys(keys)
    var out = List[Annotation]()
    for i in range(len(order)):
        out.append(anns[order[i]].copy())
    return out^


def annotations(a: Analysis, d: Diff, touched: List[String]) -> List[Annotation]:
    """Every annotation of the touched packages; see the module header."""
    var level = String("failure") if a.mode == String(MODE_ENFORCE) else String("warning")
    var is_touched = Dict[String, Bool]()
    for i in range(len(touched)):
        is_touched[touched[i]] = True
    var changed = Dict[String, Bool]()
    for i in range(len(d.paths)):
        changed[d.paths[i]] = True
    # Each annotated path, and its package's level.
    var paths = Dict[String, String]()
    for i in range(len(a.files)):
        if a.file_packages[i] in is_touched:
            paths[a.files[i].path] = String("notice") if is_info_package(a.file_packages[i], a.info_dirs) else level
    for i in range(len(a.mutants)):
        if a.mutant_packages[i] in is_touched:
            paths[a.mutants[i].path] = String("notice") if is_info_package(a.mutant_packages[i], a.info_dirs) else level
    var first = List[String]()
    var rest = List[String]()
    for e in paths.items():
        if e.key in changed:
            first.append(e.key)
        else:
            rest.append(e.key)
    sort_strings(first)
    sort_strings(rest)
    for i in range(len(rest)):
        first.append(rest[i])
    var out = List[Annotation]()
    for i in range(len(first)):
        var fa = _file_annotations(a, first[i], paths.get(first[i], level))
        for k in range(len(fa)):
            out.append(fa[k].copy())
    return out^


def cap_annotations(anns: List[Annotation], cap: Int) -> List[Annotation]:
    """The first `cap` of `anns`, in their order (see the module header)."""
    var out = List[Annotation]()
    for i in range(min(cap, len(anns))):
        out.append(anns[i].copy())
    return out^


def cap_note(total: Int, cap: Int, full_list_written: Bool) -> String:
    """The summary's line on annotations left out of the check run, or the
    empty string when none were."""
    if total <= cap:
        return String("")
    var s = String(total - cap) + String(" annotations omitted (cap ") + String(cap) + String("); ")
    if full_list_written:
        return s + String("the full list is in the annotations file")
    return s + String("the full list was not written (give --annotations-out)")


def write_annotation(mut j: JsonOut, a: Annotation):
    """One annotation object, as GitHub's check-run API takes it."""
    j.begin_object()
    j.field_str(String("path"), a.path)
    j.field_int(String("start_line"), a.start_line)
    j.field_int(String("end_line"), a.end_line)
    j.field_str(String("annotation_level"), a.level)
    j.field_str(String("title"), a.title)
    j.field_str(String("message"), a.message)
    j.end_object()


def annotations_json(anns: List[Annotation]) -> String:
    """Every annotation, a JSON array (the `--annotations-out` file)."""
    var j = JsonOut()
    j.begin_array()
    for i in range(len(anns)):
        j.item()
        write_annotation(j, anns[i])
    j.end_array()
    return j.text() + String("\n")
