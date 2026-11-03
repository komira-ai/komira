from std.os import getenv, makedirs

from komira_json import parse_json_value
from std.testing import assert_equal, assert_true

from covcheck.analyze import FORMAT_BRANCH_LCOV, FORMAT_COBERTURA, FORMAT_LCOV, Analysis, Input, Options, Sources, analyze
from covcheck.cli import EXIT_GATE, EXIT_INPUT, EXIT_OK, EXIT_USAGE, parse_args, run
from covcheck.held import Held, add_hold
from covcheck.paths import RepoFiles, repo_files_of
from covcheck.programs import parse_program_targets
from covcheck.text import read_text, write_text

# Program sources: a file the package's mopm.toml names in `[targets] bins` is
# left out of the line and branch numbers and of UnmeasuredFile, and is an
# UnrunProgram finding when no test target runs the built program (the
# evidence, `Options.program_runs`, is the build graph's, passed as data). Any
# other file stays ordinary source, a package with no manifest is unchanged, and
# a manifest shape the reader does not know is an error, never an exclusion.

comptime MANIFEST = (
    "[package]\n"
    "name = \"p\"\n"
    "\n"
    "[targets]\n"
    "lib = { path = \"src/p\" }\n"
    "bins = [{ name = \"tool\", path = \"bins/tool.mojo\" }]\n"
    "tests = [\"tests\"]\n"
)

comptime TABLES = (
    "[package]\n"
    "name = \"p\"\n"
    "\n"
    "[[targets.bins]]\n"
    "name = \"tool\"\n"
    "path = \"bins/tool.mojo\"\n"
    "\n"
    "[targets]\n"
    "lib = { path = \"src/p\" }\n"
)

comptime TOOL = "def main():\n    run()\n"
comptime TOOL_PATH = "src/p/bins/tool.mojo"
# The query's output when a test target of src/p depends on the program's target.
comptime RAN_JSON = "{\"komira//src/p:tool\": {\"main\": null, \"srcs\": [\"komira//src/p/bins/tool.mojo\"]}}\n"


def _repo(manifest: Bool = True, other: Bool = False) -> RepoFiles:
    var l = List[String]()
    l.append("src/p/BUCK")
    l.append("src/p/a.mojo")
    l.append("src/p/bins/tool.mojo")
    if other:
        l.append("src/p/bins/other.mojo")
    l.append("src/p/tests/test_a.mojo")
    if manifest:
        l.append("src/p/mopm.toml")
    l.append("src/q/BUCK")
    l.append("src/q/mopm.toml")
    l.append("src/q/q.mojo")
    l.append("src/r/BUCK")
    l.append("src/r/r.mojo")
    # A package below src/p, with its own BUCK file.
    l.append("src/p/sub/BUCK")
    l.append("src/p/sub/x.mojo")
    return repo_files_of(l)


def _sources(manifest: String = String(MANIFEST)) -> Sources:
    var s = Sources(String(""))
    s.texts[String("src/p/a.mojo")] = String("def f() -> Int:\n    return 1\n")
    s.texts[String(TOOL_PATH)] = String(TOOL)
    s.texts[String("src/p/bins/other.mojo")] = String(TOOL)
    s.texts[String("src/p/tests/test_a.mojo")] = String("def main():\n    pass\n")
    s.texts[String("src/p/mopm.toml")] = manifest
    # A manifest no reader of this tool could parse, in a package no report names.
    s.texts[String("src/q/mopm.toml")] = String("[targets]\nbins = {\n")
    s.texts[String("src/q/q.mojo")] = String("x\n")
    s.texts[String("src/r/r.mojo")] = String("x\n")
    return s^


def _report() -> List[Input]:
    # a.mojo fully covered, lines and the two branches of line 2.
    var l = List[Input]()
    l.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String(
        "SF:src/p/a.mojo\nDA:1,1\nDA:2,3\nBRDA:2,0,0,1\nBRDA:2,0,1,2\nend_of_record\n"
    )))
    return l^


def _held() raises -> Held:
    var h = Held()
    add_hold(h, String("src/p"), String("line\nbranch\n"), String("src/p/coverage_held"), List[String]())
    return h^


def _enforce(runs: List[String] = List[String]()) -> Options:
    var o = Options()
    o.mode = String("enforce")
    for i in range(len(runs)):
        o.program_runs[runs[i]] = True
    return o^


def _ran() -> List[String]:
    var l = List[String]()
    l.append(String(TOOL_PATH))
    return l^


def _kinds(a: Analysis) -> String:
    var s = String("")
    for i in range(len(a.findings)):
        if i > 0:
            s += String(" ")
        s += a.findings[i].kind
        if a.findings[i].path.byte_length() > 0:
            s += String("@") + a.findings[i].path
    return s^


# ---- the rule, in the analysis ---------------------------------------------


def test_program_nothing_runs_is_a_finding() raises:
    # The red case: the entry has no test that runs it. Its two lines are not counted
    # either way: a.mojo alone is 2/2 lines and 2/2 branches.
    var a = analyze(_report(), List[Input](), _repo(), _held(), _sources(), _enforce())
    assert_equal(_kinds(a), "UnrunProgram@src/p/bins/tool.mojo")
    assert_equal(a.conclusion, "failure")
    var k = a.package_index(String("src/p"))
    assert_equal(a.packages[k].line_found, 2)
    assert_equal(a.packages[k].line_hit, 2)
    assert_equal(a.packages[k].unmeasured_files, 0)
    assert_equal(a.packages[k].files, 1)
    var f = a.findings[0].copy()
    assert_equal(f.package, "src/p")
    assert_equal(f.line, 0)
    assert_true(f.message.find("`tool`") >= 0, f.message)
    assert_true(f.message.find("src/p/mopm.toml") >= 0, f.message)
    assert_true(f.message.find("no test target of the package depends on its built program") >= 0, f.message)
    assert_true(f.message.find("add a test") >= 0, f.message)


def test_program_a_test_runs_is_excluded_without_a_finding() raises:
    var a = analyze(_report(), List[Input](), _repo(), _held(), _sources(), _enforce(_ran()))
    assert_equal(_kinds(a), "")
    assert_equal(a.conclusion, "success")
    var k = a.package_index(String("src/p"))
    assert_equal(a.packages[k].line_found, 2)
    assert_equal(a.packages[k].line_hit, 2)
    assert_equal(a.packages[k].branch_found, 2)
    assert_equal(a.packages[k].unmeasured_files, 0)
    assert_equal(len(a.program_paths), 1)
    assert_equal(a.program_paths[0], TOOL_PATH)
    # The program is no generated source.
    assert_equal(len(a.generated_paths), 0)
    # No file entry of it either.
    assert_equal(a.file_index(String(TOOL_PATH)), -1)


def test_evidence_is_per_program_path() raises:
    # A run of another path is no evidence for this one.
    var other = List[String]()
    other.append("src/p/bins/other.mojo")
    other.append("src/q/bins/tool.mojo")
    other.append("bins/tool.mojo")
    var a = analyze(_report(), List[Input](), _repo(), _held(), _sources(), _enforce(other))
    assert_equal(_kinds(a), "UnrunProgram@src/p/bins/tool.mojo")
    # Two entries, one of them run: one finding.
    var two = String(MANIFEST).replace(
        "bins = [{ name = \"tool\", path = \"bins/tool.mojo\" }]",
        "bins = [{ name = \"tool\", path = \"bins/tool.mojo\" }, { name = \"other\", path = \"bins/other.mojo\" }]",
    )
    var b = analyze(_report(), List[Input](), _repo(True, True), _held(), _sources(two), _enforce(_ran()))
    assert_equal(_kinds(b), "UnrunProgram@src/p/bins/other.mojo")
    assert_true(b.findings[0].message.find("`other`") >= 0, b.findings[0].message)
    assert_equal(len(b.program_paths), 2)
    assert_equal(b.packages[b.package_index(String("src/p"))].line_found, 2)


def test_a_bins_file_the_manifest_does_not_name_stays_source() raises:
    # other.mojo is under bins/ but no entry names it: counted, never compiled by a test.
    var a = analyze(_report(), List[Input](), _repo(True, True), _held(), _sources(), _enforce(_ran()))
    var ka = a.package_index(String("src/p"))
    assert_equal(a.packages[ka].line_found, 4)
    assert_equal(a.packages[ka].unmeasured_files, 1)
    assert_equal(_kinds(a), "Regression UnmeasuredFile@src/p/bins/other.mojo")
    var bare = String("[targets]\nlib = { path = \"src/p\" }\ntests = [\"tests\"]\n")
    var b = analyze(_report(), List[Input](), _repo(True, True), _held(), _sources(bare), _enforce(_ran()))
    var k = b.package_index(String("src/p"))
    # tool.mojo and other.mojo: 2 executable lines each, no test compiled either.
    assert_equal(b.packages[k].line_found, 6)
    assert_equal(b.packages[k].unmeasured_files, 2)
    var paths = String("")
    for i in range(len(b.findings)):
        if b.findings[i].kind == String("UnmeasuredFile"):
            paths += b.findings[i].path + String(" ")
        assert_true(b.findings[i].kind != String("UnrunProgram"))
    assert_equal(paths, "src/p/bins/other.mojo src/p/bins/tool.mojo ")


def test_no_manifest_is_unchanged() raises:
    var a = analyze(_report(), List[Input](), _repo(False, True), _held(), _sources(), _enforce(_ran()))
    var k = a.package_index(String("src/p"))
    assert_equal(a.packages[k].line_found, 6)
    assert_equal(a.packages[k].unmeasured_files, 2)
    assert_equal(len(a.program_paths), 0)
    var found = 0
    for i in range(len(a.findings)):
        if a.findings[i].kind == String("UnmeasuredFile"):
            found += 1
        assert_true(a.findings[i].kind != String("UnrunProgram"))
    assert_equal(found, 2)


def test_a_program_a_report_names_is_still_left_out() raises:
    # A test compiled the program: its lines and arms, from the line report and from a branch record
    # file (which together would be refused as two sources of one file's branches), are not counted.
    var l = _report()
    l.append(Input(String(FORMAT_LCOV), String(""), String("t2.info"), String(
        "SF:src/p/bins/tool.mojo\nDA:2,0\nBRDA:2,0,0,0\nBRDA:2,0,1,-\nend_of_record\n"
    )))
    l.append(Input(String(FORMAT_BRANCH_LCOV), String(""), String("b.info"), String(
        "SF:src/p/bins/tool.mojo\nBRDA:2,3:br:0/1,0,1\nBRDA:2,3:br:0/1,1,-\nend_of_record\n"
    )))
    var a = analyze(l, List[Input](), _repo(), _held(), _sources(), _enforce(_ran()))
    assert_equal(_kinds(a), "")
    var k = a.package_index(String("src/p"))
    assert_equal(a.packages[k].line_found, 2)
    assert_equal(a.packages[k].branch_found, 2)
    assert_equal(a.packages[k].files, 1)
    # Without evidence the same reports still raise exactly the finding.
    var c = analyze(l, List[Input](), _repo(), _held(), _sources(), _enforce())
    assert_equal(_kinds(c), "UnrunProgram@src/p/bins/tool.mojo")
    # A surviving mutant of the program is dropped with it: no MutantSurvived.
    var m = List[Input]()
    m.append(Input(String("mutants"), String(""), String("m.tsv"), String("src/p/bins/tool.mojo\t2\tsurvived\top\td\n")))
    var d = analyze(l, m, _repo(), _held(), _sources(), _enforce(_ran()))
    assert_equal(_kinds(d), "")
    assert_equal(len(d.mutants), 0)


def test_the_hold_is_read_without_the_program() raises:
    # Counted, the two lines of tool.mojo would put the package at 50% (2/4) and fail its hold.
    var a = analyze(_report(), List[Input](), _repo(), _held(), _sources(), _enforce(_ran()))
    assert_equal(a.packages[a.package_index(String("src/p"))].line_bp(), 10000)
    for i in range(len(a.findings)):
        assert_true(a.findings[i].kind != String("Regression"))
        assert_true(a.findings[i].kind != String("BelowTarget"))


def test_a_bad_manifest_fails_the_run() raises:
    var bad = String("[targets]\nbins = [{ name = \"tool\" }]\n")
    var raised = False
    try:
        _ = analyze(_report(), List[Input](), _repo(), _held(), _sources(bad), _enforce(_ran()))
    except e:
        raised = True
        assert_true(String(e).startswith("src/p/mopm.toml:2: "), String(e))
    assert_true(raised)
    # An entry naming a file the repository does not have: the checkout and the manifest disagree.
    var gone = String(MANIFEST).replace("bins/tool.mojo", "bins/gone.mojo")
    raised = False
    try:
        _ = analyze(_report(), List[Input](), _repo(), _held(), _sources(gone), _enforce(_ran()))
    except e:
        raised = True
        assert_equal(String(e), "src/p/mopm.toml:6: bins entry `tool` names src/p/bins/gone.mojo, which is not a file of the repository")
    assert_true(raised)
    # Two entries naming one file.
    var twice = String(MANIFEST).replace(
        "bins = [{ name = \"tool\", path = \"bins/tool.mojo\" }]",
        "bins = [{ name = \"tool\", path = \"bins/tool.mojo\" }, { name = \"again\", path = \"bins/tool.mojo\" }]",
    )
    raised = False
    try:
        _ = analyze(_report(), List[Input](), _repo(), _held(), _sources(twice), _enforce(_ran()))
    except e:
        raised = True
        assert_equal(
            String(e),
            "src/p/mopm.toml:6: bins entry `again` names src/p/bins/tool.mojo, which src/p/mopm.toml:6: bins entry `tool` names too",
        )
    assert_true(raised)


def test_manifests_are_read_only_for_packages_in_the_run() raises:
    # src/q's manifest is unreadable, and src/q is in no report: nothing reads it.
    var a = analyze(_report(), List[Input](), _repo(), _held(), _sources(), _enforce(_ran()))
    assert_equal(_kinds(a), "")
    # The gate of src/p reads src/p's manifest only, even when a report names src/q.
    var l = _report()
    l.append(Input(String(FORMAT_LCOV), String(""), String("q.info"), String("SF:src/q/q.mojo\nDA:1,1\nend_of_record\n")))
    var o = _enforce(_ran())
    o.only_package = String("src/p")
    var g = analyze(l, List[Input](), _repo(), _held(), _sources(), o)
    assert_equal(_kinds(g), "")
    # In a full report that names src/q, its manifest is read, and refused.
    var raised = False
    try:
        _ = analyze(l, List[Input](), _repo(), _held(), _sources(), _enforce(_ran()))
    except e:
        raised = True
        assert_true(String(e).startswith("src/q/mopm.toml:"), String(e))
    assert_true(raised)


def test_a_package_with_a_hold_is_read_though_no_report_names_it() raises:
    # Only src/r is in a report; src/p holds its line, so it is in the run, and its program is a finding.
    var l = List[Input]()
    l.append(Input(String(FORMAT_LCOV), String(""), String("r.info"), String("SF:src/r/r.mojo\nDA:1,1\nend_of_record\n")))
    var a = analyze(l, List[Input](), _repo(), _held(), _sources(), _enforce())
    var saw = False
    for i in range(len(a.findings)):
        if a.findings[i].kind == String("UnrunProgram"):
            saw = True
            assert_equal(a.findings[i].path, TOOL_PATH)
    assert_true(saw, _kinds(a))
    # Without a hold src/p is not in the run, and its manifest is not read.
    var b = analyze(l, List[Input](), _repo(), Held(), _sources(), _enforce())
    for i in range(len(b.findings)):
        assert_true(b.findings[i].kind != String("UnrunProgram"))


def test_program_of_a_test_only_package_is_information() raises:
    var o = _enforce()
    o.info_packages.append(String("src/p"))
    var a = analyze(_report(), List[Input](), _repo(), _held(), _sources(), o)
    assert_equal(_kinds(a), "")
    var saw = False
    for i in range(len(a.info_findings)):
        if a.info_findings[i].kind == String("UnrunProgram"):
            saw = True
    assert_true(saw)
    assert_equal(a.conclusion, "success")


def test_the_root_package() raises:
    var l = List[String]()
    l.append("BUCK")
    l.append("mopm.toml")
    l.append("a.mojo")
    l.append("bins/tool.mojo")
    var s = Sources(String(""))
    s.texts[String("a.mojo")] = String("def f() -> Int:\n    return 1\n")
    s.texts[String("bins/tool.mojo")] = String(TOOL)
    s.texts[String("mopm.toml")] = String(MANIFEST)
    var r = List[Input]()
    r.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String("SF:a.mojo\nDA:1,1\nDA:2,1\nend_of_record\n")))
    var a = analyze(r, List[Input](), repo_files_of(l), Held(), s, _enforce())
    var found = False
    for i in range(len(a.findings)):
        if a.findings[i].kind == String("UnrunProgram"):
            found = True
            assert_equal(a.findings[i].path, "bins/tool.mojo")
    assert_true(found, _kinds(a))
    var root_runs = List[String]()
    for e in parse_program_targets(String("{\"komira//:tool\": {\"main\": null, \"srcs\": [\"komira//bins/tool.mojo\"]}}"), String("t.json")).items():
        root_runs.append(e.key)
    assert_equal(len(root_runs), 1)
    var b = analyze(r, List[Input](), repo_files_of(l), Held(), s, _enforce(root_runs))
    for i in range(len(b.findings)):
        assert_true(b.findings[i].kind != String("UnrunProgram"))
    assert_equal(b.packages[b.package_index(String("(root)"))].line_found, 2)


# ---- the command line --------------------------------------------------------


def _tmp(name: String) raises -> String:
    var d = getenv("TMPDIR") + String("/") + name
    makedirs(d, exist_ok=True)
    return d


def _write_tree(dir: String) raises -> List[String]:
    """A tiny repository under `dir/root` and the gate's arguments over it, less --program-targets."""
    makedirs(dir + String("/root/src/p/bins"), exist_ok=True)
    write_text(dir + String("/root/src/p/a.mojo"), String("def f() -> Int:\n    return 1\n"))
    write_text(dir + String("/root/src/p/bins/tool.mojo"), String(TOOL))
    write_text(dir + String("/root/src/p/mopm.toml"), String(MANIFEST))
    var names = List[String]()
    names.append("src/p/BUCK")
    names.append("src/p/a.mojo")
    names.append("src/p/bins/tool.mojo")
    names.append("src/p/mopm.toml")
    var b = List[UInt8]()
    for i in range(len(names)):
        var nb = names[i].as_bytes()
        for k in range(len(nb)):
            b.append(nb[k])
        b.append(UInt8(0))
    write_text(dir + String("/repo_files"), String(from_utf8_lossy=b))
    write_text(dir + String("/p.info"), String("SF:src/p/a.mojo\nDA:1,1\nDA:2,3\nBRDA:2,0,0,1\nBRDA:2,0,1,2\nend_of_record\n"))
    var a = List[String]()
    a.append("gate")
    a.append("--package")
    a.append("src/p")
    a.append("--repo-files")
    a.append(dir + String("/repo_files"))
    a.append("--source-root")
    a.append(dir + String("/root"))
    a.append("--lcov")
    a.append(dir + String("/p.info"))
    a.append("--mode")
    a.append("enforce")
    a.append("--target-bp")
    a.append("10000")
    a.append("--summary-out")
    a.append(dir + String("/summary.md"))
    a.append("--result-out")
    a.append(dir + String("/result.json"))
    return a^


def test_the_program_targets_flag() raises:
    var dir = _tmp(String("programs_cli"))
    var args = _write_tree(dir)
    # No --program-targets though the manifest declares a program: nothing says which program a test
    # runs, so the run is an input error, not a gate result.
    assert_equal(run(args.copy()), EXIT_INPUT)
    # The query's empty object: no test runs the program, a finding, and the gate fails.
    write_text(dir + String("/runs_none"), String("{}\n"))
    var none = args.copy()
    none.append("--program-targets")
    none.append(dir + String("/runs_none"))
    assert_equal(run(none^), EXIT_GATE)
    # A test of the package depends on the program's target: the gate passes.
    write_text(dir + String("/runs"), String(RAN_JSON))
    var ran = args.copy()
    ran.append("--program-targets")
    ran.append(dir + String("/runs"))
    assert_equal(run(ran^), EXIT_OK)
    # A test runs a binary whose entry point is the same path in another cell: no evidence.
    write_text(dir + String("/runs_other_cell"), String("{\"komira//src/p:tool\": {\"main\": \"other//src/p/bins/tool.mojo\", \"srcs\": []}}\n"))
    var other = args.copy()
    other.append("--program-targets")
    other.append(dir + String("/runs_other_cell"))
    assert_equal(run(other^), EXIT_GATE)
    # An empty file is not the query's output: an input error, not "no program runs".
    write_text(dir + String("/runs_empty"), String(""))
    var empty = args.copy()
    empty.append("--program-targets")
    empty.append(dir + String("/runs_empty"))
    assert_equal(run(empty^), EXIT_INPUT)
    # The flag is parsed for both commands and given once.
    var p = parse_args(_flag_args(dir))
    assert_equal(p.get(String("--program-targets")), dir + String("/runs"))
    var twice = _flag_args(dir)
    twice.append("--program-targets")
    twice.append(dir + String("/runs"))
    var raised = False
    try:
        _ = parse_args(twice)
    except e:
        raised = True
        assert_true(String(e).find("given twice") >= 0, String(e))
    assert_true(raised)
    # A runs file that cannot be read is an input error, not "no program runs".
    var missing = args.copy()
    missing.append("--program-targets")
    missing.append(dir + String("/no_such_file"))
    assert_equal(run(missing^), EXIT_INPUT)
    # The flag with no value is a usage error.
    assert_equal(run(missing_flag_value(args)), EXIT_USAGE)


def test_a_manifest_that_cannot_be_read_fails_the_run() raises:
    # The repository lists src/p/mopm.toml, but the source root holds no such file.
    var dir = _tmp(String("programs_unreadable"))
    var s = Sources(dir)
    s.texts[String("src/p/a.mojo")] = String("def f() -> Int:\n    return 1\n")
    var raised = False
    try:
        _ = analyze(_report(), List[Input](), _repo(), _held(), s, _enforce(_ran()))
    except e:
        raised = True
        assert_true(
            String(e).startswith(String("cannot read the source src/p/mopm.toml under --source-root ") + dir + String(": ")),
            String(e),
        )
    assert_true(raised)


def missing_flag_value(args: List[String]) -> List[String]:
    var l = args.copy()
    l.append("--program-targets")
    return l^


def _flag_args(dir: String) raises -> List[String]:
    var a = _write_tree(dir)
    a.append("--program-targets")
    a.append(dir + String("/runs"))
    return a^


def _query_args(dir: String, packages: String) raises -> List[String]:
    write_text(dir + String("/packages"), packages)
    var a = List[String]()
    a.append("program-query")
    a.append("--repo-files")
    a.append(dir + String("/repo_files"))
    a.append("--packages")
    a.append(dir + String("/packages"))
    a.append("--out")
    a.append(dir + String("/query.txt"))
    return a^


def test_the_program_query_command() raises:
    # What the census runs before its query: the query for the measured packages, as a file.
    var dir = _tmp(String("programs_query"))
    _ = _write_tree(dir)
    assert_equal(run(_query_args(dir, String("src/p\nsrc/q\n"))), EXIT_OK)
    assert_equal(
        read_text(dir + String("/query.txt")),
        "((kind('^mojo_binary_rule$', deps(kind('^mojo_test(_run)?_rule$', //src/p:))) + attrfilter('kind', 'bin',"
        + " kind('^mojo_unit_rule$', deps(kind('^mojo_test(_run)?_rule$', //src/p:))))) intersect //src/p:)",
    )
    # No measured package has a manifest (src/q; the root package, the empty line), or none is
    # measured: the file is empty, the census runs no query and passes no --program-targets.
    assert_equal(run(_query_args(dir, String("src/q\n\n"))), EXIT_OK)
    assert_equal(read_text(dir + String("/query.txt")), "")
    assert_equal(run(_query_args(dir, String(""))), EXIT_OK)
    assert_equal(read_text(dir + String("/query.txt")), "")
    # A packages file that cannot be read is an input error.
    var missing = _query_args(dir, String(""))
    missing[4] = dir + String("/no_such_file")
    assert_equal(run(missing^), EXIT_INPUT)
    # Its own flags only, each needed.
    var no_out = _query_args(dir, String(""))
    _ = no_out.pop()
    _ = no_out.pop()
    assert_equal(run(no_out^), EXIT_USAGE)
    for k in range(3):
        var extra = _query_args(dir, String(""))
        if k == 0:
            extra.append("--include-tests")
        elif k == 1:
            extra.append("--test-source")
            extra.append("src/p/a.mojo")
        else:
            extra.append("--lcov")
            extra.append(dir + String("/p.info"))
        assert_equal(run(extra^), EXIT_USAGE)


def test_a_program_that_is_a_test_source_is_an_error() raises:
    var m = String(MANIFEST).replace("bins/tool.mojo", "tests/test_a.mojo")
    var raised = False
    try:
        _ = analyze(_report(), List[Input](), _repo(), _held(), _sources(m), _enforce(_ran()))
    except e:
        raised = True
        assert_equal(
            String(e),
            "src/p/mopm.toml:6: bins entry `tool` names src/p/tests/test_a.mojo, which is a test source of src/p (under its tests/, or a --test-source)",
        )
    assert_true(raised)


# ---- the rule, in more shapes of the run ------------------------------------


def test_the_array_of_tables_in_the_analysis() raises:
    var a = analyze(_report(), List[Input](), _repo(), _held(), _sources(String(TABLES)), _enforce())
    assert_equal(_kinds(a), "UnrunProgram@src/p/bins/tool.mojo")
    var k = a.package_index(String("src/p"))
    assert_equal(a.packages[k].line_found, 2)
    assert_equal(a.packages[k].branch_found, 2)
    assert_equal(a.packages[k].unmeasured_files, 0)
    var b = analyze(_report(), List[Input](), _repo(), _held(), _sources(String(TABLES)), _enforce(_ran()))
    assert_equal(_kinds(b), "")
    assert_equal(len(b.program_paths), 1)
    assert_equal(b.program_paths[0], TOOL_PATH)


def test_a_report_of_the_program_alone_still_measures_the_package() raises:
    # The only record is the program's, and src/p has no hold: a.mojo is still counted, from its
    # source, as a file no test compiled.
    var l = List[Input]()
    l.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String("SF:src/p/bins/tool.mojo\nDA:2,1\nend_of_record\n")))
    var a = analyze(l, List[Input](), _repo(), Held(), _sources(), _enforce(_ran()))
    var k = a.package_index(String("src/p"))
    assert_true(k >= 0, _kinds(a))
    assert_equal(a.packages[k].line_found, 2)
    assert_equal(a.packages[k].line_hit, 0)
    assert_equal(a.packages[k].unmeasured_files, 1)
    # No record of src/p is left, so its line is also NotMeasured: nothing measured the package.
    assert_equal(_kinds(a), "BelowTarget NotMeasured UnmeasuredFile@src/p/a.mojo")


def test_manifests_of_packages_only_left_out_files_name_are_not_read() raises:
    # src/q's manifest cannot be read, and a report names only a test source of src/q, or only a
    # generated source of it: src/q is not in the run, so the manifest is not read.
    var l = _report()
    l.append(Input(String(FORMAT_LCOV), String(""), String("q.info"), String("SF:src/q/tests/test_q.mojo\nDA:1,1\nend_of_record\n")))
    var files = List[String]()
    files.append("src/p/BUCK")
    files.append("src/p/a.mojo")
    files.append("src/p/bins/tool.mojo")
    files.append("src/p/mopm.toml")
    files.append("src/q/BUCK")
    files.append("src/q/mopm.toml")
    files.append("src/q/gen.mojo")
    files.append("src/q/tests/test_q.mojo")
    var s = _sources()
    s.texts[String("src/q/gen.mojo")] = String("# @generated by a tool\ndef g():\n    pass\n")
    s.texts[String("src/q/tests/test_q.mojo")] = String("def main():\n    pass\n")
    var a = analyze(l, List[Input](), repo_files_of(files), _held(), s, _enforce(_ran()))
    assert_equal(_kinds(a), "")
    var g = _report()
    g.append(Input(String(FORMAT_LCOV), String(""), String("g.info"), String("SF:src/q/gen.mojo\nDA:2,1\nend_of_record\n")))
    var b = analyze(g, List[Input](), repo_files_of(files), _held(), s, _enforce(_ran()))
    assert_equal(_kinds(b), "")
    assert_equal(len(b.generated_paths), 1)
    assert_equal(b.generated_paths[0], "src/q/gen.mojo")


def test_a_program_with_a_generated_marker_is_a_program() raises:
    var s = _sources()
    s.texts[String(TOOL_PATH)] = String("# @generated\ndef main():\n    run()\n")
    var l = _report()
    l.append(Input(String(FORMAT_LCOV), String(""), String("t2.info"), String("SF:src/p/bins/tool.mojo\nDA:2,0\nend_of_record\n")))
    var a = analyze(l, List[Input](), _repo(), _held(), s, _enforce())
    assert_equal(_kinds(a), "UnrunProgram@src/p/bins/tool.mojo")
    assert_equal(len(a.program_paths), 1)
    assert_equal(len(a.generated_paths), 0)
    assert_equal(a.packages[a.package_index(String("src/p"))].line_found, 2)


def _cobertura(path: String, lines: String) -> String:
    return (
        String("<coverage><packages><package name=\"\"><classes><class name=\"c\" filename=\"") + path
        + String("\"><lines>") + lines + String("</lines></class></classes></package></packages></coverage>")
    )


def test_a_program_in_the_uncompiled_report_is_left_out() raises:
    # buildrules' report of the code no test compiled names the program: its lines are not counted,
    # and nothing about it is listed as left out by that report.
    var l = List[Input]()
    l.append(Input(String(FORMAT_COBERTURA), String(""), String("t.xml"), _cobertura(
        String("src/p/a.mojo"), String("<line number=\"1\" hits=\"1\"/><line number=\"2\" hits=\"1\"/>")
    )))
    l.append(Input(String(FORMAT_COBERTURA), String(""), String("x/__coverage__/uncompiled.cobertura.xml"), _cobertura(
        String(TOOL_PATH), String("<line number=\"2\" hits=\"0\"/>")
    )))
    var a = analyze(l, List[Input](), _repo(), _held(), _sources(), _enforce(_ran()))
    var k = a.package_index(String("src/p"))
    assert_equal(a.packages[k].line_found, 2)
    assert_equal(a.packages[k].line_hit, 2)
    assert_equal(a.packages[k].unmeasured_files, 0)
    assert_equal(len(a.excluded), 0)
    assert_equal(len(a.program_paths), 1)
    for i in range(len(a.findings)):
        assert_true(a.findings[i].kind != String("UnrunProgram") and a.findings[i].kind != String("UnmeasuredFile"), _kinds(a))


# ---- the report command --------------------------------------------------------


def _report_args(dir: String, mode: String, run_name: String) raises -> List[String]:
    var gate = _write_tree(dir)
    write_text(dir + String("/diff.txt"), String(""))
    var a = List[String]()
    a.append("report")
    # The gate's arguments less `gate --package src/p`, and the report's own.
    for i in range(3, len(gate)):
        if gate[i] == String("--mode"):
            continue
        if i > 0 and gate[i - 1] == String("--mode"):
            continue
        a.append(gate[i])
    a.append("--mode")
    a.append(mode)
    a.append("--diff")
    a.append(dir + String("/diff.txt"))
    a.append("--head-sha")
    a.append("0123456789abcdef0123456789abcdef01234567")
    a.append("--checkrun-dir")
    a.append(dir + String("/checkrun_") + run_name)
    return a^


def _result_kinds(path: String) raises -> String:
    var doc = parse_json_value(read_text(path))
    var fs = doc.get(String("findings"))
    var s = doc.get(String("conclusion")).as_string()
    for i in range(fs.array_len()):
        s += String(" ") + fs.element_at(i).get(String("kind")).as_string() + String("@") + fs.element_at(i).get(String("path")).as_string()
    return s^


def test_the_report_reads_the_program_targets() raises:
    var dir = _tmp(String("programs_report"))
    write_text(dir + String("/none.json"), String("{}\n"))
    write_text(dir + String("/ran.json"), String(RAN_JSON))
    # Without --program-targets the report is refused: the census passes the query's answer
    # whenever a measured package has a manifest.
    assert_equal(run(_report_args(dir, String("census"), String("no_flag"))), EXIT_INPUT)
    for m in range(3):
        var mode = String("census") if m == 0 else (String("neutral") if m == 1 else String("enforce"))
        var none = _report_args(dir, mode, mode + String("_none"))
        none.append("--program-targets")
        none.append(dir + String("/none.json"))
        # The report exits 0 whatever it finds; the conclusion carries the mode.
        assert_equal(run(none^), EXIT_OK)
        var want = String("failure") if m == 2 else String("neutral")
        assert_equal(_result_kinds(dir + String("/result.json")), want + String(" UnrunProgram@src/p/bins/tool.mojo"))
        var summary = read_text(dir + String("/summary.md"))
        assert_true(summary.find("**UnrunProgram** `src/p` `src/p/bins/tool.mojo`: bins entry `tool` of src/p/mopm.toml") >= 0, summary)
        var ran = _report_args(dir, mode, mode + String("_ran"))
        ran.append("--program-targets")
        ran.append(dir + String("/ran.json"))
        assert_equal(run(ran^), EXIT_OK)
        var want_ran = String("success") if m == 2 else String("neutral")
        assert_equal(_result_kinds(dir + String("/result.json")), want_ran)

def main() raises:
    test_program_nothing_runs_is_a_finding()
    test_program_a_test_runs_is_excluded_without_a_finding()
    test_evidence_is_per_program_path()
    test_a_bins_file_the_manifest_does_not_name_stays_source()
    test_no_manifest_is_unchanged()
    test_a_program_a_report_names_is_still_left_out()
    test_the_hold_is_read_without_the_program()
    test_a_bad_manifest_fails_the_run()
    test_manifests_are_read_only_for_packages_in_the_run()
    test_a_package_with_a_hold_is_read_though_no_report_names_it()
    test_program_of_a_test_only_package_is_information()
    test_the_root_package()
    test_a_program_that_is_a_test_source_is_an_error()
    test_the_array_of_tables_in_the_analysis()
    test_a_report_of_the_program_alone_still_measures_the_package()
    test_manifests_of_packages_only_left_out_files_name_are_not_read()
    test_a_program_with_a_generated_marker_is_a_program()
    test_a_program_in_the_uncompiled_report_is_left_out()
    test_the_report_reads_the_program_targets()
    test_the_program_targets_flag()
    test_the_program_query_command()
    test_a_manifest_that_cannot_be_read_fails_the_run()
    print("test_programs: PASS")
