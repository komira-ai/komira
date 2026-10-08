from std.testing import assert_equal, assert_true

from covcheck.paths import RepoFiles, repo_files_of
from covcheck.ratchet import Ratchet, compare, parse_ratchet, propose, render_ratchet
from covcheck.stats import PackageStats
from covcheck.text import read_text

# The ratchet file's grammar, the shipped file, every comparison outcome and
# the proposed file.

comptime SHIPPED = "tools/build/coverage/ratchet.tsv"


def _repo() -> RepoFiles:
    var l = List[String]()
    l.append("src/a/BUCK")
    l.append("src/b/BUCK")
    l.append("src/c/BUCK")
    return repo_files_of(l)


def _pkg(name: String, lhit: Int, lfound: Int, bhit: Int, bfound: Int) -> PackageStats:
    var p = PackageStats(name)
    p.line_hit = lhit
    p.line_found = lfound
    p.branch_hit = bhit
    p.branch_found = bfound
    return p^


def _kinds(r: Ratchet, ps: List[PackageStats]) -> String:
    var fs = compare(r, ps, _repo(), True)
    var s = String("")
    for i in range(len(fs)):
        if i > 0:
            s += String(" ")
        s += fs[i].kind + String(":") + fs[i].package
        if fs[i].metric.byte_length() > 0:
            s += String(":") + fs[i].metric
    return s^


def _refused(text: String, want: String) raises:
    var raised = False
    try:
        _ = parse_ratchet(text, String("r.tsv"))
    except e:
        raised = True
        assert_true(String(e).find(want) >= 0, String(e) + String(" lacks ") + want)
    assert_true(raised, String("accepted: ") + text)


def test_shipped_file_parses() raises:
    # The rows are the census's (census.sh render): libraries under src/,
    # never the test packages under src/tests/.
    var r = parse_ratchet(read_text(String(SHIPPED)), String(SHIPPED))
    assert_true(len(r.rows) > 0)
    assert_true(len(r.comments) > 3)
    for i in range(len(r.rows)):
        assert_true(r.rows[i].package.startswith("src/"), r.rows[i].package)
        assert_true(not r.rows[i].package.startswith("src/tests/"), r.rows[i].package)


def test_rows_parse() raises:
    var r = parse_ratchet(String("# h\nsrc/a\t8734\t-\nsrc/b\t10000\t5000\n"), String("r.tsv"))
    assert_equal(len(r.rows), 2)
    assert_equal(r.rows[0].line_floor, 8734)
    assert_equal(r.rows[0].branch_floor, -1)
    assert_equal(r.rows[1].branch_floor, 5000)


def test_malformed_rows_refused() raises:
    _refused(String("src/a\t87\n"), String("r.tsv:1: a row has 3 tab-separated fields"))
    _refused(String("src/a 87 -\n"), String("r.tsv:1: a row has 3"))
    _refused(String("src/a\t87.5\t-\n"), String("line floor '87.5'"))
    _refused(String("src/a\t10001\t-\n"), String("line floor '10001'"))
    _refused(String("src/a\t1\tx\n"), String("branch floor 'x'"))
    _refused(String("\t1\t-\n"), String("an empty package"))
    _refused(String("# ok\n\nsrc/a\t1\t-\n"), String("r.tsv:2: an empty line"))
    _refused(String("src/a\t1\t-\r\n"), String("carriage return"))


def test_unsorted_and_duplicate_rows_refused() raises:
    _refused(String("src/b\t1\t-\nsrc/a\t1\t-\n"), String("r.tsv:2: rows are not sorted"))
    _refused(String("src/a\t1\t-\nsrc/a\t2\t-\n"), String("r.tsv:2: package src/a has a second row"))


def test_equal_is_no_finding() raises:
    var r = parse_ratchet(String("src/a\t5000\t5000\n"), String("r.tsv"))
    var ps = List[PackageStats]()
    ps.append(_pkg(String("src/a"), 1, 2, 1, 2))
    assert_equal(_kinds(r, ps), "")


def test_below_is_regression_line_and_branch() raises:
    var r = parse_ratchet(String("src/a\t5001\t5001\n"), String("r.tsv"))
    var ps = List[PackageStats]()
    ps.append(_pkg(String("src/a"), 1, 2, 1, 2))
    assert_equal(_kinds(r, ps), "Regression:src/a:line Regression:src/a:branch")


def test_above_is_no_finding_and_the_proposal_rises() raises:
    var r = parse_ratchet(String("# keep me\nsrc/a\t4000\t1000\n"), String("r.tsv"))
    var ps = List[PackageStats]()
    ps.append(_pkg(String("src/a"), 2, 3, 1, 2))
    assert_equal(_kinds(r, ps), "")
    assert_equal(render_ratchet(propose(r, ps, _repo())), "# keep me\nsrc/a\t6666\t5000\n")


def test_missing_row() raises:
    # src/b's floor is 0, so its missing data loses nothing.
    var r = parse_ratchet(String("src/b\t0\t-\n"), String("r.tsv"))
    var ps = List[PackageStats]()
    ps.append(_pkg(String("src/a"), 1, 4, 0, 0))
    assert_equal(_kinds(r, ps), "MissingRow:src/a:line")


def test_unmeasured_package_needs_no_row() raises:
    var r = Ratchet()
    var ps = List[PackageStats]()
    ps.append(_pkg(String("src/a"), 0, 0, 0, 0))
    assert_equal(_kinds(r, ps), "")


def test_row_without_data_is_a_regression() raises:
    # src/b has a BUCK file and a floor but no data at all; src/c's floors
    # are 0 (nothing to lose); src/a was measured without branch data while
    # its row has a branch floor. Dropping the data never escapes a floor.
    var r = parse_ratchet(String("src/a\t1\t3000\nsrc/b\t9000\t8000\nsrc/c\t0\t0\n"), String("r.tsv"))
    var ps = List[PackageStats]()
    ps.append(_pkg(String("src/a"), 1, 1, 0, 0))
    assert_equal(_kinds(r, ps), "Regression:src/a:branch Regression:src/b:line Regression:src/b:branch")
    var fs = compare(r, ps, _repo(), True)
    assert_equal(fs[1].measured, -1)
    assert_equal(fs[1].bound, 9000)
    # A package present with no line record (only mutants, say) and a line
    # floor: the same; with every line exempted it was measured.
    var rb = parse_ratchet(String("src/b\t9000\t8000\n"), String("r.tsv"))
    var empty = List[PackageStats]()
    empty.append(_pkg(String("src/b"), 0, 0, 0, 0))
    assert_equal(_kinds(rb, empty), "Regression:src/b:line Regression:src/b:branch")
    empty[0].exempt_lines = 2
    assert_equal(_kinds(rb, empty), "Regression:src/b:branch")
    # The gate (not every row) checks only its own package's row.
    assert_equal(len(compare(r, ps, _repo(), False)), 1)


def test_extra_row() raises:
    var r = parse_ratchet(String("src/a\t1\t-\nsrc/gone\t1\t-\n"), String("r.tsv"))
    var ps = List[PackageStats]()
    ps.append(_pkg(String("src/a"), 1, 1, 0, 0))
    assert_equal(_kinds(r, ps), "ExtraRow:src/gone")


def test_branch_floor_missing() raises:
    var r = parse_ratchet(String("src/a\t1\t-\n"), String("r.tsv"))
    var ps = List[PackageStats]()
    ps.append(_pkg(String("src/a"), 1, 1, 1, 4))
    assert_equal(_kinds(r, ps), "BranchFloorMissing:src/a:branch")


def test_proposal_adds_drops_and_sorts() raises:
    # src/a: raised; src/b: new row (no branch data: '-'); src/c: kept, not
    # measured; src/gone: dropped (no BUCK). Byte-stable: proposing again
    # from the proposal gives the same text.
    var r = parse_ratchet(String("# h\nsrc/a\t1\t-\nsrc/c\t7000\t-\nsrc/gone\t1\t-\n"), String("r.tsv"))
    var ps = List[PackageStats]()
    ps.append(_pkg(String("src/a"), 1, 2, 3, 4))
    ps.append(_pkg(String("src/b"), 2, 3, 0, 0))
    var text = render_ratchet(propose(r, ps, _repo()))
    assert_equal(text, "# h\nsrc/a\t5000\t7500\nsrc/b\t6666\t-\nsrc/c\t7000\t-\n")
    var again = render_ratchet(propose(parse_ratchet(text, String("p.tsv")), ps, _repo()))
    assert_equal(again, text)


def test_pinned_rows() raises:
    # A pinned row (a 4th field, its reason) parses, renders as written, and
    # is never raised by the proposal; an empty reason is refused. Its floors
    # are compared like any row's.
    var text = String("# h\nsrc/a\t4000\t-\ttiming: a.mojo:10-12 run only when contended\nsrc/b\t1\t-\n")
    var r = parse_ratchet(text, String("r.tsv"))
    assert_equal(r.rows[0].reason, "timing: a.mojo:10-12 run only when contended")
    assert_equal(r.rows[1].reason, "")
    assert_equal(render_ratchet(r), text)
    var ps = List[PackageStats]()
    ps.append(_pkg(String("src/a"), 9, 10, 0, 0))
    ps.append(_pkg(String("src/b"), 9, 10, 0, 0))
    assert_equal(render_ratchet(propose(r, ps, _repo())), "# h\nsrc/a\t4000\t-\ttiming: a.mojo:10-12 run only when contended\nsrc/b\t9000\t-\n")
    var low = List[PackageStats]()
    low.append(_pkg(String("src/a"), 3, 10, 0, 0))
    assert_equal(_kinds(r, low), "Regression:src/a:line Regression:src/b:line")
    _refused(String("src/a\t1\t-\t\n"), String("r.tsv:1: a pinned row has an empty reason"))
    _refused(String("src/a\t1\t-\tx\ty\n"), String("r.tsv:1: a row has 3 tab-separated fields"))


def test_gate_package_with_no_line_is_no_regression() raises:
    # The gate counts every source of its library, so a gated package with
    # no executable line (a library whose sources are all generated) has
    # nothing to cover: its row's floors, set by another library of the
    # same directory, are no Regression for it. Every row compared (report)
    # still finds them unmeasured.
    var r = parse_ratchet(String("src/a\t9000\t8000\n"), String("r.tsv"))
    var ps = List[PackageStats]()
    ps.append(_pkg(String("src/a"), 0, 0, 0, 0))
    assert_equal(len(compare(r, ps, _repo(), False)), 0)
    assert_equal(_kinds(r, ps), "Regression:src/a:line Regression:src/a:branch")


def main() raises:
    test_shipped_file_parses()
    test_rows_parse()
    test_malformed_rows_refused()
    test_unsorted_and_duplicate_rows_refused()
    test_equal_is_no_finding()
    test_below_is_regression_line_and_branch()
    test_above_is_no_finding_and_the_proposal_rises()
    test_missing_row()
    test_unmeasured_package_needs_no_row()
    test_row_without_data_is_a_regression()
    test_extra_row()
    test_branch_floor_missing()
    test_proposal_adds_drops_and_sorts()
    test_pinned_rows()
    test_gate_package_with_no_line_is_no_regression()
    print("test_ratchet: PASS")
