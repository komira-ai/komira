# =============================================================================
# test_harness.mojo -- the RESULT line and the command line of komira_bench
# =============================================================================
#
# What it proves, and the defect each case would catch:
#   result_line     the exact text of a line: a changed separator, a dropped
#                   parameter, a metric without its `=`, or a hidden value that
#                   prints a number; and the refusals that keep the line one
#                   shape: an op, parameter name or metric that is empty or
#                   holds a space, `=`, `:`, `~`, a line break or an upper-case
#                   letter, a parameter name given twice, a shown value that is
#                   `nan` or infinite (a hidden one is `-` whatever it was).
#   BenchArgs       refuses settings no program can run with: a count below 1,
#                   no capacity, a capacity below 1.
#   parse_args      the defaults when nothing is given, held in a list of their
#                   own; each flag alone and together; a flag given twice keeps
#                   the last, and both values are checked; `--help` does not
#                   excuse a bad argument before or after it; the number
#                   grammar: 1 and the largest Int are taken, and a sign, a
#                   space, a number past the largest Int, zero, a non-number and
#                   an empty value are refused, for both numeric flags; an empty
#                   capacity list and an empty first, middle or last element
#                   are refused; defaults that are not valid settings are
#                   refused.
#   usage           its exact text for given defaults.
# No case reads a clock: the values passed to result_line are constants.
# =============================================================================

from std.math import inf, nan
from std.sys import argv
from std.testing import assert_equal, assert_false, assert_true

from komira_bench.harness import (
    BenchArgs,
    Param,
    _without_program,
    command_line,
    parse_args,
    result_line,
    usage,
)


def _caps(a: Int, b: Int) -> List[Int]:
    var c = List[Int]()
    c.append(a)
    c.append(b)
    return c^


def _list(*items: String) -> List[String]:
    var out = List[String]()
    for item in items:
        out.append(String(item))
    return out^


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


def _cap_param(name: String) -> List[Param]:
    var p = List[Param]()
    p.append(Param(name, 64))
    return p^


def _line_refused(
    op: String, params: List[Param], metric: String, value: Float64
) -> String:
    """The message result_line raises with (values shown), or `ACCEPTED`."""
    try:
        _ = result_line(op, params, metric, value)
    except e:
        return String(e)
    return String("ACCEPTED")


def _args_refused(total_ops: Int, var caps: List[Int]) -> String:
    """The message BenchArgs raises with, or `ACCEPTED`."""
    try:
        _ = BenchArgs(total_ops, caps^)
    except e:
        return String(e)
    return String("ACCEPTED")


def _number_message(flag: String, text: String) -> String:
    return (
        "komira_bench: "
        + flag
        + " must be a positive integer (decimal digits, at most"
        + " 9223372036854775807), got '"
        + text
        + "'"
    )


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
    # Every character a token may hold: a-z, 0-9 and `_`.
    assert_equal(
        result_line("op_09az", _cap_param("k_2"), "m_0", 0.0),
        "RESULT op_09az k_2=64 m_0=0.0",
    )


def test_result_line_hides_the_value() raises:
    var params = List[Param]()
    params.append(Param("cap", 64))
    assert_equal(
        result_line("push_only", params, "ns_per_op", 123.456, True),
        "RESULT push_only cap=64 ns_per_op=-",
    )
    # A hidden value is `-` even when it is not a number.
    assert_equal(
        result_line("push_only", params, "ns_per_op", nan[DType.float64](), True),
        "RESULT push_only cap=64 ns_per_op=-",
    )


def test_result_line_refuses_what_would_break_its_shape() raises:
    var none = List[Param]()
    var p = _cap_param("cap")
    assert_equal(
        _line_refused("", p, "ns_per_op", 1.0),
        "komira_bench: a RESULT op is one or more of a-z, 0-9 and _, got ''",
    )
    assert_equal(
        _line_refused("push pop", p, "ns_per_op", 1.0),
        "komira_bench: a RESULT op is one or more of a-z, 0-9 and _, got"
        " 'push pop'",
    )
    assert_equal(
        _line_refused("Push", p, "ns_per_op", 1.0),
        "komira_bench: a RESULT op is one or more of a-z, 0-9 and _, got"
        " 'Push'",
    )
    # The bytes either side of `a`-`z` (`` ` ``, `{`), of `0`-`9` (`/`, `:`)
    # and of `_` (`^`, `` ` ``), and one far above `z` (`~`).
    var neighbours = List[String]()
    neighbours.append("`")
    neighbours.append("{")
    neighbours.append("/")
    neighbours.append("@")
    neighbours.append("[")
    neighbours.append("^")
    for i in range(len(neighbours)):
        assert_equal(
            _line_refused("op" + neighbours[i], p, "ns_per_op", 1.0),
            "komira_bench: a RESULT op is one or more of a-z, 0-9 and _, got 'op"
            + neighbours[i]
            + "'",
        )
    assert_equal(
        _line_refused("op~", p, "ns_per_op", 1.0),
        "komira_bench: a RESULT op is one or more of a-z, 0-9 and _, got"
        " 'op~'",
    )
    assert_equal(
        _line_refused("push_pop", _cap_param("k:v"), "ns_per_op", 1.0),
        "komira_bench: a RESULT parameter name is one or more of a-z, 0-9 and"
        " _, got 'k:v'",
    )
    assert_equal(
        _line_refused("push_pop", _cap_param("a=b"), "ns_per_op", 1.0),
        "komira_bench: a RESULT parameter name is one or more of a-z, 0-9 and"
        " _, got 'a=b'",
    )
    assert_equal(
        _line_refused("push_pop", _cap_param(""), "ns_per_op", 1.0),
        "komira_bench: a RESULT parameter name is one or more of a-z, 0-9 and"
        " _, got ''",
    )
    assert_equal(
        _line_refused("push_pop", none, "ns\nper_op", 1.0),
        "komira_bench: a RESULT metric is one or more of a-z, 0-9 and _, got"
        " 'ns\nper_op'",
    )
    assert_equal(
        _line_refused("push_pop", none, "", 1.0),
        "komira_bench: a RESULT metric is one or more of a-z, 0-9 and _, got"
        " ''",
    )
    var twice = List[Param]()
    twice.append(Param("cap", 1))
    twice.append(Param("threads", 2))
    twice.append(Param("cap", 3))
    assert_equal(
        _line_refused("push_pop", twice, "ns_per_op", 1.0),
        "komira_bench: the RESULT parameter 'cap' is given twice",
    )
    var finite = "komira_bench: the RESULT value of 'ns_per_op' is not a finite number"
    assert_equal(_line_refused("push_pop", p, "ns_per_op", nan[DType.float64]()), finite)
    assert_equal(_line_refused("push_pop", p, "ns_per_op", inf[DType.float64]()), finite)
    assert_equal(_line_refused("push_pop", p, "ns_per_op", -inf[DType.float64]()), finite)


def test_bench_args_refuses_settings_no_program_runs_with() raises:
    assert_equal(_args_refused(1, _caps(1, 1)), "ACCEPTED")
    assert_equal(
        _args_refused(0, _caps(8, 16)),
        "komira_bench: total_ops must be at least 1, got 0",
    )
    assert_equal(
        _args_refused(-3, _caps(8, 16)),
        "komira_bench: total_ops must be at least 1, got -3",
    )
    assert_equal(
        _args_refused(10, List[Int]()),
        "komira_bench: caps must name at least one capacity",
    )
    assert_equal(
        _args_refused(10, _caps(8, 0)),
        "komira_bench: a capacity must be at least 1, got 0",
    )
    assert_equal(
        _args_refused(10, _caps(-1, 8)),
        "komira_bench: a capacity must be at least 1, got -1",
    )


def test_defaults() raises:
    var a = parse_args(List[String](), 1000, _caps(8, 16))
    assert_equal(a.total_ops, 1000)
    assert_equal(len(a.caps), 2)
    assert_equal(a.caps[0], 8)
    assert_equal(a.caps[1], 16)
    assert_false(a.hide_times)
    assert_false(a.help)


def test_parsed_capacities_are_a_list_of_their_own() raises:
    var defaults = _caps(8, 16)
    var a = parse_args(List[String](), 1000, defaults)
    var b = parse_args(List[String](), 1000, defaults)
    a.caps[0] = 4096
    a.caps.append(2)
    assert_equal(defaults[0], 8)
    assert_equal(len(defaults), 2)
    assert_equal(b.caps[0], 8)
    assert_equal(len(b.caps), 2)


def test_defaults_that_are_not_settings_are_refused() raises:
    var message = String("ACCEPTED")
    try:
        _ = parse_args(List[String](), 0, _caps(8, 16))
    except e:
        message = String(e)
    assert_equal(message, "komira_bench: total_ops must be at least 1, got 0")
    message = String("ACCEPTED")
    try:
        _ = parse_args(_one("--caps=8"), 1000, List[Int]())
    except e:
        message = String(e)
    # Checked before the command line is read: `--caps` would replace them.
    assert_equal(message, "komira_bench: caps must name at least one capacity")


def test_each_flag() raises:
    var a = parse_args(_one("--total-ops=5000"), 1000, _caps(8, 16))
    assert_equal(a.total_ops, 5000)
    assert_equal(len(a.caps), 2)
    var b = parse_args(_one("--caps=64,1024,4096"), 1000, _caps(8, 16))
    assert_equal(len(b.caps), 3)
    assert_equal(b.caps[0], 64)
    assert_equal(b.caps[1], 1024)
    assert_equal(b.caps[2], 4096)
    assert_equal(b.total_ops, 1000)
    var c = parse_args(_one("--hide-times"), 1000, _caps(8, 16))
    assert_true(c.hide_times)
    assert_false(c.help)
    assert_true(parse_args(_one("--help"), 1000, _caps(8, 16)).help)
    assert_true(parse_args(_one("-h"), 1000, _caps(8, 16)).help)


def test_capacities_keep_their_order_and_repeats() raises:
    var a = parse_args(_one("--caps=16,8,16"), 1000, _caps(8, 16))
    assert_equal(len(a.caps), 3)
    assert_equal(a.caps[0], 16)
    assert_equal(a.caps[1], 8)
    assert_equal(a.caps[2], 16)


def test_flags_together_and_repeated() raises:
    var a = parse_args(
        _list("--caps=2,4", "--hide-times", "--total-ops=7", "--caps=32", "--total-ops=9"),
        1000,
        _caps(8, 16),
    )
    assert_equal(a.total_ops, 9)
    assert_equal(len(a.caps), 1)
    assert_equal(a.caps[0], 32)
    assert_true(a.hide_times)
    assert_false(a.help)
    var h = parse_args(_list("--total-ops=7", "-h", "--hide-times"), 1000, _caps(8, 16))
    assert_true(h.help)
    assert_true(h.hide_times)
    assert_equal(h.total_ops, 7)


def test_every_occurrence_of_a_flag_is_checked() raises:
    var bad_ops = _number_message("--total-ops", "0")
    assert_equal(_refused(_list("--total-ops=0", "--total-ops=5")), bad_ops)
    assert_equal(_refused(_list("--total-ops=5", "--total-ops=0")), bad_ops)
    var bad_cap = _number_message("--caps", "x")
    assert_equal(_refused(_list("--caps=x", "--caps=8")), bad_cap)
    assert_equal(_refused(_list("--caps=8", "--caps=x")), bad_cap)


def test_help_does_not_excuse_a_bad_argument() raises:
    var unknown = "komira_bench: unknown argument '--bogus' (try --help)"
    assert_equal(_refused(_list("--help", "--bogus")), unknown)
    assert_equal(_refused(_list("--bogus", "--help")), unknown)
    assert_equal(_refused(_list("-h", "--total-ops=-1")), _number_message("--total-ops", "-1"))
    # The first refused argument is the error.
    assert_equal(_refused(_list("--bogus", "--total-ops=0")), unknown)


def test_refusals_name_the_argument() raises:
    assert_equal(
        _refused(_one("--bogus")),
        "komira_bench: unknown argument '--bogus' (try --help)",
    )
    assert_equal(
        _refused(_one("--total-ops")),
        "komira_bench: unknown argument '--total-ops' (try --help)",
    )
    assert_equal(
        _refused(_one("--caps")),
        "komira_bench: unknown argument '--caps' (try --help)",
    )
    assert_equal(
        _refused(_one("")),
        "komira_bench: unknown argument '' (try --help)",
    )


def test_the_number_grammar() raises:
    # Taken: the least and the largest positive Int, and a leading zero.
    assert_equal(parse_args(_one("--total-ops=1"), 1000, _caps(8, 16)).total_ops, 1)
    assert_equal(
        parse_args(_one("--total-ops=9223372036854775807"), 1000, _caps(8, 16)).total_ops,
        9223372036854775807,
    )
    assert_equal(parse_args(_one("--total-ops=007"), 1000, _caps(8, 16)).total_ops, 7)
    assert_equal(parse_args(_one("--caps=1"), 1000, _caps(8, 16)).caps[0], 1)
    # Refused, for both numeric flags: each is a value no program should guess at.
    var bad = List[String]()
    bad.append("0")
    bad.append("00")
    bad.append("-5")
    bad.append("+5")
    bad.append(" 5")
    bad.append("5 ")
    bad.append("12x")
    bad.append("1.5")
    bad.append("1e3")
    # The bytes either side of `0`-`9`.
    bad.append("/")
    bad.append(":")
    bad.append("1:")
    bad.append("")
    bad.append("9223372036854775808")
    bad.append("99999999999999999999")
    for i in range(len(bad)):
        var v = bad[i]
        assert_equal(_refused(_one("--total-ops=" + v)), _number_message("--total-ops", v))
        assert_equal(_refused(_one("--caps=" + v)), _number_message("--caps", v))
        assert_equal(_refused(_one("--caps=8," + v)), _number_message("--caps", v))


def test_empty_capacity_elements_are_refused() raises:
    var empty = _number_message("--caps", "")
    assert_equal(_refused(_one("--caps=")), empty)
    assert_equal(_refused(_one("--caps=,64")), empty)
    assert_equal(_refused(_one("--caps=64,")), empty)
    assert_equal(_refused(_one("--caps=64,,128")), empty)
    assert_equal(_refused(_one("--caps=,")), empty)


def test_usage_is_exact() raises:
    assert_equal(
        usage("spsc_ring", 1000, _caps(8, 16)),
        "usage: spsc_ring [--total-ops=N] [--caps=A,B,...] [--hide-times] [--help]\n"
        "  --total-ops=N   operations per measurement (default 1000)\n"
        "  --caps=A,B,...  capacities to measure (default 8,16)\n"
        "  --hide-times    print `-` for every measured value, so the output is"
        " the same on every machine\n"
        "  --help, -h      this text",
    )


def test_the_program_name_is_dropped() raises:
    var rest = _without_program(_list("prog", "--a", "--b"))
    assert_equal(len(rest), 2)
    assert_equal(rest[0], "--a")
    assert_equal(rest[1], "--b")
    assert_equal(len(_without_program(_one("prog"))), 0)
    assert_equal(len(_without_program(List[String]())), 0)
    # The process's own command line is argv without its first entry.
    assert_equal(len(command_line()), len(argv()) - 1)


def main() raises:
    test_result_line_shape()
    test_result_line_hides_the_value()
    test_result_line_refuses_what_would_break_its_shape()
    test_bench_args_refuses_settings_no_program_runs_with()
    test_defaults()
    test_parsed_capacities_are_a_list_of_their_own()
    test_defaults_that_are_not_settings_are_refused()
    test_each_flag()
    test_capacities_keep_their_order_and_repeats()
    test_flags_together_and_repeated()
    test_every_occurrence_of_a_flag_is_checked()
    test_help_does_not_excuse_a_bad_argument()
    test_refusals_name_the_argument()
    test_the_number_grammar()
    test_empty_capacity_elements_are_refused()
    test_usage_is_exact()
    test_the_program_name_is_dropped()
    print("ALL TESTS PASS")
