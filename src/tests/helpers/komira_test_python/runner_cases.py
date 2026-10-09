"""pyrun.py, the runner of every py_test, gives each case its verdict.

Argument: the path of pyrun.py. Each case runs the runner in a process of its
own, as the py_test action does (`sys.executable -I -S pyrun.py ...`), on a
script of cases/, and holds the exit status, the last stderr line and
whether `--out` was written to what is expected. They pin what makes a
py_test a gate: a script that fails, exits non-zero or fails with another
error than `expect_error` names is red; only the exact line is green.

The report cases run the runner with `--report`, `--run-id` and `--target`
(a report test) and also hold the report file's exact bytes and what the
runner left on its own standard output.
"""

import json
import os
import subprocess
import sys
import tempfile

RUNNER = os.path.abspath(sys.argv[1])
CASES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases")


def run(script, expect_error=None):
    work = tempfile.mkdtemp()
    out = os.path.join(work, "out")
    cmd = [sys.executable, "-I", "-S", RUNNER, "--out", out, "--tmpdir", os.path.join(work, "tmp")]
    if expect_error is not None:
        cmd += ["--expect-error", expect_error]
    cmd += ["--", os.path.join(CASES, script)]
    p = subprocess.run(cmd, capture_output=True, text=True, env={})
    last = p.stderr.rstrip("\n").rsplit("\n", 1)[-1] if p.stderr else ""
    return p.returncode, last, os.path.exists(out)


CASES_TABLE = [
    # (name, script, expect_error, (exit status, last stderr line, out written))
    ("pass", "passes.py", None, (0, "", True)),
    ("raises", "raises_value_error.py", None, (1, "pyrun: raises_value_error.py failed: ValueError: planted: 42", False)),
    ("exits_3", "exits_3.py", None, (1, "pyrun: exits_3.py failed: SystemExit: 3", False)),
    ("expected", "raises_value_error.py", "ValueError: planted: 42", (0, "", True)),
    (
        "expected_prefix_only",
        "raises_value_error.py",
        "ValueError: planted: 4",
        (1, "pyrun: raises_value_error.py was expected to fail with 'ValueError: planted: 4', it failed with 'ValueError: planted: 42'", False),
    ),
    (
        "expected_but_passed",
        "passes.py",
        "ValueError: planted: 42",
        (1, "pyrun: passes.py was expected to fail with 'ValueError: planted: 42', and it passed", False),
    ),
    (
        "expected_exit_is_not_error",
        "exits_3.py",
        "ValueError: planted: 42",
        (1, "pyrun: exits_3.py was expected to fail with 'ValueError: planted: 42', it failed with 'SystemExit: 3'", False),
    ),
    ("no_tzdir_empty_tzpath", "tzpath_empty.py", None, (0, "", True)),
]

bad = []
for name, script, expect, want in CASES_TABLE:
    got = run(script, expect)
    if got != want:
        bad.append("{}: got {!r}, want {!r}".format(name, got, want))
    else:
        print("ok", name)


def run_report(script, run_id="run-7\n", flags=("--report", "--run-id", "--target"), expect_error=None):
    """(exit status, last stderr line, out written, report bytes or None, runner stdout, stderr, run id path)."""
    work = tempfile.mkdtemp()
    out = os.path.join(work, "out")
    report = os.path.join(work, "report.json")
    run_id_path = os.path.join(work, "run_id")
    with open(run_id_path, "w", encoding="utf-8") as f:
        f.write(run_id)
    values = {"--report": report, "--run-id": run_id_path, "--target": "tests//x:y"}
    cmd = [sys.executable, "-I", "-S", RUNNER, "--out", out, "--tmpdir", os.path.join(work, "tmp")]
    for flag in flags:
        cmd += [flag, values[flag]]
    if expect_error is not None:
        cmd += ["--expect-error", expect_error]
    cmd += ["--", os.path.join(CASES, script)]
    # errors="replace": a broken runner may pass a script's non-UTF-8 bytes through.
    p = subprocess.run(cmd, capture_output=True, text=True, errors="replace", env={})
    last = p.stderr.rstrip("\n").rsplit("\n", 1)[-1] if p.stderr else ""
    body = None
    if os.path.exists(report):
        with open(report, encoding="utf-8") as f:
            body = f.read()
    return p.returncode, last, os.path.exists(out), body, p.stdout, p.stderr, run_id_path


def report_of(run_id, obj):
    full = {"run_id": run_id, "target": "tests//x:y"}
    full.update(obj)
    return json.dumps(full, indent=2) + "\n"


def failed(script, why):
    return "pyrun: {} failed: ValueError: report: {}".format(script, why)


OK = report_of("run-7", {"a": 1, "b": [2]})
ID_RULE = "not one run id (A-Z a-z 0-9 . _ : + -, at most 128)"

REPORT_CASES = [
    # (name, script, run id file, want (exit status, last stderr line, out written, report))
    ("report_ok", "report_ok.py", "run-7\n", (0, "stderr is not captured", True, OK)),
    ("report_id_without_newline", "report_ok.py", "run-7", (0, "stderr is not captured", True, OK)),
    ("report_id_128", "report_ok.py", "a" * 128, (0, "stderr is not captured", True, report_of("a" * 128, {"a": 1, "b": [2]}))),
    ("report_id_leading_digit", "report_ok.py", "7a\n", (0, "stderr is not captured", True, report_of("7a", {"a": 1, "b": [2]}))),
    ("report_id_charset", "report_ok.py", "Z9._:+-\n", (0, "stderr is not captured", True, report_of("Z9._:+-", {"a": 1, "b": [2]}))),
    (
        "report_not_json",
        "passes.py",
        "run-7\n",
        (1, failed("passes.py", "its standard output is not one JSON object (Expecting value: line 1 column 1 (char 0))"), False, None),
    ),
    ("report_array", "report_array.py", "run-7\n", (1, failed("report_array.py", "its standard output is a JSON list, not an object"), False, None)),
    (
        "report_sets_run_id",
        "report_sets_run_id.py",
        "run-7\n",
        (1, failed("report_sets_run_id.py", "its JSON object sets 'run_id', which the runner writes"), False, None),
    ),
    (
        "report_sets_target",
        "report_sets_target.py",
        "run-7\n",
        (1, failed("report_sets_target.py", "its JSON object sets 'target', which the runner writes"), False, None),
    ),
    (
        "report_nan",
        "report_nan.py",
        "run-7\n",
        (1, failed("report_nan.py", "its standard output is not one JSON object (NaN is not a number JSON allows)"), False, None),
    ),
    (
        "report_duplicate_key",
        "report_duplicate_key.py",
        "run-7\n",
        (1, failed("report_duplicate_key.py", "its standard output is not one JSON object (key 'calls' written twice)"), False, None),
    ),
    (
        "report_out_of_range",
        "report_out_of_range.py",
        "run-7\n",
        (1, failed("report_out_of_range.py", "its standard output is not one JSON object (1e999 is out of the range of a double)"), False, None),
    ),
    (
        "report_huge_integer",
        "report_huge_integer.py",
        "run-7\n",
        (1, failed("report_huge_integer.py", "its standard output is not one JSON object (an integer of 310 digits is out of the range of a double)"), False, None),
    ),
    (
        "report_not_utf8",
        "report_not_utf8.py",
        "run-7\n",
        (
            1,
            failed("report_not_utf8.py", "its standard output is not one JSON object ('utf-8' codec can't decode byte 0xff in position 7: invalid start byte)"),
            False,
            None,
        ),
    ),
    (
        "report_script_fails",
        "report_then_raise.py",
        "run-7\n",
        (1, "pyrun: report_then_raise.py failed: ValueError: planted after the report", False, None),
    ),
    ("report_id_empty", "report_ok.py", "", (2, "pyrun: the run id file {} holds '', " + ID_RULE, False, None)),
    ("report_id_space", "report_ok.py", "a b\n", (2, "pyrun: the run id file {} holds 'a b\\n', " + ID_RULE, False, None)),
    ("report_id_leading_dash", "report_ok.py", "-a\n", (2, "pyrun: the run id file {} holds '-a\\n', " + ID_RULE, False, None)),
    ("report_id_two_lines", "report_ok.py", "a\n\n", (2, "pyrun: the run id file {} holds 'a\\n\\n', " + ID_RULE, False, None)),
    ("report_id_129", "report_ok.py", "a" * 129, (2, "pyrun: the run id file {} holds '" + "a" * 129 + "', " + ID_RULE, False, None)),
    # The range of a double at each end: the largest is accepted (as a number
    # with a fraction and as an integer), and the first value past it refused.
    ("report_max_double", "report_max_double.py", "run-7\n", (0, "", True, report_of("run-7", {"f": sys.float_info.max}))),
    (
        "report_double_past_max",
        "report_double_past_max.py",
        "run-7\n",
        (1, failed("report_double_past_max.py", "its standard output is not one JSON object (1.7976931348623159e308 is out of the range of a double)"), False, None),
    ),
    ("report_max_integer", "report_max_integer.py", "run-7\n", (0, "", True, report_of("run-7", {"i": 2**1024 - 2**970 - 1}))),
    (
        "report_integer_past_max",
        "report_integer_past_max.py",
        "run-7\n",
        (1, failed("report_integer_past_max.py", "its standard output is not one JSON object (an integer of 309 digits is out of the range of a double)"), False, None),
    ),
]

# A run id's character classes at each end: one-character ids of each end of
# the first character's ranges (A-Z a-z 0-9), and a later character at each
# end of A-Z a-z 0-9 after an `x` (9 and . _ : + - are also in
# report_id_charset); refused, the byte just past each end or next to each
# single character, first and later.
for rid in ["A", "Z", "a", "z", "0", "9", "xA", "xZ", "xa", "xz", "x0", "x9"]:
    REPORT_CASES.append(("report_id_" + rid, "report_ok.py", rid, (0, "stderr is not captured", True, report_of(rid, {"a": 1, "b": [2]}))))
for rid in ["@a", "[a", "`a", "{a", "/a", ":a", "a@", "a[", "a`", "a{", "a/", "a;", "a,", "a*", "a^"]:
    REPORT_CASES.append(("report_id_" + rid, "report_ok.py", rid, (2, "pyrun: the run id file {} holds " + repr(rid) + ", " + ID_RULE, False, None)))

for name, script, run_id, want in REPORT_CASES:
    rc, last, out, body, stdout, stderr, run_id_path = run_report(script, run_id)
    want = (want[0], want[1].replace("{}", run_id_path), want[2], want[3])
    got = (rc, last, out, body)
    if got != want:
        bad.append("{}: got {!r}, want {!r}".format(name, got, want))
    elif stdout != "":
        bad.append("{}: the runner's standard output is {!r}; a report test's is captured".format(name, stdout))
    else:
        print("ok", name)

# A failing report test shows what its script wrote, on standard error.
rc, last, out, body, stdout, stderr, _ = run_report("report_then_raise.py")
if '{"partial": 1}\n' not in stderr:
    bad.append("report_script_fails: the captured output is not on standard error: {!r}".format(stderr))
else:
    print("ok report_output_shown_on_failure")

# A report the runner refuses shows what the script wrote, on standard error, too.
rc, last, out, body, stdout, stderr, _ = run_report("report_duplicate_key.py")
if '{"calls": 9, "calls": 8}\n' not in stderr:
    bad.append("report_duplicate_key: the captured output is not on standard error: {!r}".format(stderr))
else:
    print("ok report_output_shown_on_refusal")

# The report flags come together, and not with --expect-error.
for name, flags, expect, want in [
    ("report_flags_report_alone", ("--report",), None, "pyrun: --report, --run-id and --target come together"),
    ("report_flags_no_target", ("--report", "--run-id"), None, "pyrun: --report, --run-id and --target come together"),
    ("report_flags_target_alone", ("--target",), None, "pyrun: --report, --run-id and --target come together"),
    ("report_flags_expect_error", ("--report", "--run-id", "--target"), "ValueError: x", "pyrun: --report does not go with --expect-error"),
]:
    rc, last, out, body = run_report("report_ok.py", flags=flags, expect_error=expect)[:4]
    if (rc, last, out, body) != (2, want, False, None):
        bad.append("{}: got {!r}, want {!r}".format(name, (rc, last, out, body), (2, want, False, None)))
    else:
        print("ok", name)

# Without --report the script's standard output is the runner's, as before.
rc, last, out, body, stdout = run_report("passes.py", flags=())[:5]
if (rc, out, body, stdout) != (0, True, None, "passes\n"):
    bad.append("no_report_stdout_passes_through: got {!r}".format((rc, out, body, stdout)))
else:
    print("ok no_report_stdout_passes_through")

assert not bad, "\n".join(bad)
