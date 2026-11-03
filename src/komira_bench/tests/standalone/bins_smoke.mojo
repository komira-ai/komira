# =============================================================================
# bins_smoke.mojo -- each program of komira_bench builds and runs once
# =============================================================================
#
# The program is this test's data (BUCK: `mojo_test` `bins_smoke`): komira's
# build of `bins/spsc_ring.mojo`, the file the package ships (`:conda_holds`
# holds the `.conda`'s copy to its bytes). Each run captures everything the
# program writes, standard error included, and how it ended. Nothing here reads
# or asserts a time: with `--hide-times` the value of every line is `-`, and a
# shown value is only required to be a finite number of at least 0.
#   - with the times hidden, the whole output is the three RESULT lines;
#   - with the values shown, the whole output is the three lines, in order,
#     each value a finite number;
#   - `--help` prints the usage text and exits 0;
#   - a refused argument exits with status 1 (not a signal, not a launch
#     failure such as the shell's 127) and prints no RESULT line; its last line
#     is exactly the Mojo runtime's report of the named error,
#     `Unhandled exception caught during execution: <error>`. (The runtime may
#     print a line about stack traces before it, which depends on the
#     environment, so only the last line is compared.)
#
# This is not one of the package's gated tests (tests/test_*.mojo): the program imports the
# gated library, so a gated test that ran it would wait for itself.
# =============================================================================

from std.ffi import external_call
from std.math import isfinite
from std.testing import assert_equal, assert_false, assert_true

comptime _PROGRAM = "bench/bin/spsc_ring_bench"


struct _Ran(Movable):
    """How a run ended: everything it wrote, and its wait status decoded."""

    var out: String
    var exited: Bool
    var code: Int
    var signal: Int

    def __init__(out self, var out: String, status: Int32):
        self.out = out^
        var s = Int(status)
        self.signal = s & 0x7F
        self.exited = self.signal == 0
        self.code = (s >> 8) & 0xFF


def _run(command: String) raises -> _Ran:
    """Runs `command` with its standard error joined to its standard output;
    raises only when the process could not be started or waited for."""
    var cmd = command + " 2>&1"
    var mode = String("r")
    # FFI-BOUNDARY: popen starts `cmd` and returns its FILE* (kept as an
    # address); fread fills `buf`, a local that outlives the call; pclose closes
    # the stream and returns the wait status. All three are owned here.
    var fp = external_call["popen", Int64](
        cmd.as_c_string_slice().unsafe_ptr(),
        mode.as_c_string_slice().unsafe_ptr(),
    )
    if fp == 0:
        raise Error("popen failed for " + command)
    var out = String()
    var buf = List[UInt8](length=4096, fill=UInt8(0))
    while True:
        # SAFETY: `buf` holds 4096 bytes and fread writes at most that many.
        var n = external_call["fread", Int64](
            buf.unsafe_ptr(), Int64(1), Int64(4096), fp
        )
        if n <= 0:
            break
        for i in range(Int(n)):
            out += chr(Int(buf[i]))
    var status = external_call["pclose", Int32](fp)
    if status == -1:
        raise Error("pclose failed for " + command)
    return _Ran(out^, status)


def _ok(ran: _Ran) raises:
    assert_true(ran.exited, "ended by signal " + String(ran.signal) + ": " + ran.out)
    assert_equal(ran.code, 0, ran.out)


def _value(line: String, prefix: String) raises:
    assert_true(line.startswith(prefix), line)
    var v = atof(String(line[byte = prefix.byte_length() : line.byte_length()]))
    assert_true(isfinite(v) and v >= 0.0, line)


def test_spsc_ring_prints_its_result_lines() raises:
    var ran = _run(_PROGRAM + " --total-ops=2048 --caps=64 --hide-times")
    _ok(ran)
    assert_equal(
        ran.out,
        "RESULT push_only cap=64 ns_per_op=-\n"
        "RESULT push_pop cap=64 ns_per_op=-\n"
        "RESULT drop_push cap=64 ns_per_op=-\n",
    )


def test_spsc_ring_runs_with_real_values() raises:
    var ran = _run(_PROGRAM + " --total-ops=2048 --caps=64")
    _ok(ran)
    assert_true(ran.out.endswith("\n"), ran.out)
    var lines = ran.out.split("\n")
    # Three lines and the empty piece after the last line break.
    assert_equal(len(lines), 4, ran.out)
    _value(String(lines[0]), "RESULT push_only cap=64 ns_per_op=")
    _value(String(lines[1]), "RESULT push_pop cap=64 ns_per_op=")
    _value(String(lines[2]), "RESULT drop_push cap=64 ns_per_op=")


def test_spsc_ring_help() raises:
    var ran = _run(_PROGRAM + " --help")
    _ok(ran)
    assert_true(ran.out.startswith("usage: spsc_ring [--total-ops=N] "), ran.out)
    assert_true(ran.out.endswith("  --help, -h      this text\n"), ran.out)


def _refused_with(arguments: String, error: String) raises:
    var ran = _run(_PROGRAM + " " + arguments)
    assert_true(ran.exited, "ended by signal " + String(ran.signal) + ": " + ran.out)
    assert_equal(ran.code, 1, ran.out)
    assert_false("RESULT" in ran.out, ran.out)
    var lines = ran.out.split("\n")
    # The last line break ends the output: the line before it is the last line.
    assert_true(len(lines) >= 2, ran.out)
    assert_equal(String(lines[len(lines) - 1]), "", ran.out)
    assert_equal(
        String(lines[len(lines) - 2]),
        "Unhandled exception caught during execution: " + error,
        ran.out,
    )


def test_spsc_ring_refusal_is_a_named_error_and_exit_1() raises:
    _refused_with(
        "--total-ops=0 --hide-times",
        "komira_bench: --total-ops must be a positive integer (decimal digits,"
        " at most 9223372036854775807), got '0'",
    )
    _refused_with(
        "--caps=3 --hide-times",
        "komira_bench: spsc_ring --caps takes powers of two from 1 to 16777216,"
        " got 3",
    )
    _refused_with(
        "--hide-times --bogus", "komira_bench: unknown argument '--bogus' (try --help)"
    )


def main() raises:
    test_spsc_ring_prints_its_result_lines()
    test_spsc_ring_runs_with_real_values()
    test_spsc_ring_help()
    test_spsc_ring_refusal_is_a_named_error_and_exit_1()
    print("ALL TESTS PASS")
