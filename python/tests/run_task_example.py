"""Runs common-task examples (python/docs/tasks/<rank>-<slug>/example.py)
against the installed wheel and holds what each prints to its directory's
expected_output.txt, byte for byte.

    run_task_example.py --site <dir> [--host-lib <lib>]...
        --tasks-dir <dir> --task <rank>-<slug> [--task <rank>-<slug>]...

Run by wheel_install_run.py (python/install_test.bzl, `wheel_install_test`),
which installed komira's wheel and its requirements into `--site` and starts
this from an empty working directory outside the checkout. Each `--host-lib`
is opened by path first: the C++ runtime a user's system provides, which the
build workers do not (test_installed.py says the same). `--tasks-dir` holds
the task directories (python/BUCK, `:task_tree`). Then each `--task`, in the
order given, runs in this process as `python example.py` runs it
(`__name__` is "__main__"), from a new empty directory of its own, so the
files it makes are its own; what it writes to stdout is captured.

Every task runs. A task whose output is not its expected text writes both
texts to stderr; one that raises writes its traceback. The run then fails
with one line naming the first task that failed, as
`python/docs/tasks/<rank>-<slug>`:

    AssertionError: python/docs/tasks/<task> printed other text than its expected_output.txt: line <n> is <printed>, expected <expected>
    AssertionError: python/docs/tasks/<task> raised <Type>: <message>

(`missing` stands for a line past the end of a text), and a
`wheel_install_test` with `expect_failure` holds that line.
"""

import contextlib
import ctypes
import io
import os
import runpy
import sys
import traceback

DISPLAY = "python/docs/tasks"


def parse(argv):
    opts = {"host_lib": [], "task": []}
    i = 0
    while i < len(argv):
        flag = argv[i]
        if i + 1 >= len(argv):
            raise SystemExit("run_task_example: flag {} needs a value".format(flag))
        value = argv[i + 1]
        if flag in ("--host-lib", "--task"):
            opts[flag[2:].replace("-", "_")].append(value)
        elif flag in ("--site", "--tasks-dir"):
            opts[flag[2:].replace("-", "_")] = value
        else:
            raise SystemExit("run_task_example: unknown flag {}".format(flag))
        i += 2
    if "tasks_dir" not in opts:
        raise SystemExit("run_task_example: --tasks-dir is required")
    if not opts["task"]:
        raise SystemExit("run_task_example: at least one --task is required")
    return opts


def first_difference(got, want):
    """The line number (from 1) of the first line where the texts `got` and
    `want` differ, with each side's line (None past its end); None when the
    texts are equal."""
    if got == want:
        return None
    have, wanted = got.split("\n"), want.split("\n")
    n = 0
    while n < len(have) and n < len(wanted) and have[n] == wanted[n]:
        n += 1
    # Unequal texts split into unequal lists, so n is inside one of them.
    return n + 1, (have[n] if n < len(have) else None), (wanted[n] if n < len(wanted) else None)


def describe(line):
    return "missing" if line is None else repr(line)


def run_task(tasks_dir, task):
    """Runs one task's example from a new empty directory; the failure line
    for it, or None when it printed its expected text."""
    name = "{}/{}".format(DISPLAY, task)
    example = os.path.join(tasks_dir, task, "example.py")
    with open(os.path.join(tasks_dir, task, "expected_output.txt"), encoding="utf-8") as f:
        want = f.read()
    home = os.getcwd()
    run_dir = os.path.join(home, task)
    os.mkdir(run_dir)
    os.chdir(run_dir)
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            runpy.run_path(example, run_name="__main__")
    except Exception as e:  # any failure of the example is the task's failure
        sys.stderr.write("--- {} raised ---\n{}--- end ---\n".format(name, traceback.format_exc()))
        return "{} raised {}: {}".format(name, type(e).__name__, e)
    finally:
        os.chdir(home)
    got = out.getvalue()
    diff = first_difference(got, want)
    if diff is None:
        return None
    n, a, b = diff
    sys.stderr.write("--- {} expected ---\n{}--- printed ---\n{}--- end ---\n".format(name, want, got))
    return "{} printed other text than its expected_output.txt: line {} is {}, expected {}".format(
        name, n, describe(a), describe(b)
    )


def main(argv):
    opts = parse(argv)
    for lib in opts["host_lib"]:
        ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)
    tasks_dir = os.path.abspath(opts["tasks_dir"])
    failures = [f for f in (run_task(tasks_dir, t) for t in opts["task"]) if f is not None]
    if failures:
        for f in failures[1:]:
            sys.stderr.write("also failed: {}\n".format(f))
        raise AssertionError(failures[0])


if __name__ == "__main__":
    main(sys.argv[1:])
