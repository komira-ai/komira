from std.testing import assert_equal, assert_true

from covcheck.exempt import (
    STATUS_EXEMPT,
    STATUS_EXEMPT_BRANCHES,
    STATUS_NO_REASON,
    STATUS_NO_RECORD,
    STATUS_STALE,
    apply_exemptions,
    marker_in,
    scan_markers,
)
from covcheck.cobertura import parse_cobertura
from covcheck.lcov import parse_lcov
from covcheck.model import FileCov
from covcheck.mutants import parse_mutants

# Exemption markers (the one documented form, and the near misses that are
# not markers), what a marker does to the counts; the mutants file format.


def test_end_of_line_marker() raises:
    var m = marker_in(String("    abort()  # cov: unreachable the caller checked n > 0"))
    assert_true(m.found)
    assert_equal(m.reason, "the caller checked n > 0")


def test_marker_alone_on_a_line_is_that_line() raises:
    var m = marker_in(String("# cov: unreachable why  "))
    assert_true(m.found)
    assert_equal(m.reason, "why")


def test_marker_without_reason() raises:
    var m = marker_in(String("x()  # cov: unreachable"))
    assert_true(m.found)
    assert_equal(m.reason, "")
    var blank = marker_in(String("x()  # cov: unreachable   "))
    assert_true(blank.found)
    assert_equal(blank.reason, "")


def test_near_misses_are_not_markers() raises:
    var misses = List[String]()
    misses.append("x()  #cov: unreachable why")
    misses.append("x()  # cov:unreachable why")
    misses.append("x()  # Cov: unreachable why")
    misses.append("x()  # cov: Unreachable why")
    misses.append("x()  # cov: unreachable: why")
    misses.append("x()  # cov: unreachables why")
    misses.append("x()  ## cov: unreachable why")
    misses.append("x()  # cov:  unreachable why")
    misses.append("x()  #  cov: unreachable why")
    misses.append("x()  # cov: unreachable\twhy")
    misses.append("s = \"# cov: unreachable why\"")
    misses.append("x()  # coverage: unreachable why")
    misses.append("x()# cov: unreachable why")
    for i in range(len(misses)):
        assert_true(not marker_in(misses[i]).found, misses[i])


def test_scan_numbers_lines() raises:
    var ms = scan_markers(String("p.mojo"), String("a\nb  # cov: unreachable r1\nc\n# cov: unreachable r2\n"))
    assert_equal(len(ms), 2)
    assert_equal(ms[0].line, 2)
    assert_equal(ms[0].reason, "r1")
    assert_equal(ms[1].line, 4)


def test_apply_statuses_and_counts() raises:
    var f = FileCov(String("p.mojo"))
    f.add_line(1, 0)
    f.add_line(2, 5)
    f.add_line(3, 0)
    f.add_branch(String("1,0,0"), 0)
    f.add_branch(String("1,0,1"), 1)
    f.add_branch(String("3,0,0"), 0)
    var ms = scan_markers(String("p.mojo"), String(
        "a  # cov: unreachable never\n"
        "b  # cov: unreachable but it ran\n"
        "c  # cov: unreachable\n"
        "d  # cov: unreachable no code here\n"
    ))
    var removed = apply_exemptions(f, ms)
    assert_equal(removed, 1)
    assert_equal(ms[0].status, String(STATUS_EXEMPT))
    assert_equal(ms[1].status, String(STATUS_STALE))
    assert_equal(ms[2].status, String(STATUS_NO_REASON))
    assert_equal(ms[3].status, String(STATUS_NO_RECORD))
    # Line 1 and its two branches left the counts; the stale line 2 and the
    # reasonless line 3 (and its branch) still count.
    assert_equal(f.line_found(), 2)
    assert_equal(f.line_hit(), 1)
    assert_equal(f.branch_found(), 1)
    assert_equal(f.branch_hit(), 0)


comptime GUARD_SOURCE = (
    "def f(fd: Int) raises:\n"
    "    var x = 1\n"
    "    if fd < 0:  # cov: unreachable open never fails here\n"
    "        raise Error(\"open\")\n"
    "    if fd > 9:  # cov: unreachable every branch was taken\n"
)


def _check_guard(mut f: FileCov) raises:
    """Line 3 ran but one of its two branches never did: the marker takes
    its branches out and leaves the line counted (covered). Line 5 ran and
    took every branch: the marker is stale."""
    var ms = scan_markers(String("g.mojo"), String(GUARD_SOURCE))
    var removed = apply_exemptions(f, ms)
    assert_equal(removed, 0)
    assert_equal(ms[0].line, 3)
    assert_equal(ms[0].status, String(STATUS_EXEMPT_BRANCHES))
    assert_equal(ms[1].status, String(STATUS_STALE))
    assert_equal(f.line_found(), 3)
    assert_equal(f.line_hit(), 3)
    assert_equal(f.branch_found(), 2)
    assert_equal(f.branch_hit(), 2)


def test_marker_on_a_run_line_exempts_its_untaken_branches_lcov() raises:
    var fs = parse_lcov(String(
        "SF:g.mojo\nDA:2,5\nDA:3,5\nBRDA:3,0,0,5\nBRDA:3,0,1,0\nDA:5,5\nBRDA:5,0,0,2\nBRDA:5,0,1,3\nend_of_record\n"
    ), String("g.info"))
    _check_guard(fs[0])


def test_marker_on_a_run_line_exempts_its_untaken_branches_cobertura() raises:
    var fs = parse_cobertura(String(
        "<coverage><packages><package name=\"\"><classes><class name=\"g\" filename=\"g.mojo\"><lines>"
        "<line number=\"2\" hits=\"5\"/>"
        "<line number=\"3\" hits=\"5\" branch=\"true\" condition-coverage=\"50% (1/2)\"/>"
        "<line number=\"5\" hits=\"5\" branch=\"true\" condition-coverage=\"100% (2/2)\"/>"
        "</lines></class></classes></package></packages></coverage>"
    ), String("g.xml"))
    _check_guard(fs[0])


def _mut_refused(text: String, want: String) raises:
    var raised = False
    try:
        _ = parse_mutants(text, String("m.tsv"))
    except e:
        raised = True
        assert_true(String(e).find(want) >= 0, String(e) + String(" lacks ") + want)
    assert_true(raised, String("accepted: ") + text)


def test_mutants_rows() raises:
    var ms = parse_mutants(String(
        "# path line status operator description\n"
        "src/a/x.mojo\t3\tkilled\tnegate\tx > 0 -> x <= 0\n"
        "src/a/x.mojo\t4\tsurvived\tdelete\t\n"
        "src/a/x.mojo\t5\ttimeout\tloop\tforever\n"
        "src/a/x.mojo\t6\terror\tconst\tdoes not compile\n"
    ), String("m.tsv"))
    assert_equal(len(ms), 4)
    assert_equal(ms[0].status, "killed")
    assert_equal(ms[0].description, "x > 0 -> x <= 0")
    assert_equal(ms[1].description, "")
    assert_equal(ms[3].line, 6)


def test_mutants_refusals() raises:
    _mut_refused(String("a\t1\tkilled\top\n"), String("m.tsv:1: a row has 5 tab-separated fields"))
    _mut_refused(String("# c\na\tx\tkilled\top\td\n"), String("m.tsv:2: line 'x'"))
    _mut_refused(String("a\t0\tkilled\top\td\n"), String("line '0'"))
    _mut_refused(String("a\t1000000001\tkilled\top\td\n"), String("m.tsv:1: line '1000000001'"))
    _mut_refused(String("a\t1\tlived\top\td\n"), String("status 'lived'"))
    _mut_refused(String("a\t1\tkilled\t\td\n"), String("an empty operator"))
    _mut_refused(String("\t1\tkilled\top\td\n"), String("an empty path"))
    _mut_refused(String("a\t1\tkilled\top\td\r\n"), String("carriage return"))
    _mut_refused(String("a\t1\tkilled\top\td\n\na\t2\tkilled\top\td\n"), String("m.tsv:2: an empty line"))


def main() raises:
    test_end_of_line_marker()
    test_marker_alone_on_a_line_is_that_line()
    test_marker_without_reason()
    test_near_misses_are_not_markers()
    test_scan_numbers_lines()
    test_apply_statuses_and_counts()
    test_marker_on_a_run_line_exempts_its_untaken_branches_lcov()
    test_marker_on_a_run_line_exempts_its_untaken_branches_cobertura()
    test_mutants_rows()
    test_mutants_refusals()
    print("test_exempt_mutants: PASS")
