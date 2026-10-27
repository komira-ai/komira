# =============================================================================
# test_harness.mojo -- the RESULT line and the command line of komira_bench
# =============================================================================
#
# What it proves, and the defect each case would catch:
#   result_line     the exact text of a line: a changed separator, a dropped
#                   parameter, a metric without its `=`, or a hidden value that
#                   prints a number.
#   parse_args      the defaults when nothing is given; each flag alone and
#                   together; a flag given twice keeps the last; a flag that is
#                   not known, a number that is not positive or not a number,
#                   and an empty list of capacities are refused by name (a
#                   benchmark must not run with settings the user did not mean).
#   usage           names every flag and the defaults it was given.
# No case reads a clock: the values passed to result_line are constants.
# =============================================================================

from std.sys import argv
from std.testing import assert_equal, assert_false, assert_true

from komira_bench.harness import (
    BenchArgs,
    Param,
    command_line,
    parse_args,
    result_line,
    usage,
    without_program,
)


def _caps(a: Int, b: Int) -> List[Int]:
    var c = List[Int]()
    c.append(a)
    c.append(b)
    return c^


def _refused(args: List[String]) -> String:
    """The message parse_args raises with, or `ACCEPTED` when it does not."""
    try:
        _ = parse_args(args, 1000, _caps(8, 16))
    except e:
        return String(e)
    return String("ACCEPTED")


def _one(a: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    return l^


def test_result_line_shape() raises:
    var params = List[Param]()
    params.append(Param("cap", 1024))
    assert_equal(
        result_line("push_pop", params, "ns_per_op", 11.25),
        "RESULT push_pop cap=1024 ns_per_op=11.25",
    )
    params.append(Param("threads", 2))
    assert_equal(
        result_line("push_pop", params, "ns_per_op", 0.5),
        "RESULT push_pop cap=1024 threads=2 ns_per_op=0.5",
    )
    assert_equal(
        result_line("drain", List[Param](), "ns_per_unit", 3.0),
        "RESULT drain ns_per_unit=3.0",
    )


def test_result_line_hides_the_value() raises:
    var params = List[Param]()
    params.append(Param("cap", 64))
    assert_equal(
        result_line("push_only", params, "ns_per_op", 123.456, True),
        "RESULT push_only cap=64 ns_per_op=-",
    )


def test_defaults() raises:
    var a = parse_args(List[String](), 1000, _caps(8, 16))
    assert_equal(a.total_ops, 1000)
    assert_equal(len(a.caps), 2)
    assert_equal(a.caps[0], 8)
    assert_equal(a.caps[1], 16)
    assert_false(a.hide_times)
    assert_false(a.help)


def test_each_flag() raises:
    var a = parse_args(_one("--total-ops=5000"), 1000, _caps(8, 16))
    assert_equal(a.total_ops, 5000)
    assert_equal(len(a.caps), 2)
    var b = parse_args(_one("--caps=64,1024,4096"), 1000, _caps(8, 16))
    assert_equal(len(b.caps), 3)
    assert_equal(b.caps[0], 64)
    assert_equal(b.caps[2], 4096)
    assert_equal(b.total_ops, 1000)
    var c = parse_args(_one("--hide-times"), 1000, _caps(8, 16))
    assert_true(c.hide_times)
    assert_false(c.help)
    assert_true(parse_args(_one("--help"), 1000, _caps(8, 16)).help)
    assert_true(parse_args(_one("-h"), 1000, _caps(8, 16)).help)


def test_flags_together_and_repeated() raises:
    var args = List[String]()
    args.append("--caps=2,4")
    args.append("--hide-times")
    args.append("--total-ops=7")
    args.append("--caps=32")
    args.append("--total-ops=9")
    var a = parse_args(args, 1000, _caps(8, 16))
    assert_equal(a.total_ops, 9)
    assert_equal(len(a.caps), 1)
    assert_equal(a.caps[0], 32)
    assert_true(a.hide_times)


def test_refusals_name_the_argument() raises:
    assert_equal(
        _refused(_one("--bogus")),
        "komira_bench: unknown argument '--bogus' (try --help)",
    )
    assert_equal(
        _refused(_one("--total-ops")),
        "komira_bench: unknown argument '--total-ops' (try --help)",
    )
    var want = "komira_bench: --total-ops must be a positive integer, got '"
    assert_equal(_refused(_one("--total-ops=0")), want + "0'")
    assert_equal(_refused(_one("--total-ops=-5")), want + "-5'")
    assert_equal(_refused(_one("--total-ops=12x")), want + "12x'")
    assert_equal(_refused(_one("--total-ops=")), want + "'")
    var wantc = "komira_bench: --caps must be a positive integer, got '"
    assert_equal(_refused(_one("--caps=")), wantc + "'")
    assert_equal(_refused(_one("--caps=64,,128")), wantc + "'")
    assert_equal(_refused(_one("--caps=64,zero")), wantc + "zero'")
    assert_equal(_refused(_one("--caps=64,0")), wantc + "0'")


def test_usage_names_the_flags_and_defaults() raises:
    var text = usage("spsc_ring", 1000, _caps(8, 16))
    assert_true(text.startswith("usage: spsc_ring "))
    assert_true("--total-ops=N" in text)
    assert_true("(default 1000)" in text)
    assert_true("--caps=A,B,..." in text)
    assert_true("(default 8,16)" in text)
    assert_true("--hide-times" in text)
    assert_true("--help" in text)


def test_the_program_name_is_dropped() raises:
    var all = List[String]()
    all.append("prog")
    all.append("--a")
    all.append("--b")
    var rest = without_program(all)
    assert_equal(len(rest), 2)
    assert_equal(rest[0], "--a")
    assert_equal(rest[1], "--b")
    assert_equal(len(without_program(_one("prog"))), 0)
    assert_equal(len(without_program(List[String]())), 0)
    # The process's own command line is argv without its first entry.
    assert_equal(len(command_line()), len(argv()) - 1)


def main() raises:
    test_result_line_shape()
    test_result_line_hides_the_value()
    test_defaults()
    test_each_flag()
    test_flags_together_and_repeated()
    test_refusals_name_the_argument()
    test_usage_names_the_flags_and_defaults()
    test_the_program_name_is_dropped()
    print("ALL TESTS PASS")
