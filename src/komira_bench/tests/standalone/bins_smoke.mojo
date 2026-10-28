# =============================================================================
# bins_smoke.mojo -- each program of komira_bench builds and runs once
# =============================================================================
#
# The program is this test's data (BUCK: `mojo_test` `bins_smoke`), the program
# a user gets from `mopm run --bin komira_bench:spsc_ring` built by komira's
# rules. It is run on a few records with the times hidden, and its whole output
# must be the three RESULT lines of one capacity. Nothing here reads or asserts
# a time: with `--hide-times` the value of every line is `-`.
#
# This is not one of the package's gated tests (tests/test_*.mojo): the program imports the
# gated library, so a gated test that ran it would wait for itself.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true

comptime _PROGRAM = "bench/bin/spsc_ring_bench"


def _run(command: String) raises -> String:
    """The standard output of `command`; raises unless it exited with status 0."""
    var cmd = command.copy()
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
    if status != 0:
        raise Error(command + " exited with wait status " + String(status))
    return out


def test_spsc_ring_prints_its_result_lines() raises:
    var out = _run(_PROGRAM + " --total-ops=2048 --caps=64 --hide-times")
    assert_equal(
        out,
        "RESULT push_only cap=64 ns_per_op=-\n"
        "RESULT push_pop cap=64 ns_per_op=-\n"
        "RESULT drop_push cap=64 ns_per_op=-\n",
    )


def test_spsc_ring_runs_with_real_values() raises:
    var out = _run(_PROGRAM + " --total-ops=2048 --caps=64")
    assert_true(out.startswith("RESULT push_only cap=64 ns_per_op="), out)
    assert_true("\nRESULT push_pop cap=64 ns_per_op=" in out, out)
    assert_true("\nRESULT drop_push cap=64 ns_per_op=" in out, out)
    assert_true("ns_per_op=-" not in out, out)


def test_spsc_ring_help_and_refusal() raises:
    var help = _run(_PROGRAM + " --help")
    assert_true(help.startswith("usage: spsc_ring "), help)
    var refused = False
    try:
        _ = _run(_PROGRAM + " --total-ops=0 2>/dev/null")
    except:
        refused = True
    assert_true(refused, "a bad --total-ops must exit non-zero")


def main() raises:
    test_spsc_ring_prints_its_result_lines()
    test_spsc_ring_runs_with_real_values()
    test_spsc_ring_help_and_refusal()
    print("ALL TESTS PASS")
