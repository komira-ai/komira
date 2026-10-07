"""pyrun.py, the runner of every py_test, gives each case its verdict.

Argument: the path of pyrun.py. Each case runs the runner in a process of its
own, as the py_test action does (`sys.executable -I -S pyrun.py ...`), on a
script of cases/, and holds the exit status, the last stderr line and
whether `--out` was written to what is expected. They pin what makes a
py_test a gate: a script that fails, exits non-zero or fails with another
error than `expect_error` names is red; only the exact line is green.
"""

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
assert not bad, "\n".join(bad)
