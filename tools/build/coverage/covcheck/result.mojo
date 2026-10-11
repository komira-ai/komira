"""The machine-readable result (`--result-out`), one JSON object.

`covcheck report`:

    {"conclusion", "mode", "target_bp", "total": <numbers>,
     "diff": {"covered", "uncovered", "not_instrumented", "exempt"},
     "touched_packages": [...], "packages": [<package>...],
     "findings": [<finding>...], "exemptions": [<exemption>...],
     "unrecorded_functions": [<function>...],
     "unrecorded_functions_unreliable": [<function>...], "ignored_files",
     "excluded_test_files", "ignored_mutants", "excluded_test_mutants",
     "info_packages": [...], "info_findings": [<finding>...]}

`covcheck gate`: `{"conclusion", "mode", "target_bp", "package": <package>,
"findings", "exemptions", "unrecorded_functions",
"unrecorded_functions_unreliable", ...the four counts, "info_packages",
"info_findings"}`. A `<package>` is written by
one function for both, so the gate's entry for a package and the report's
are the same bytes when the numbers are the same.

Percentages are basis points, `null` when n/a; a floor is `null` when the
package has no row (or, for the branch floor, the row has `-`). A package's
`files` counts every file in its numbers, `unmeasured_files` those that
raised `UnmeasuredFile`; a finding's `line` is 0 when it is about a whole file, its `count`
the lines an `UnmeasuredFile` counts uncovered or a `DeclarationOnlyFile`
would have counted (`null` for other kinds).
`info_packages` are the measured test-only packages (`--info-package`) and
`info_findings` their findings, then any package's `DeclarationOnlyFile`
(a file no test compiled that counts no line, analyze.mojo step 4), which
`findings` does not hold and the conclusion does not count (analyze.mojo,
step 8).
A `<function>` (`{"package", "path", "line", "name", "class", "lines"}`)
is a function of a measured file none of whose lines has a record
(analyze.mojo, step 9), `lines` its executable lines without an exemption
marker with a reason. `unrecorded_functions` holds the `plain` ones, the
class a census can count; `unrecorded_functions_unreliable` the
`always_inline` and `comptime_if` ones, which a test may call all the same
(decls.mojo). Both are reported only: no number or finding counts them.
"""

from covcheck.analyze import Analysis
from covcheck.annotate import DiffCoverage
from covcheck.decls import KIND_PLAIN
from covcheck.jsonw import JsonOut
from covcheck.stats import Finding, PackageStats


def _numbers(mut j: JsonOut, p: PackageStats):
    j.field_int(String("files"), p.files)
    j.field_int(String("unmeasured_files"), p.unmeasured_files)
    j.field_int(String("line_hit"), p.line_hit)
    j.field_int(String("line_found"), p.line_found)
    j.field_opt(String("line_bp"), p.line_bp())
    j.field_int(String("branch_hit"), p.branch_hit)
    j.field_int(String("branch_found"), p.branch_found)
    j.field_opt(String("branch_bp"), p.branch_bp())
    j.field_int(String("exempt_lines"), p.exempt_lines)
    j.field_int(String("mutants"), p.mutants)
    j.field_int(String("killed"), p.killed)
    j.field_int(String("survived"), p.survived)
    j.field_int(String("timeout"), p.timeout)
    j.field_int(String("error"), p.error)
    j.field_opt(String("mutation_bp"), p.mutation_bp())


def write_package(mut j: JsonOut, p: PackageStats):
    j.begin_object()
    j.field_str(String("package"), p.package)
    _numbers(j, p)
    j.field_opt(String("line_floor_bp"), p.line_floor if p.has_row else -1)
    j.field_opt(String("branch_floor_bp"), p.branch_floor if p.has_row else -1)
    j.end_object()


def package_json(p: PackageStats) -> String:
    var j = JsonOut()
    write_package(j, p)
    return j.text()


def _unrecorded(mut j: JsonOut, a: Analysis, key: String, plain: Bool):
    """The unrecorded functions of class `plain` (`plain`), or of every
    other class."""
    j.key(key)
    j.begin_array()
    for i in range(len(a.unrecorded_functions)):
        ref u = a.unrecorded_functions[i]
        if (u.kind == String(KIND_PLAIN)) != plain:
            continue
        j.item()
        j.begin_object()
        j.field_str(String("package"), u.package)
        j.field_str(String("path"), u.path)
        j.field_int(String("line"), u.line)
        j.field_str(String("name"), u.name)
        j.field_str(String("class"), u.kind)
        j.field_int(String("lines"), u.lines)
        j.end_object()
    j.end_array()


def _findings(mut j: JsonOut, key: String, fs: List[Finding]):
    j.key(key)
    j.begin_array()
    for i in range(len(fs)):
        ref f = fs[i]
        j.item()
        j.begin_object()
        j.field_str(String("kind"), f.kind)
        j.field_str(String("package"), f.package)
        j.field_str(String("metric"), f.metric)
        j.field_opt(String("measured_bp"), f.measured)
        j.field_opt(String("bound_bp"), f.bound)
        j.field_str(String("path"), f.path)
        j.field_int(String("line"), f.line)
        j.field_str(String("message"), f.message)
        j.field_opt(String("count"), f.count)
        j.end_object()
    j.end_array()


def _tail(mut j: JsonOut, a: Analysis):
    _findings(j, String("findings"), a.findings)
    j.key(String("exemptions"))
    j.begin_array()
    for i in range(len(a.exemptions)):
        ref e = a.exemptions[i]
        j.item()
        j.begin_object()
        j.field_str(String("path"), e.path)
        j.field_int(String("line"), e.line)
        j.field_str(String("reason"), e.reason)
        j.field_str(String("status"), e.status)
        j.end_object()
    j.end_array()
    _unrecorded(j, a, String("unrecorded_functions"), True)
    _unrecorded(j, a, String("unrecorded_functions_unreliable"), False)
    j.field_int(String("ignored_files"), a.ignored_files)
    j.field_int(String("excluded_test_files"), a.excluded_test_files)
    j.field_int(String("ignored_mutants"), a.ignored_mutants)
    j.field_int(String("excluded_test_mutants"), a.excluded_test_mutants)
    j.key(String("info_packages"))
    j.begin_array()
    for i in range(len(a.info_packages)):
        j.item()
        j.str_value(a.info_packages[i])
    j.end_array()
    _findings(j, String("info_findings"), a.info_findings)


def _head(mut j: JsonOut, a: Analysis):
    j.field_str(String("conclusion"), a.conclusion)
    j.field_str(String("mode"), a.mode)
    j.field_int(String("target_bp"), a.target_bp)


def report_json(a: Analysis, touched: List[String], d: DiffCoverage) -> String:
    var j = JsonOut()
    j.begin_object()
    _head(j, a)
    j.key(String("total"))
    j.begin_object()
    _numbers(j, a.total)
    j.end_object()
    j.key(String("diff"))
    j.begin_object()
    j.field_int(String("covered"), d.covered)
    j.field_int(String("uncovered"), d.uncovered)
    j.field_int(String("not_instrumented"), d.not_instrumented)
    j.field_int(String("exempt"), d.exempt)
    j.end_object()
    j.key(String("touched_packages"))
    j.begin_array()
    for i in range(len(touched)):
        j.item()
        j.str_value(touched[i])
    j.end_array()
    j.key(String("packages"))
    j.begin_array()
    for i in range(len(a.packages)):
        j.item()
        write_package(j, a.packages[i])
    j.end_array()
    _tail(j, a)
    j.end_object()
    return j.text() + String("\n")


def gate_json(a: Analysis, package: String) -> String:
    var j = JsonOut()
    j.begin_object()
    _head(j, a)
    j.key(String("package"))
    var k = a.package_index(package)
    if k >= 0:
        write_package(j, a.packages[k])
    else:
        write_package(j, PackageStats(package))
    _tail(j, a)
    j.end_object()
    return j.text() + String("\n")
