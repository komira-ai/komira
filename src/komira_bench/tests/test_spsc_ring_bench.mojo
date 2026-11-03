# =============================================================================
# test_spsc_ring_bench.mojo -- the spsc_ring benchmark runs and prints its lines
# =============================================================================
#
# The benchmark is run for real on a few records, through the same functions
# the program calls. It proves the shape of what comes out, how many operations
# each measurement timed, and that the three measurements complete (push_pop's
# consumer stops only after it has popped every record, so a ring that lost one
# would never return and the test would be stopped by the hang limit); it
# asserts nothing about a time. Cases:
#   - the program's defaults and its exact `--help` and `-h` text;
#   - three lines, in the order push_only, push_pop, drop_push, each with the
#     capacity it was run at and a value that is a finite number of at least 0;
#   - with the times hidden the three lines are exactly the expected text;
#   - every measurement times exactly `total_ops` operations: below, at and
#     above one round of push_only, a partial last round, one operation, a
#     capacity above the record count; push_pop pops every record; every timed
#     drop_push is refused (the ring is full to its own capacity);
#   - capacities are measured in the order given, a repeated one again;
#   - a capacity that is not a power of two from 1 to MAX_CAP (one the ring
#     would round, or one whose rounding would overflow) is refused by name
#     before any ring is made, `--help` or not, where it stands: a later
#     `--caps` does not excuse it and a later bad argument is not reported
#     first;
#   - push_only's rounds are two counters, also at the largest counts (no
#     round is stored or run to check them).
# =============================================================================

from std.math import isfinite
from std.testing import assert_equal, assert_true

from komira_bench.harness import BenchArgs
from komira_bench.spsc_ring_bench import (
    DEFAULT_TOTAL_OPS,
    MAX_CAP,
    _bench_lines,
    _drop_push,
    _push_only,
    _Rounds,
    _push_pop,
    default_caps,
    program_lines,
    run_program,
)


def _args(total_ops: Int, hide: Bool) raises -> BenchArgs:
    var a = BenchArgs(total_ops, default_caps())
    a.hide_times = hide
    return a^


def _list(*items: String) -> List[String]:
    var out = List[String]()
    for item in items:
        out.append(String(item))
    return out^


def _value(line: String, prefix: String) raises -> Float64:
    """The value after `prefix` in `line`, which must start with it; raises
    unless that value is a finite number of at least 0."""
    assert_true(line.startswith(prefix), line)
    var text = String(line[byte = prefix.byte_length() : line.byte_length()])
    var v = atof(text)
    assert_true(isfinite(v) and v >= 0.0, line)
    return v


def _refused(arguments: List[String]) -> String:
    try:
        _ = program_lines(arguments)
    except e:
        return String(e)
    return String("ACCEPTED")


def test_the_programs_defaults() raises:
    assert_equal(DEFAULT_TOTAL_OPS, 20_000_000)
    var caps = default_caps()
    assert_equal(len(caps), 4)
    assert_equal(caps[0], 64)
    assert_equal(caps[1], 1024)
    assert_equal(caps[2], 4096)
    assert_equal(caps[3], 65536)
    assert_equal(MAX_CAP, 16777216)


def test_program_help_is_the_exact_usage_text() raises:
    var want = (
        "usage: spsc_ring [--total-ops=N] [--caps=A,B,...] [--hide-times] [--help]\n"
        "  --total-ops=N   operations per measurement (default 20000000)\n"
        "  --caps=A,B,...  capacities to measure (default 64,1024,4096,65536)\n"
        "  --hide-times    print `-` for every measured value, so the output is"
        " the same on every machine\n"
        "  --help, -h      this text"
    )
    var lines = program_lines(_list("--help"))
    assert_equal(len(lines), 1)
    assert_equal(lines[0], want)
    var short = program_lines(_list("-h", "--total-ops=100"))
    assert_equal(len(short), 1)
    assert_equal(short[0], want)


def test_three_lines_with_a_value() raises:
    var lines = _bench_lines(64, _args(2048, False))
    assert_equal(len(lines), 3)
    _ = _value(lines[0], "RESULT push_only cap=64 ns_per_op=")
    _ = _value(lines[1], "RESULT push_pop cap=64 ns_per_op=")
    _ = _value(lines[2], "RESULT drop_push cap=64 ns_per_op=")


def test_hidden_times_are_exact() raises:
    var lines = _bench_lines(64, _args(2048, True))
    assert_equal(len(lines), 3)
    assert_equal(lines[0], "RESULT push_only cap=64 ns_per_op=-")
    assert_equal(lines[1], "RESULT push_pop cap=64 ns_per_op=-")
    assert_equal(lines[2], "RESULT drop_push cap=64 ns_per_op=-")


def _sizes(r: _Rounds) -> List[Int]:
    var out = List[Int]()
    for k in range(r.count()):
        out.append(r.size(k))
    return out^


def test_push_only_rounds_add_up_to_total_ops() raises:
    var below = _sizes(_Rounds(64, 63))
    assert_equal(len(below), 1)
    assert_equal(below[0], 63)
    var at = _sizes(_Rounds(64, 64))
    assert_equal(len(at), 1)
    assert_equal(at[0], 64)
    var above = _sizes(_Rounds(64, 65))
    assert_equal(len(above), 2)
    assert_equal(above[0], 64)
    assert_equal(above[1], 1)
    var two = _sizes(_Rounds(64, 128))
    assert_equal(len(two), 2)
    assert_equal(two[0], 64)
    assert_equal(two[1], 64)
    var one = _sizes(_Rounds(4096, 1))
    assert_equal(len(one), 1)
    assert_equal(one[0], 1)


def test_push_only_rounds_at_the_largest_counts() raises:
    # Counted, never listed: the largest supported counts take two numbers,
    # and no round is run or stored here.
    var max_int = 9223372036854775807
    var each = _Rounds(1, max_int)
    assert_equal(each.count(), max_int)
    assert_equal(each.size(0), 1)
    assert_equal(each.size(max_int - 1), 1)
    var big = _Rounds(64, max_int)
    assert_equal(big.full, 144115188075855871)
    assert_equal(big.last, 63)
    assert_equal(big.count(), 144115188075855872)
    assert_equal(big.size(144115188075855870), 64)
    assert_equal(big.size(144115188075855871), 63)
    var widest = _Rounds(16777216, max_int)
    assert_equal(widest.full * 16777216 + widest.last, max_int)
    assert_equal(widest.size(widest.count() - 1), widest.last)


def test_each_measurement_times_exactly_total_ops() raises:
    var cases = List[Int]()
    cases.append(1)
    cases.append(63)
    cases.append(64)
    cases.append(65)
    cases.append(100)
    for i in range(len(cases)):
        var n = cases[i]
        assert_equal(_push_only(64, n).ops, n)
        assert_equal(_push_pop(64, n).ops, n)
        assert_equal(_drop_push(64, n).ops, n)
    # A capacity above the record count, and the smallest ring.
    assert_equal(_push_only(4096, 100).ops, 100)
    assert_equal(_drop_push(4096, 100).ops, 100)
    assert_equal(_push_only(1, 5).ops, 5)
    assert_equal(_push_pop(1, 5).ops, 5)
    assert_equal(_drop_push(1, 5).ops, 5)


def test_capacity_above_the_record_count() raises:
    var lines = _bench_lines(4096, _args(100, True))
    assert_equal(len(lines), 3)
    assert_equal(lines[0], "RESULT push_only cap=4096 ns_per_op=-")
    assert_equal(lines[1], "RESULT push_pop cap=4096 ns_per_op=-")
    assert_equal(lines[2], "RESULT drop_push cap=4096 ns_per_op=-")
    # With the values shown each is a finite number: push_only with no round
    # would divide zero by zero. (No value is compared with a time.)
    var shown = _bench_lines(4096, _args(100, False))
    _ = _value(shown[0], "RESULT push_only cap=4096 ns_per_op=")
    _ = _value(shown[1], "RESULT push_pop cap=4096 ns_per_op=")
    _ = _value(shown[2], "RESULT drop_push cap=4096 ns_per_op=")


def test_program_lines_keep_the_order_and_repeats_given() raises:
    var lines = program_lines(_list("--total-ops=100", "--caps=16,8,16", "--hide-times"))
    assert_equal(len(lines), 9)
    var caps = List[String]()
    caps.append("16")
    caps.append("8")
    caps.append("16")
    for c in range(3):
        assert_equal(lines[3 * c], "RESULT push_only cap=" + caps[c] + " ns_per_op=-")
        assert_equal(lines[3 * c + 1], "RESULT push_pop cap=" + caps[c] + " ns_per_op=-")
        assert_equal(lines[3 * c + 2], "RESULT drop_push cap=" + caps[c] + " ns_per_op=-")


def test_a_capacity_that_is_not_a_power_of_two_in_range_is_refused() raises:
    var want = "komira_bench: spsc_ring --caps takes powers of two from 1 to 16777216, got "
    assert_equal(_refused(_list("--caps=3")), want + "3")
    assert_equal(_refused(_list("--caps=64,100")), want + "100")
    assert_equal(_refused(_list("--caps=16777217")), want + "16777217")
    assert_equal(_refused(_list("--caps=33554432")), want + "33554432")
    # Its next power of two does not fit in an Int: refused, never rounded.
    assert_equal(_refused(_list("--caps=4611686018427387905")), want + "4611686018427387905")
    assert_equal(_refused(_list("--help", "--caps=3")), want + "3")
    # Each `--caps` is held to the rule where it stands: a later one that would
    # pass does not excuse it, and a later bad argument is not reported first.
    assert_equal(_refused(_list("--caps=3", "--caps=8")), want + "3")
    assert_equal(_refused(_list("--caps=3", "--caps=8", "--help")), want + "3")
    assert_equal(_refused(_list("--help", "--caps=3", "--caps=8")), want + "3")
    assert_equal(_refused(_list("--caps=33554432", "--caps=8")), want + "33554432")
    assert_equal(_refused(_list("--caps=3", "--bogus")), want + "3")
    assert_equal(_refused(_list("--caps=3", "--total-ops=0", "--help")), want + "3")
    # And the other way round: an earlier bad argument is the error.
    assert_equal(
        _refused(_list("--bogus", "--caps=3")),
        "komira_bench: unknown argument '--bogus' (try --help)",
    )
    assert_equal(_refused(_list("--caps=8", "--caps=3")), want + "3")
    # A valid repeat is still the last value.
    var kept = program_lines(_list("--caps=8", "--caps=16", "--total-ops=10", "--hide-times"))
    assert_equal(len(kept), 3)
    assert_equal(kept[0], "RESULT push_only cap=16 ns_per_op=-")
    # The bounds themselves are taken (parsed only: nothing is measured).
    var lines = program_lines(_list("--caps=1,16777216", "--help"))
    assert_equal(len(lines), 1)


def test_program_refuses_a_bad_argument() raises:
    assert_equal(
        _refused(_list("--total-ops=0")),
        "komira_bench: --total-ops must be a positive integer (decimal digits,"
        " at most 9223372036854775807), got '0'",
    )
    assert_equal(
        _refused(_list("--bogus")),
        "komira_bench: unknown argument '--bogus' (try --help)",
    )


def test_run_program_prints_without_raising() raises:
    # What it prints is the lines `program_lines` returns (asserted above); the
    # program's own output is checked by :bins_smoke.
    run_program(_list("--total-ops=100", "--caps=8", "--hide-times"))


def main() raises:
    test_the_programs_defaults()
    test_program_help_is_the_exact_usage_text()
    test_three_lines_with_a_value()
    test_hidden_times_are_exact()
    test_push_only_rounds_add_up_to_total_ops()
    test_push_only_rounds_at_the_largest_counts()
    test_each_measurement_times_exactly_total_ops()
    test_capacity_above_the_record_count()
    test_program_lines_keep_the_order_and_repeats_given()
    test_a_capacity_that_is_not_a_power_of_two_in_range_is_refused()
    test_program_refuses_a_bad_argument()
    test_run_program_prints_without_raising()
    print("ALL TESTS PASS")
