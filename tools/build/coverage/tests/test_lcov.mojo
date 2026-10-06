from std.testing import assert_equal, assert_true

from covcheck.lcov import parse_lcov
from covcheck.model import FileCov
from covcheck.text import read_text

# The lcov reader: what a tracefile measures, and every shape it refuses.

comptime FIXTURES = "tools/build/coverage/tests/fixtures/"


def _hits(f: FileCov, line: Int) raises -> Int:
    return f.hits[line]


def _refused(text: String, want: String) raises:
    """`text` is refused with an error that holds `want`."""
    var raised = False
    try:
        _ = parse_lcov(text, String("t.info"))
    except e:
        raised = True
        var msg = String(e)
        assert_true(msg.find(want) >= 0, msg + String(" lacks ") + want)
    assert_true(raised, String("accepted: ") + text)


def test_basic_lines_and_branches() raises:
    # Two files; DA with and without a checksum; FN/FNDA/FNF/FNH are read and
    # ignored.
    var fs = parse_lcov(read_text(String(FIXTURES) + "basic.info"), String("basic.info"))
    assert_equal(len(fs), 2)
    assert_equal(fs[0].path, "/repo/src/alpha/a.mojo")
    assert_equal(fs[0].line_found(), 4)
    assert_equal(fs[0].line_hit(), 3)
    assert_equal(_hits(fs[0], 3), 0)
    assert_equal(_hits(fs[0], 4), 7)
    assert_equal(fs[0].branch_found(), 2)
    assert_equal(fs[0].branch_hit(), 1)
    assert_equal(fs[1].path, "src/alpha/b.mojo")
    assert_equal(fs[1].line_found(), 2)
    assert_equal(fs[1].line_hit(), 1)
    assert_equal(fs[1].branch_found(), 0)


def test_summary_records_that_lie_are_ignored() raises:
    # LF/LH/BRF/BRH claim 100 lines and 50 branches; the data has 2 and 1.
    var t = String("SF:x.mojo\nDA:1,1\nDA:2,0\nBRDA:1,0,0,1\nLF:100\nLH:100\nBRF:50\nBRH:50\nend_of_record\n")
    var fs = parse_lcov(t, String("t.info"))
    assert_equal(fs[0].line_found(), 2)
    assert_equal(fs[0].line_hit(), 1)
    assert_equal(fs[0].branch_found(), 1)
    assert_equal(fs[0].branch_hit(), 1)


def test_duplicate_sf_sums_hits() raises:
    # The same file in two records (two tests): per-line hits are summed, so
    # a line either test reached is covered; branches merge by key.
    var t = String(
        "TN:first\nSF:x.mojo\nDA:1,0\nDA:2,3\nBRDA:2,0,0,0\nBRDA:2,0,1,-\nend_of_record\n"
        "TN:second\nSF:x.mojo\nDA:1,2\nDA:3,0\nBRDA:2,0,0,4\nend_of_record\n"
    )
    var fs = parse_lcov(t, String("t.info"))
    assert_equal(len(fs), 1)
    assert_equal(_hits(fs[0], 1), 2)
    assert_equal(_hits(fs[0], 2), 3)
    assert_equal(_hits(fs[0], 3), 0)
    assert_equal(fs[0].line_found(), 3)
    assert_equal(fs[0].line_hit(), 2)
    assert_equal(fs[0].branch_found(), 2)
    assert_equal(fs[0].branch_hit(), 1)


def test_brda_dash_counts_as_not_taken() raises:
    # `-`: the block never ran. Both branches count in the denominator.
    var t = String("SF:x.mojo\nDA:1,0\nBRDA:1,0,0,-\nBRDA:1,0,1,-\nend_of_record\n")
    var fs = parse_lcov(t, String("t.info"))
    assert_equal(fs[0].branch_found(), 2)
    assert_equal(fs[0].branch_hit(), 0)


def test_brda_branch_id_with_commas() raises:
    # lcov 2 writes an expression as the branch id; it may hold commas.
    var t = String("SF:x.mojo\nBRDA:4,0,(a, b) - True,1\nBRDA:4,0,(a, b) - False,0\nend_of_record\n")
    var fs = parse_lcov(t, String("t.info"))
    assert_equal(fs[0].branch_found(), 2)
    assert_equal(fs[0].branch_hit(), 1)


def test_lcov2_exception_branches_and_function_records() raises:
    # lcov 2.x: `e` before a block marks an exception branch (its own
    # branch, apart from block 0); FNL/FNA are checked and ignored.
    var t = String(
        "SF:x.mojo\nFNL:0,3,9\nFNA:0,2,f\nFNL:1,12\nDA:3,1\nBRDA:3,0,0,1\nBRDA:3,e0,0,0\nBRDA:3,e0,1,-\nend_of_record\n"
    )
    var fs = parse_lcov(t, String("t.info"))
    assert_equal(fs[0].branch_found(), 3)
    assert_equal(fs[0].branch_hit(), 1)
    assert_true(String("3,e0,0") in fs[0].branches)
    _refused(String("SF:x\nFNL:0\nend_of_record\n"), String("t.info:2: FNL needs"))
    _refused(String("SF:x\nFNA:0,x,f\nend_of_record\n"), String("t.info:2: FNA count 'x'"))
    _refused(String("SF:x\nBRDA:3,ex,0,1\nend_of_record\n"), String("t.info:2: BRDA block 'x'"))


def test_refuses_unknown_record() raises:
    _refused(String("SF:x\nDA:1,1\nXYZ:3\nend_of_record\n"), String("t.info:3: unknown record type 'XYZ'"))


def test_refuses_carriage_return() raises:
    _refused(String("SF:x\r\nDA:1,1\nend_of_record\n"), String("t.info:1: carriage return"))


def test_refuses_missing_end_of_record() raises:
    _refused(String("SF:x\nDA:1,1\n"), String("t.info:2: the last record has no end_of_record"))
    _refused(String("SF:x\nDA:1,1\nSF:y\nend_of_record\n"), String("t.info:3: SF before the end_of_record"))


def test_refuses_bad_numbers() raises:
    _refused(String("SF:x\nDA:1,x\nend_of_record\n"), String("t.info:2: DA hits 'x'"))
    _refused(String("SF:x\nDA:-1,1\nend_of_record\n"), String("t.info:2: DA line '-1'"))
    _refused(String("SF:x\nDA:1,-3\nend_of_record\n"), String("t.info:2: DA hits '-3'"))
    _refused(String("SF:x\nDA:0,1\nend_of_record\n"), String("t.info:2: DA line 0"))
    _refused(String("SF:x\nBRDA:1,0,0,y\nend_of_record\n"), String("t.info:2: BRDA taken 'y'"))
    _refused(String("SF:x\nLF:many\nend_of_record\n"), String("t.info:2: LF 'many'"))
    _refused(String("SF:x\nDA:1\nend_of_record\n"), String("t.info:2: DA needs"))
    _refused(String("SF:x\nDA:1,99999999999999999999\nend_of_record\n"), String("t.info:2: DA hits"))
    _refused(String("SF:x\nDA:3,1,cksum,junk\nend_of_record\n"), String("t.info:2: DA needs <line>,<hits>[,<checksum>], not 4 fields"))
    _refused(String("SF:x\nDA:1000000001,1\nend_of_record\n"), String("t.info:2: DA line 1000000001 is above 10^9"))
    _refused(String("SF:x\nBRDA:1000000001,0,0,1\nend_of_record\n"), String("t.info:2: BRDA line 1000000001 is above 10^9"))


def test_refuses_data_outside_a_record() raises:
    _refused(String("DA:1,1\n"), String("t.info:1: DA outside SF .. end_of_record"))
    _refused(String("SF:x\nend_of_record\nBRDA:1,0,0,1\n"), String("t.info:3: BRDA outside"))
    _refused(String("end_of_record\n"), String("t.info:1: end_of_record outside a record"))
    _refused(String("garbage\n"), String("t.info:1: not a record"))


def main() raises:
    test_basic_lines_and_branches()
    test_summary_records_that_lie_are_ignored()
    test_duplicate_sf_sums_hits()
    test_brda_dash_counts_as_not_taken()
    test_brda_branch_id_with_commas()
    test_lcov2_exception_branches_and_function_records()
    test_refuses_unknown_record()
    test_refuses_carriage_return()
    test_refuses_missing_end_of_record()
    test_refuses_bad_numbers()
    test_refuses_data_outside_a_record()
    print("test_lcov: PASS")
