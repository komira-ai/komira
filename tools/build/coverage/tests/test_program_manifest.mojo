from std.testing import assert_equal, assert_true

from covcheck.paths import RepoFiles, repo_files_of
from covcheck.programs import BinEntry, parse_bins, parse_program_targets, program_sources

# The program sources' readers: the `bins` of a mopm.toml (programs.parse_bins over
# manifest.toml_statements), what an entry may name (programs.program_sources), and the
# build-graph evidence file (programs.parse_program_targets). Every shape the reader does
# not know is an error naming the manifest and line; the analysis that uses them is in
# test_programs.mojo.

comptime MANIFEST = (
    "[package]\n"
    "name = \"p\"\n"
    "\n"
    "[targets]\n"
    "lib = { path = \"src/p\" }\n"
    "bins = [{ name = \"tool\", path = \"bins/tool.mojo\" }]\n"
    "tests = [\"tests\"]\n"
)

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
    l.append("src/r/BUCK")
    l.append("src/r/r.mojo")
    # A package below src/p, with its own BUCK file.
    l.append("src/p/sub/BUCK")
    l.append("src/p/sub/x.mojo")
    return repo_files_of(l)


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
    # A quoted table name, which would hide `bins` from this reader.
    _refused(String("[\"targets\"]\nbins = []\n"), String("quoted table name"))
    _refused(String("[[targets.'bins']]\nname = \"a\"\npath = \"bins/a.mojo\"\n"), String("quoted table name"))


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
    # A quoted key holding an escaped quote and an `=`: the key ends at its closing quote.
    var key = String(
        "[package]\n"
        "\"we\\\"ird = key\" = 1\n"
        "[targets]\n"
        "bins = [{ name = \"k\", path = \"bins/k.mojo\" }]\n"
    )
    assert_equal(_names(parse_bins(key, String("m.toml"))), "k=bins/k.mojo")
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


def _targets(text: String) raises -> String:
    """The entry points `parse_program_targets` takes from `text`, sorted, space-separated."""
    var keys = List[String]()
    for e in parse_program_targets(text, String("t.json")).items():
        keys.append(e.key)
    sort(keys)
    var out = String("")
    for i in range(len(keys)):
        if i > 0:
            out += String(" ")
        out += keys[i]
    return out^


def _targets_refused(text: String, want: String) raises:
    var raised = False
    try:
        _ = parse_program_targets(text, String("t.json"))
    except e:
        raised = True
        assert_equal(String(e), want)
    assert_true(raised, String("not refused: ") + text)


def test_the_program_targets_file() raises:
    # buck2's JSON: `main` when set, else the one source; a target with two sources and no main
    # gives none; a mojo_unit_rule has no `main` attribute; the `<package>:<path>` and root spellings.
    var json = String(
        "{\n"
        "  \"komira//src/p:tool\": {\"main\": null, \"srcs\": [\"komira//src/p/bins/tool.mojo\"]},\n"
        "  \"komira//src/p:two\": {\"main\": \"komira//src/p/bins/b.mojo\", \"srcs\": [\"komira//src/p/bins/a.mojo\", \"komira//src/p/bins/b.mojo\"]},\n"
        "  \"komira//src/p:many\": {\"main\": null, \"srcs\": [\"komira//src/p/bins/c.mojo\", \"komira//src/p/bins/d.mojo\"]},\n"
        "  \"komira//src/q:bin_x\": {\"srcs\": [\"komira//src/q:bins/x.mojo\"]},\n"
        "  \"komira//:root\": {\"main\": \"komira//:bins/r.mojo\", \"srcs\": []},\n"
        "  \"komira//src/q:none\": {\"main\": null, \"srcs\": []}\n"
        "}\n"
    )
    assert_equal(_targets(json), "bins/r.mojo src/p/bins/b.mojo src/p/bins/tool.mojo src/q/bins/x.mojo")
    # No program target: the empty object the census writes.
    assert_equal(_targets(String("{}\n")), "")
    # Anything else is an input error naming the file.
    _targets_refused(String("[]"), String("t.json: not a JSON object of target labels"))
    _targets_refused(String("{\"//:a\": 1}"), String("t.json: //:a: not an object of attributes"))
    _targets_refused(String("{\"//:a\": {\"main\": 3}}"), String("t.json: //:a: `main` is neither a path nor null"))
    _targets_refused(String("{\"//:a\": {\"srcs\": \"x\"}}"), String("t.json: //:a: `srcs` is not a list"))
    _targets_refused(String("{\"//:a\": {\"srcs\": [1]}}"), String("t.json: //:a: a source in `srcs` is not a path"))
    _targets_refused(String("{\"//:a\": {\"srcs\": [\"bins/a.mojo\"]}}"), String("t.json: a source that is not `<cell>//<path>`: bins/a.mojo"))
    var raised = False
    try:
        _ = parse_program_targets(String(""), String("t.json"))
    except e:
        raised = True
        assert_true(String(e).startswith("t.json: not the JSON of a buck2 uquery: "), String(e))
    assert_true(raised)


def test_values_are_read_to_their_end() raises:
    # Text after an otherwise valid bins table is still read, and refused when it is no value.
    var ok = String(MANIFEST)
    _refused(ok + String("extra = \"never closed\n"), String("m.toml:8: a string that is never closed"))
    _refused(ok + String("extra = [}\n"), String("m.toml:8: a `}` where the `[` of line 8 is never closed"))
    _refused(ok + String("extra = {]\n"), String("m.toml:8: a `]` where the `{` of line 8 is never closed"))
    _refused(ok + String("extra = ]\n"), String("m.toml:8: `extra` has no value"))
    _refused(ok + String("extra = [1]]\n"), String("m.toml:8: text after the end of a statement: ]"))
    _refused(ok + String("extra = 1 2\n"), String("m.toml:8: text after the end of a statement: 2"))
    _refused(ok + String("extra = \n"), String("m.toml:8: `extra` has no value"))
    _refused(ok + String(" = 1\n"), String("m.toml:8: a `=` with no key"))
    _refused(ok + String("extra = '''never closed\n"), String("m.toml:8: a string that is never closed"))
    _refused(ok + String("extra = \"ends in a backslash \\"), String("m.toml:8: a string that is never closed"))
    _refused(ok + String("[extra]] \n"), String("m.toml:8: text after the end of a statement: ]"))


def test_table_names_are_dotted_bare_keys() raises:
    _refused(String("[tar gets]\nbins = []\n"), String("m.toml:1: a table name that is not a dotted list of bare keys: [tar gets]"))
    _refused(String("[targets.]\nbins = []\n"), String("m.toml:1: a table name that is not a dotted list of bare keys: [targets.]"))
    _refused(String("[]\n"), String("m.toml:1: a table name that is not a dotted list of bare keys: []"))
    _refused(String("[[targets.bins]\nname = \"a\"\n"), String("m.toml:1: a table header that does not end with its brackets: [[targets.bins]"))
    _refused(String("[targets.\"bins\"]\n"), String("m.toml:1: a quoted table name is not a shape this tool reads: [targets.\"bins\"]"))
    # Blanks around the dots are allowed, as TOML allows them.
    var spaced = String("[[ targets . bins ]]\nname = \"a\"\npath = \"bins/a.mojo\"\n")
    assert_equal(_names(parse_bins(spaced, String("m.toml"))), "a=bins/a.mojo")


def test_multi_line_strings_are_read_to_their_real_end() raises:
    # An escaped quote does not end a multi-line basic string; the look-alike table inside it is text.
    var esc = String(
        "[package]\n"
        "notes = \"\"\"a \\\"\"\" is not the end\n"
        "[targets]\n"
        "bins = [{ name = \"fake\", path = \"bins/fake.mojo\" }]\n"
        "\"\"\"\n"
        "[targets]\n"
        "bins = [{ name = \"real\", path = \"bins/real.mojo\" }]\n"
    )
    assert_equal(_names(parse_bins(esc, String("m.toml"))), "real=bins/real.mojo")
    # A multi-line string inside an array, holding brackets, a `#` and look-alike text.
    var nested = String(
        "[package]\n"
        "keywords = [\"\"\"one ] }\n"
        "# not a comment\n"
        "[targets]\n"
        "bins = [{ name = \"fake\", path = \"bins/fake.mojo\" }]\"\"\", '''two\n"
        "]'''] # a comment\n"
        "[targets]\n"
        "bins = [{ name = \"real\", path = \"bins/real.mojo\" }]\n"
    )
    assert_equal(_names(parse_bins(nested, String("m.toml"))), "real=bins/real.mojo")
    # Up to two quotes of the string's own just before the closing three.
    var ends = String("[package]\nq = \"\"\"say \"hi\"\"\"\"\n[targets]\nbins = []\n")
    assert_equal(len(parse_bins(ends, String("m.toml"))), 0)
    _refused(String("[package]\nnotes = \"\"\"a \\\"\"\"\n"), String("m.toml:2: a string that is never closed"))


def _sources_of(manifest: String) raises -> List[String]:
    var packages = List[String]()
    packages.append(String("src/p"))
    var manifests = Dict[String, String]()
    manifests[String("src/p/mopm.toml")] = manifest
    var ps = program_sources(_repo(True, True), manifests, packages)
    var out = List[String]()
    for i in range(len(ps)):
        out.append(ps[i].name + String("=") + ps[i].path + String("@") + String(ps[i].line))
    return out^


def _sources_refused(manifest: String, want: String) raises:
    var raised = False
    try:
        _ = _sources_of(manifest)
    except e:
        raised = True
        assert_equal(String(e), want)
    assert_true(raised, String("not refused: ") + manifest)


def test_entries_name_files_of_their_own_package() raises:
    var two = String("[targets]\nbins = [{ name = \"tool\", path = \"bins/tool.mojo\" }, { name = \"other\", path = \"bins/other.mojo\" }]\n")
    var got = _sources_of(two)
    assert_equal(len(got), 2)
    assert_equal(got[0], "tool=src/p/bins/tool.mojo@2")
    assert_equal(got[1], "other=src/p/bins/other.mojo@2")
    # Each error names the manifest and the line of the entry.
    _sources_refused(
        String("[targets]\n\nbins = [{ name = \"gone\", path = \"bins/gone.mojo\" }]\n"),
        String("src/p/mopm.toml:3: bins entry `gone` names src/p/bins/gone.mojo, which is not a file of the repository"),
    )
    _sources_refused(
        String("[[targets.bins]]\nname = \"x\"\npath = \"sub/x.mojo\"\n"),
        String("src/p/mopm.toml:1: bins entry `x` names src/p/sub/x.mojo, which is a file of the package src/p/sub, not of src/p"),
    )
    _sources_refused(
        String("[[targets.bins]]\nname = \"a\"\npath = \"bins/tool.mojo\"\n[[targets.bins]]\nname = \"b\"\npath = \"bins/tool.mojo\"\n"),
        String("src/p/mopm.toml:4: bins entry `b` names src/p/bins/tool.mojo, which src/p/mopm.toml:1: bins entry `a` names too"),
    )
    _sources_refused(
        String("[[targets.bins]]\nname = \"a\"\npath = \"bins/tool.mojo\"\n[[targets.bins]]\nname = \"a\"\npath = \"bins/other.mojo\"\n"),
        String("src/p/mopm.toml:4: bins entry `a`: the entry of line 1 has that name too"),
    )



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
    test_values_are_read_to_their_end()
    test_table_names_are_dotted_bare_keys()
    test_multi_line_strings_are_read_to_their_real_end()
    test_entries_name_files_of_their_own_package()
    test_the_program_targets_file()
    print("test_program_manifest: PASS")
