from std.os import getenv, makedirs
from std.testing import assert_equal, assert_true

from covcheck.analyze import FORMAT_BRANCH_LCOV, FORMAT_LCOV, Analysis, Input, Options, Sources, analyze
from covcheck.cli import EXIT_GATE, EXIT_OK, parse_args, run
from covcheck.held import Held, add_hold
from covcheck.paths import RepoFiles, repo_files_of
from covcheck.programs import BinEntry, parse_bins, parse_program_runs, program_sources
from covcheck.text import write_text

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

comptime TOOL = "def main():\n    run()\n"
comptime TOOL_PATH = "src/p/bins/tool.mojo"


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


def _names(es: List[BinEntry]) -> String:
    var s = String("")
    for i in range(len(es)):
        if i > 0:
            s += String(" ")
        s += es[i].name + String("=") + es[i].path
    return s^


def _refused(text: String, fragment: String) raises:
    var raised = False
    try:
        _ = parse_bins(text, String("m.toml"))
    except e:
        raised = True
        assert_true(String(e).find(fragment) >= 0, String(e) + String(" lacks ") + fragment)
        assert_true(String(e).startswith("m.toml:"), String(e))
    assert_true(raised, String("not refused: ") + text)


# ---- the manifest reader --------------------------------------------------


def test_inline_array_in_every_layout() raises:
    assert_equal(_names(parse_bins(String(MANIFEST), String("m.toml"))), "tool=bins/tool.mojo")
    var multi = String(
        "[targets]\n"
        "bins = [  # the programs\n"
        "    { name = \"a\", path = \"bins/a.mojo\" },\n"
        "    { path = 'bins/b.mojo', name = \"b\", },  # a comment, with a } and a ]\n"
        "]\n"
        "tests = [\"tests\"]\n"
    )
    assert_equal(_names(parse_bins(multi, String("m.toml"))), "a=bins/a.mojo b=bins/b.mojo")
    # CRLF line ends, and spaces inside the table's header.
    var crlf = String("[ targets ]\r\nbins = [{ name = \"a\", path = \"bins/a.mojo\" }]\r\n")
    assert_equal(_names(parse_bins(crlf, String("m.toml"))), "a=bins/a.mojo")


def test_array_of_tables() raises:
    var t = String(
        "[package]\nname = \"p\"\n\n"
        "[[targets.bins]]\nname = \"a\"\npath = \"bins/a.mojo\"\n\n"
        "[[targets.bins]]\npath = \"bins/b.mojo\" # trailing\nname = \"b\"\nkind = \"x\"\n\n"
        "[targets]\nlib = { path = \"src/p\" }\n"
    )
    assert_equal(_names(parse_bins(t, String("m.toml"))), "a=bins/a.mojo b=bins/b.mojo")


def test_no_bins_is_no_programs() raises:
    assert_equal(len(parse_bins(String(""), String("m.toml"))), 0)
    assert_equal(len(parse_bins(String("[package]\nname = \"p\"\n"), String("m.toml"))), 0)
    assert_equal(len(parse_bins(String("[targets]\nlib = { path = \"x\" }\nbins = []\n"), String("m.toml"))), 0)
    assert_equal(len(parse_bins(String("[targets]\nbins = [\n]\n"), String("m.toml"))), 0)
    # `bins` in another table is not the targets' bins.
    var other = String("[package]\nbins = [{ name = \"a\", path = \"bins/a.mojo\" }]\n[extra]\nbins = 3\n")
    assert_equal(len(parse_bins(other, String("m.toml"))), 0)


def test_other_values_are_skipped_not_read() raises:
    # A `#` in a string is no comment; a multi-line string holds look-alike lines.
    var t = String(
        "[package]\n"
        "description = \"a # b = [\"\n"
        "notes = \"\"\"\n"
        "[targets]\n"
        "bins = [{ name = \"fake\", path = \"bins/fake.mojo\" }]\n"
        "\"\"\"\n"
        "one = '''a''' # after\n"
        "[targets]\n"
        "bins = [{ name = \"real\", path = \"bins/real.mojo\" }]\n"
    )
    assert_equal(_names(parse_bins(t, String("m.toml"))), "real=bins/real.mojo")


def test_shapes_that_are_refused() raises:
    # One inline table where the array belongs.
    _refused(String("[targets]\nbins = { name = \"a\", path = \"bins/a.mojo\" }\n"), String("array of entries"))
    # An array of something else.
    _refused(String("[targets]\nbins = [\"bins/a.mojo\"]\n"), String("inline table"))
    _refused(String("[targets]\nbins = \"bins/a.mojo\"\n"), String("array of entries"))
    _refused(String("[targets]\nbins = [{ name = \"a\", path = \"bins/a.mojo\" } { name = \"b\", path = \"bins/b.mojo\" }]\n"), String("separated by"))
    _refused(String("[targets]\nbins = [{ name = \"a\", path = \"bins/a.mojo\" },, { name = \"b\", path = \"bins/b.mojo\" }]\n"), String("inline table"))
    # A table, not an array of tables.
    _refused(String("[targets.bins]\nname = \"a\"\npath = \"bins/a.mojo\"\n"), String("is a table"))
    _refused(String("[targets]\nbins.a = 1\n"), String("dotted key"))
    _refused(String("[[targets.bins]]\nname = \"a\"\npath = \"bins/a.mojo\"\n[targets.bins.extra]\n"), String("not a shape"))
    _refused(String("[[targets]]\nbins = []\n"), String("not a shape"))
    _refused(String("targets = { bins = [] }\n"), String("as a table"))
    _refused(String("targets.bins = []\n"), String("as a table"))
    # Both shapes, and the key twice.
    _refused(
        String("[targets]\nbins = []\n[[targets.bins]]\nname = \"a\"\npath = \"bins/a.mojo\"\n"), String("inline array and as")
    )
    _refused(
        String("[[targets.bins]]\nname = \"a\"\npath = \"bins/a.mojo\"\n[targets]\nbins = [{ name = \"b\", path = \"bins/b.mojo\" }]\n"),
        String("given twice"),
    )
    _refused(String("[targets]\nbins = []\nbins = []\n"), String("given twice"))
    # Text that is no manifest.
    _refused(String("[targets\nbins = []\n"), String("table header"))
    _refused(String("[targets]\nbins\n"), String("key = value"))
    _refused(String("[targets]\nbins = [{ name = \"a\", path = \"bins/a.mojo\" }\n"), String("never closed"))
    _refused(String("[targets]\nbins = [{ name = \"a\", path = \"bins/a.mojo\"\n]\n"), String("never closed"))
    _refused(String("[package]\nnotes = \"\"\"\nno end\n"), String("never closed"))


def test_entries_must_name_and_path() raises:
    _refused(String("[targets]\nbins = [{ name = \"a\" }]\n"), String("no `path`"))
    _refused(String("[targets]\nbins = [{ path = \"bins/a.mojo\" }]\n"), String("no `name`"))
    _refused(String("[targets]\nbins = [{ name = \"\", path = \"bins/a.mojo\" }]\n"), String("no `name`"))
    _refused(String("[[targets.bins]]\nname = \"a\"\n"), String("no `path`"))
    _refused(String("[[targets.bins]]\npath = \"bins/a.mojo\"\n"), String("no `name`"))
    _refused(String("[[targets.bins]]\n[[targets.bins]]\nname = \"a\"\npath = \"bins/a.mojo\"\n"), String("no `path`"))
    _refused(String("[targets]\nbins = [{ name = \"a\", name = \"b\", path = \"bins/a.mojo\" }]\n"), String("given twice"))
    _refused(String("[[targets.bins]]\nname = \"a\"\nname = \"b\"\npath = \"bins/a.mojo\"\n"), String("given twice"))
    _refused(String("[[targets.bins]]\nname = \"a\"\npath = \"x.mojo\"\npath = \"y.mojo\"\n"), String("given twice"))
    _refused(String("[targets]\nbins = [{ name = \"a\", path = 5 }]\n"), String("plain quoted string"))
    _refused(String("[targets]\nbins = [{ name = \"a\", path = \"bins/\\a.mojo\" }]\n"), String("plain quoted string"))
    _refused(String("[targets]\nbins = [{ name = \"a\", path = \"bins/a.mojo }]\n"), String("never closed"))
    _refused(String("[targets]\nbins = [{ name = \"a\", path }]\n"), String("key = value"))
    _refused(String("[targets]\nbins = [{ name = \"a\", path = \"bins/a.mojo\", }, { }]\n"), String("empty field"))


def test_paths_must_be_relative_mojo_files() raises:
    var head = String("[targets]\nbins = [{ name = \"a\", path = \"")
    var tail = String("\" }]\n")
    _refused(head + String("") + tail, String("is empty"))
    _refused(head + String("/bins/a.mojo") + tail, String("relative path"))
    _refused(head + String("bins/a.txt") + tail, String("`.mojo` file"))
    _refused(head + String("../bins/a.mojo") + tail, String("segment"))
    _refused(head + String("bins/../a.mojo") + tail, String("segment"))
    _refused(head + String("./bins/a.mojo") + tail, String("segment"))
    _refused(head + String("bins//a.mojo") + tail, String("segment"))
    _refused(head + String("bins/") + tail, String("`.mojo` file"))
    assert_equal(_names(parse_bins(head + String("a.mojo") + tail, String("m.toml"))), "a=a.mojo")


def test_quoting_and_nesting_in_the_manifest() raises:
    # A backslash-escaped quote does not end a string, so the `#` after it is inside the string.
    var esc = String(
        "[package]\n"
        "note = \"say \\\"hi\\\" # not a comment\"\n"
        "[targets]\n"
        "bins = [{ name = \"a\", path = \"bins/a.mojo\" }]\n"
    )
    assert_equal(_names(parse_bins(esc, String("m.toml"))), "a=bins/a.mojo")
    # Quoted keys, and a nested array inside an entry, whose brackets do not end the entry.
    var quoted = String(
        "[targets]\n"
        "\"bins\" = [{ \"name\" = \"q\", 'path' = \"bins/q.mojo\", tags = [\"x\", \"y\"] }]\n"
    )
    assert_equal(_names(parse_bins(quoted, String("m.toml"))), "q=bins/q.mojo")
    # A key given twice inside one entry; an entry whose brace is never matched.
    _refused(String("[targets]\nbins = [{ name = \"a\", path = \"x.mojo\", path = \"y.mojo\" }]\n"), String("given twice"))
    _refused(String("[targets]\nbins = [{ name = \"a\", path = \"bins/a.mojo\" ] ]\n"), String("never closed"))


def test_a_package_without_a_manifest_has_no_programs() raises:
    var packages = List[String]()
    packages.append(String("src/r"))
    packages.append(String("src/p"))
    var manifests = Dict[String, String]()
    manifests[String("src/p/mopm.toml")] = String(MANIFEST)
    var ps = program_sources(_repo(), manifests, packages)
    assert_equal(len(ps), 1)
    assert_equal(ps[0].package, "src/p")
    assert_equal(ps[0].path, TOOL_PATH)


def test_the_error_names_the_line() raises:
    var raised = False
    try:
        _ = parse_bins(String("[package]\nname = \"p\"\n\n[targets]\nbins = [{ name = \"a\" }]\n"), String("src/p/mopm.toml"))
    except e:
        raised = True
        assert_true(String(e).startswith("src/p/mopm.toml:5: "), String(e))
    assert_true(raised)


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
    assert_true(f.message.find("no test target of the package runs its built program") >= 0, f.message)
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
        assert_true(String(e).find("src/p/bins/gone.mojo, which is not a file of the repository") >= 0, String(e))
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
    var b = analyze(r, List[Input](), repo_files_of(l), Held(), s, _enforce(parse_runs("bins/tool.mojo\n")))
    for i in range(len(b.findings)):
        assert_true(b.findings[i].kind != String("UnrunProgram"))
    assert_equal(b.packages[b.package_index(String("(root)"))].line_found, 2)


def parse_runs(text: String) -> List[String]:
    var d = parse_program_runs(text)
    var l = List[String]()
    for e in d.items():
        l.append(e.key)
    return l^


def test_the_runs_file() raises:
    var d = parse_program_runs(String("src/p/bins/tool.mojo\r\n\n  src/q/bins/x.mojo  \n\n"))
    assert_equal(len(d), 2)
    assert_true(String("src/p/bins/tool.mojo") in d)
    assert_true(String("src/q/bins/x.mojo") in d)
    assert_equal(len(parse_program_runs(String(""))), 0)
    assert_equal(len(parse_program_runs(String("\n\n"))), 0)


# ---- the command line --------------------------------------------------------


def _tmp(name: String) raises -> String:
    var d = getenv("TMPDIR") + String("/") + name
    makedirs(d, exist_ok=True)
    return d


def _write_tree(dir: String) raises -> List[String]:
    """A tiny repository under `dir/root` and the gate's arguments over it, less --program-runs."""
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


def test_the_program_runs_flag() raises:
    var dir = _tmp(String("programs_cli"))
    var args = _write_tree(dir)
    # No evidence: the program is a finding and the gate fails.
    assert_equal(run(args.copy()), EXIT_GATE)
    # An empty evidence file says the same.
    write_text(dir + String("/runs_none"), String(""))
    var none = args.copy()
    none.append("--program-runs")
    none.append(dir + String("/runs_none"))
    assert_equal(run(none^), EXIT_GATE)
    # The evidence names the program: the gate passes.
    write_text(dir + String("/runs"), String(TOOL_PATH) + String("\n"))
    var ran = args.copy()
    ran.append("--program-runs")
    ran.append(dir + String("/runs"))
    assert_equal(run(ran^), EXIT_OK)
    # The flag is parsed for both commands and given once.
    var p = parse_args(_flag_args(dir))
    assert_equal(p.get(String("--program-runs")), dir + String("/runs"))
    var twice = _flag_args(dir)
    twice.append("--program-runs")
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
    missing.append("--program-runs")
    missing.append(dir + String("/no_such_file"))
    assert_true(run(missing^) != EXIT_OK)
    assert_true(run(missing_flag_value(args)) != EXIT_OK)


def missing_flag_value(args: List[String]) -> List[String]:
    var l = args.copy()
    l.append("--program-runs")
    return l^


def _flag_args(dir: String) raises -> List[String]:
    var a = _write_tree(dir)
    a.append("--program-runs")
    a.append(dir + String("/runs"))
    return a^


def main() raises:
    test_inline_array_in_every_layout()
    test_array_of_tables()
    test_no_bins_is_no_programs()
    test_other_values_are_skipped_not_read()
    test_shapes_that_are_refused()
    test_entries_must_name_and_path()
    test_paths_must_be_relative_mojo_files()
    test_quoting_and_nesting_in_the_manifest()
    test_a_package_without_a_manifest_has_no_programs()
    test_the_error_names_the_line()
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
    test_the_runs_file()
    test_the_program_runs_flag()
    print("test_programs: PASS")
