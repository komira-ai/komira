# =============================================================================
# test_abort_path.mojo -- the ABORTS: child path, driven by a testee that
# really aborts
# =============================================================================
#
# No parser aborts on a suite file today, so no allowlist holds an ABORTS:
# line and no parser test runs the child path (runner.mojo: check_abort,
# run_child, the --child branch of a test's main). This test runs it for
# real with `abort_probe` (testees.mojo), a test-only testee that aborts the
# process on one suite file (ABORT_PROBE_FILE) and accepts every other. The
# suite is the pinned corpus; the allowlists are written here.
#
#   - listed: ABORT_PROBE_FILE as ABORTS: with the probe's abort text. The
#     file is not run in process, its child dies by a signal printing that
#     text, and the gate passes. Then an ABORTS: line with text the abort
#     does not print: ABORTS TEXT CHANGED.
#   - stale: the same live line plus an ABORTS: line for a file the probe
#     does not abort on: exactly one problem, STALE ABORTS ENTRY for it.
#   - unlisted: nothing listed. The in-process run reaches the file and the
#     abort kills that process, so this runs in a child (this executable
#     with --unlisted, the whole check): the child must die by a signal with
#     the abort text and never print the run's summary line.
#
# Defects it catches: a child path that reads an abort as an exit (every
# live ABORTS: line would turn STALE), a child that runs the wrong file or
# none, an ABORTS: file still fed in process (the test itself dies), a stale
# line the gate lets stand, an abort that does not end the run.
# =============================================================================

from std.sys import argv, exit
from std.testing import assert_equal, assert_false, assert_true

from komira_runtime_paths import executable_path

from komira_json_conformance import (
    ABORT_PROBE_FILE,
    ABORT_PROBE_TEXT,
    CHILD_FLAG,
    PARSER_ABORT_PROBE,
    check_abort,
    gate_parser,
    run_child,
    run_self,
)

comptime UNLISTED_FLAG = "--unlisted"
# A file the probe does not abort on.
comptime NOT_ABORTING = "y_string_utf8.json"


def _live_line() -> String:
    return String(ABORT_PROBE_FILE) + " ABORTS: " + ABORT_PROBE_TEXT + " | test_abort_path\n"


def test_listed_abort_passes() raises:
    # The child alone: dies by a signal, with the probe's text.
    var a = check_abort(executable_path(), String(ABORT_PROBE_FILE))
    assert_true(a.died, "the child exited: " + a.how + ": " + a.output)
    assert_true(String(ABORT_PROBE_TEXT) in a.output, a.output)
    # The whole check: the listed file runs in a child; nothing else aborts.
    var problems = gate_parser(PARSER_ABORT_PROBE, _live_line())
    for ref p in problems:
        print("unexpected:", p)
    assert_equal(len(problems), 0)
    # A recorded text the abort does not print.
    problems = gate_parser(
        PARSER_ABORT_PROBE, String(ABORT_PROBE_FILE) + " ABORTS: some other text | x\n"
    )
    assert_equal(len(problems), 1)
    assert_true(problems[0].startswith("ABORTS TEXT CHANGED " + String(ABORT_PROBE_FILE)), problems[0])


def test_stale_abort_entry() raises:
    var a = check_abort(executable_path(), String(NOT_ABORTING))
    assert_false(a.died, "the child died: " + a.how + ": " + a.output)
    var problems = gate_parser(
        PARSER_ABORT_PROBE, _live_line() + NOT_ABORTING + " ABORTS: " + ABORT_PROBE_TEXT + "\n"
    )
    for ref p in problems:
        print("problem:", p)
    assert_equal(len(problems), 1)
    assert_true(problems[0].startswith("STALE ABORTS ENTRY " + String(NOT_ABORTING)), problems[0])


def test_unlisted_abort_is_red() raises:
    var args: List[String] = [String(UNLISTED_FLAG)]
    var a = run_self(executable_path(), String("unlisted"), args)
    assert_true(a.died, "the unlisted run did not die: " + a.how + ": " + a.output)
    assert_true(String(ABORT_PROBE_TEXT) in a.output, a.output)
    assert_false("files run:" in a.output, "the run went on past the abort")
    assert_false("UNLISTED RUN SURVIVED" in a.output)


def main() raises:
    var args = argv()
    if len(args) >= 3 and String(args[1]) == CHILD_FLAG:
        run_child(PARSER_ABORT_PROBE, String(args[2]))
        exit(0)
    if len(args) >= 2 and String(args[1]) == UNLISTED_FLAG:
        _ = gate_parser(PARSER_ABORT_PROBE, String(""))
        print("UNLISTED RUN SURVIVED", flush=True)
        exit(0)
    test_listed_abort_passes()
    test_stale_abort_entry()
    test_unlisted_abort_is_red()
    print("PASS komira_json_conformance abort path")
