from std.testing import assert_equal, assert_true

from covcheck.cobertura import parse_cobertura
from covcheck.lcov import parse_lcov
from covcheck.model import FileCov, branch_line
from covcheck.text import read_text, sort_ints

# The Cobertura reader: kcov's exact shape, the XML it accepts, what it
# refuses, and that it measures what an lcov tracefile of the same data does.

comptime FIXTURES = "tools/build/coverage/tests/fixtures/"


def shape(fs: List[FileCov]) raises -> String:
    """Every file's path, line hits and per-line branches (taken/total) as
    text, so two reports can be compared whatever their branch keys."""
    var s = String("")
    for i in range(len(fs)):
        s += fs[i].path + String(":")
        var ls = fs[i].lines()
        for k in range(len(ls)):
            s += String(" ") + String(ls[k]) + String("=") + String(fs[i].hits[ls[k]])
        var bl = List[Int]()
        for e in fs[i].branches.items():
            var ln = branch_line(e.key)
            var seen = False
            for x in range(len(bl)):
                if bl[x] == ln:
                    seen = True
            if not seen:
                bl.append(ln)
        sort_ints(bl)
        for k in range(len(bl)):
            var n = 0
            var t = 0
            for e in fs[i].branches.items():
                if branch_line(e.key) == bl[k]:
                    n += 1
                    if e.value > 0:
                        t += 1
            s += String(" b") + String(bl[k]) + String("=") + String(t) + String("/") + String(n)
        s += String("\n")
    return s^


def _refused(text: String, want: String) raises:
    var raised = False
    try:
        _ = parse_cobertura(text, String("c.xml"))
    except e:
        raised = True
        var msg = String(e)
        assert_true(msg.find(want) >= 0, msg + String(" lacks ") + want)
    assert_true(raised, String("accepted: ") + text)


def _doc(lines: String) -> String:
    return String("<coverage><packages><package><classes><class filename=\"x.mojo\"><lines>") + lines + String("</lines></class></classes></package></packages></coverage>")


def test_kcov_shape_reads_classes_and_lines() raises:
    # The trimmed real kcov report: XML declaration, DOCTYPE, tabs, every
    # rate attribute; filenames kept exactly as written (mapping is paths.mojo).
    var fs = parse_cobertura(read_text(String(FIXTURES) + "kcov_trimmed.xml"), String("kcov.xml"))
    assert_equal(len(fs), 3)
    assert_equal(fs[0].path, "tests/test_refusals.mojo")
    assert_equal(fs[0].line_found(), 3)
    assert_equal(fs[0].line_hit(), 2)
    assert_equal(fs[1].path, "buck-out/v2/art/komira/src/komira_retry/__komira_retry__/fedcba9876543210/src/komira_retry/budget.mojo")
    assert_equal(fs[1].line_hit(), 3)
    assert_equal(fs[2].hits[143], 0)


def test_rate_attributes_make_no_branches() raises:
    # kcov writes branch-rate="1.0" with no branch data: no branch is counted.
    var fs = parse_cobertura(read_text(String(FIXTURES) + "kcov_trimmed.xml"), String("kcov.xml"))
    for i in range(len(fs)):
        assert_equal(fs[i].branch_found(), 0)


def test_cobertura_equals_lcov() raises:
    # The same data as Cobertura (with a <method> whose lines repeat the
    # class's, single quotes, attributes out of order, an explicit </line>)
    # and as lcov: identical lines, hits and per-line branches.
    var c = parse_cobertura(read_text(String(FIXTURES) + "equiv.xml"), String("equiv.xml"))
    var l = parse_lcov(read_text(String(FIXTURES) + "equiv.info"), String("equiv.info"))
    assert_equal(shape(c), shape(l))
    assert_equal(shape(c), String("src/alpha/a.mojo: 1=3 2=1 3=4 b2=1/2\nsrc/alpha/b.mojo: 7=0\n"))


def test_condition_coverage_counts_branches() raises:
    var fs = parse_cobertura(_doc(String("<line number=\"4\" hits=\"2\" branch=\"true\" condition-coverage=\"25% (1/4)\"/>")), String("c.xml"))
    assert_equal(fs[0].branch_found(), 4)
    assert_equal(fs[0].branch_hit(), 1)


def test_entities_in_attribute_values() raises:
    var t = String("<coverage><classes><class filename=\"a&amp;b &lt;&gt;&quot;&apos;.mojo\"><lines><line number=\"1\" hits=\"0\"/></lines></class></classes></coverage>")
    var fs = parse_cobertura(t, String("c.xml"))
    assert_equal(fs[0].path, "a&b <>\"'.mojo")


def test_two_classes_same_file_sum() raises:
    var t = String(
        "<coverage><classes><class filename=\"x.mojo\"><lines><line number=\"1\" hits=\"0\"/></lines></class>"
        "<class filename=\"x.mojo\"><lines><line number=\"1\" hits=\"2\"/><line number=\"2\" hits=\"0\"/></lines></class></classes></coverage>"
    )
    var fs = parse_cobertura(t, String("c.xml"))
    assert_equal(len(fs), 1)
    assert_equal(fs[0].hits[1], 2)
    assert_equal(fs[0].line_found(), 2)


def test_refusals() raises:
    _refused(_doc(String("<line number=\"1\" hits=\"1\"")), String("unterminated"))
    _refused(_doc(String("<line hits=\"1\"/>")), String("<line> has no number"))
    _refused(_doc(String("<line number=\"1\"/>")), String("<line> has no hits"))
    _refused(_doc(String("<line number=\"1\" hits=\"x\"/>")), String("hits='x' is not a decimal number"))
    _refused(_doc(String("<line number=\"1.5\" hits=\"1\"/>")), String("number='1.5'"))
    _refused(_doc(String("<line number=\"1\" hits=\"-1\"/>")), String("hits='-1'"))
    _refused(_doc(String("<line number=\"1\" hits=\"1\" branch=\"true\"/>")), String("no condition-coverage"))
    _refused(_doc(String("<line number=\"1\" hits=\"1\" branch=\"true\" condition-coverage=\"50%\"/>")), String("is not 'NN% (k/n)'"))
    _refused(_doc(String("<line number=\"1\" hits=\"1\" branch=\"true\" condition-coverage=\"50% (3/2)\"/>")), String("k <= n"))
    _refused(_doc(String("<line number=\"1\" hits=\"1\" branch=\"yes\"/>")), String("not true or false"))
    _refused(_doc(String("<line number=1 hits=\"1\"/>")), String("is not quoted"))
    _refused(String("<coverage><classes></class></coverage>"), String("</class> closes <classes>"))
    _refused(String("<coverage><x a=\"&nbsp;\"/></coverage>"), String("unknown entity"))
    _refused(String("<report></report>"), String("not <coverage>"))
    _refused(String("<coverage><classes><class name=\"x\"/></classes></coverage>"), String("no filename"))
    _refused(String("<coverage>"), String("<coverage> is never closed"))
    _refused(String("<coverage><!-- x</coverage>"), String("unterminated comment"))
    _refused(String(""), String("no <coverage> element"))
    _refused(_doc(String("<line number=\"1\" number=\"2\" hits=\"0\"/>")), String("attribute number of <line> is given twice"))
    _refused(_doc(String("<line number=\"1\" hits=\"0\" branch=\"true\" condition-coverage=\"0% (0/999999999999999999)\"/>")), String("more than 4096 branches"))
    _refused(_doc(String("<line number=\"1000000001\" hits=\"0\"/>")), String("<line> number 1000000001 is above 10^9"))
    _refused(String("<coverage><x a=\"&#65;\"/></coverage>"), String("unknown entity"))
    _refused(String("\xef\xbb\xbf<coverage></coverage>"), String("text outside the root element"))


def test_refusal_names_the_line() raises:
    _refused(String("<coverage>\n<classes>\n<class filename=\"x\">\n<lines>\n<line number=\"1\" hits=\"z\"/>\n</lines></class></classes></coverage>"), String("c.xml:5:"))


def main() raises:
    test_kcov_shape_reads_classes_and_lines()
    test_rate_attributes_make_no_branches()
    test_cobertura_equals_lcov()
    test_condition_coverage_counts_branches()
    test_entities_in_attribute_values()
    test_two_classes_same_file_sum()
    test_refusals()
    test_refusal_names_the_line()
    print("test_cobertura: PASS")
