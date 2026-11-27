"""Runs common-task cases (python/docs/tasks/<rank>-<slug>/) against the
installed wheel and judges each.

    run_task_example.py --site <dir> [--host-lib <lib>]... --tasks-dir <dir>
        (--task <rank>-<slug> | --probe <rank>-<slug>/<name>)...

Run by wheel_install_run.py (python/install_test.bzl, `wheel_install_test`),
which installed komira's wheel and its requirements into `--site` and starts
this from an empty working directory outside the checkout. Each `--host-lib`
is opened by path first: the C++ runtime a user's system provides, which the
build workers do not (test_installed.py says the same). `--tasks-dir` holds
the task directories (python/docs/tasks/BUCK, `:tree`).

Each case, in the order given, runs in this process as `python <file>` runs
it (`__name__` is "__main__"), from a new empty directory of its own, so the
files it makes are its own.

- `--task <t>` runs `<t>/example.py`. It must run to the end, and what it
  writes to stdout must be `<t>/expected_output.txt` byte for byte.
- `--probe <t>/<name>` runs `<t>/probe_<name>.py`, a program that shows
  what komira cannot do yet. It must raise, and the line `<Type>: <message>`
  of what it raised must be `<t>/probe_<name>.error.txt` (one line). Its
  stdout is not compared.

Every case runs. Each failure writes what it has (both texts, or the
traceback) to stderr; the run then fails with one line naming the first
failure by a file and a line a person can open, under `python/docs/tasks/`:

    AssertionError: <t>/expected_output.txt:<n>: expected <line>, printed <line>
    AssertionError: <t>/example.py:<n>: raised <Type>: <message>
    AssertionError: <t>/probe_<name>.error.txt:1: expected <line>, raised <line>
    AssertionError: <t>/probe_<name>.py: ran to the end, but probe_<name>.error.txt says it fails: ...

(`missing` stands for a line past the end of a text). A `wheel_install_test`
with `expect_failure` holds that line.
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
    opts = {"host_lib": [], "cases": []}
    i = 0
    while i < len(argv):
        flag = argv[i]
        if i + 1 >= len(argv):
            raise SystemExit("run_task_example: flag {} needs a value".format(flag))
        value = argv[i + 1]
        if flag == "--host-lib":
            opts["host_lib"].append(value)
        elif flag in ("--task", "--probe"):
            opts["cases"].append((flag[2:], value))
        elif flag in ("--site", "--tasks-dir"):
            opts[flag[2:].replace("-", "_")] = value
        else:
            raise SystemExit("run_task_example: unknown flag {}".format(flag))
        i += 2
    if "tasks_dir" not in opts:
        raise SystemExit("run_task_example: --tasks-dir is required")
    if not opts["cases"]:
        raise SystemExit("run_task_example: at least one --task or --probe is required")
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


def summary(e):
    """The line `<Type>: <message>` of an exception."""
    return "{}: {}".format(type(e).__name__, e)


def line_in(e, path):
    """The line of `path` the exception `e` passed through last, or None."""
    n = None
    for frame in traceback.extract_tb(e.__traceback__):
        if frame.filename == path:
            n = frame.lineno
    return n


def run_file(path, run_dir):
    """Runs `path` from the new empty directory `run_dir`: what it printed,
    and the exception it raised or None."""
    home = os.getcwd()
    os.mkdir(run_dir)
    os.chdir(run_dir)
    out = io.StringIO()
    raised = None
    try:
        with contextlib.redirect_stdout(out):
            runpy.run_path(path, run_name="__main__")
    except Exception as e:  # what a case raises is judged below
        raised = e
    finally:
        os.chdir(home)
    return out.getvalue(), raised


def run_example(tasks_dir, task):
    """The failure line of the task's example, or None when it printed its
    expected text."""
    shown = "{}/{}".format(DISPLAY, task)
    path = os.path.join(tasks_dir, task, "example.py")
    with open(os.path.join(tasks_dir, task, "expected_output.txt"), encoding="utf-8") as f:
        want = f.read()
    got, raised = run_file(path, os.path.join(os.getcwd(), task))
    if raised is not None:
        sys.stderr.write("--- {}/example.py raised ---\n{}--- end ---\n".format(
            shown, "".join(traceback.format_exception(raised))))
        n = line_in(raised, path)
        where = "example.py" if n is None else "example.py:{}".format(n)
        return "{}/{}: raised {}".format(shown, where, summary(raised))
    diff = first_difference(got, want)
    if diff is None:
        return None
    n, a, b = diff
    sys.stderr.write("--- {} expected ---\n{}--- printed ---\n{}--- end ---\n".format(shown, want, got))
    return "{}/expected_output.txt:{}: expected {}, printed {}".format(shown, n, describe(b), describe(a))


def run_probe(tasks_dir, probe):
    """The failure line of the probe `<task>/<name>`, or None when it raised
    exactly its recorded line."""
    task, name = probe.split("/", 1)
    shown = "{}/{}".format(DISPLAY, task)
    path = os.path.join(tasks_dir, task, "probe_{}.py".format(name))
    with open(os.path.join(tasks_dir, task, "probe_{}.error.txt".format(name)), encoding="utf-8") as f:
        want = f.read().rstrip("\n")
    _, raised = run_file(path, os.path.join(os.getcwd(), "{}__probe_{}".format(task, name)))
    if raised is None:
        return (
            "{}/probe_{}.py: ran to the end, but probe_{}.error.txt says it fails with {}: "
            "if komira does this now, update the page, its catalogue status and the probe"
        ).format(shown, name, name, repr(want))
    got = summary(raised)
    if got == want:
        return None
    sys.stderr.write("--- {}/probe_{}.py raised ---\n{}--- end ---\n".format(
        shown, name, "".join(traceback.format_exception(raised))))
    return "{}/probe_{}.error.txt:1: expected {}, raised {}".format(shown, name, repr(want), repr(got))


def main(argv):
    opts = parse(argv)
    for lib in opts["host_lib"]:
        ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)
    tasks_dir = os.path.abspath(opts["tasks_dir"])
    failures = []
    for kind, value in opts["cases"]:
        f = run_example(tasks_dir, value) if kind == "task" else run_probe(tasks_dir, value)
        if f is not None:
            failures.append(f)
    if failures:
        for f in failures[1:]:
            sys.stderr.write("also failed: {}\n".format(f))
        raise AssertionError(failures[0])


if __name__ == "__main__":
    main(sys.argv[1:])
