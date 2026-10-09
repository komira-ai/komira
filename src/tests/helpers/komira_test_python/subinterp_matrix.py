"""Records which pinned libraries import in an own-GIL sub-interpreter, against pinned outcomes.

Arguments: `preload=<path>`, repeated (the shared libraries `py_test` loaded
before the script, which each child loads too), and `<module>=<outcome>`, one
per module MODULES lists. An outcome is `ok`, `<ExceptionType>: <message>`
(the exception the import raised inside the sub-interpreter, with each
absolute path cut to its last component), or `exit <status>` / `signal <n>`
(the child process died).

Each module is imported in a child process of its own (the same executable,
`-I -S`), so that a crash is a row of the table instead of the end of the
test. The child creates one sub-interpreter with `concurrent.interpreters`
(PEP 734, new in Python 3.14): its default configuration gives it its own
GIL and refuses an extension module that does not declare support for
several interpreters. The child puts its `sys.path` in the sub-interpreter
and imports the module there; a failure is reported as the innermost
exception of its chain (the extension module that refused, not a wrapper
such as pandas' "Unable to import required dependency"). Fails unless the
self-checks pass (check_self: the chain walk over a cause, an implicit and a
suppressed context, and each way a child can end), the modules named are
exactly MODULES and every outcome is the pinned one. Every
row is printed before the verdict, so one failing run shows the whole table.
"""

import json
import re
import subprocess
import sys

MODULES = ["cloudpickle", "numpy", "pandas", "pyarrow", "sklearn"]

# Run as `python -I -S -c CHILD <json>`; prints the outcome on its last line.
CHILD = r"""
import ctypes, json, sys
from concurrent import interpreters
preload, path, module = json.loads(sys.argv[1])
for lib in preload:
    ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)
sys.path[:] = path
interp = interpreters.create()
try:
    interp.exec(SUB % (path, module))
    print("ok")
except interpreters.ExecutionFailed as e:
    print(e.excinfo.msg)
finally:
    interp.close()
"""

# The innermost exception of a failure's chain, as `<ExceptionType>: <first
# line of its message>`: its cause (`raise ... from`), else the exception it
# was raised while handling, even one `from None` suppresses. Run both in the
# sub-interpreter (SUB) and by check_self, so it holds no `%`.
DESCRIBE = r"""
def describe(e):
    while e.__cause__ is not None or e.__context__ is not None:
        e = e.__cause__ if e.__cause__ is not None else e.__context__
    return type(e).__name__ + ": " + (str(e).splitlines() or [""])[0]
"""

# Run in the sub-interpreter: imports the module, and on failure raises the
# innermost exception of its chain, described.
SUB = DESCRIBE + r"""
import sys
sys.path[:] = %r
try:
    import %s
except BaseException as e:
    raise RuntimeError(describe(e))
"""

ABSOLUTE = re.compile(r"/[^\s'\"]*/")


def outcome(preload, module, program=None):
    """The outcome of importing the module in a child; `program` replaces the child's code (check_self)."""
    code = "SUB = %r\n" % SUB + CHILD if program is None else program
    proc = subprocess.run(
        [sys.executable, "-I", "-S", "-c", code, json.dumps([preload, sys.path, module])],
        capture_output=True,
        text=True,
    )
    if proc.returncode < 0:
        return "signal {}".format(-proc.returncode), proc.stderr
    if proc.returncode != 0:
        return "exit {}".format(proc.returncode), proc.stderr
    lines = proc.stdout.strip().splitlines()
    return ABSOLUTE.sub("", lines[-1] if lines else "(no output)"), proc.stderr


def check_self():
    """describe() finds the innermost exception of each kind of chain, and outcome() reads each way a child ends."""
    space = {}
    exec(DESCRIBE, space)
    describe = space["describe"]

    def raised(f):
        try:
            f()
        except BaseException as e:
            return e
        raise AssertionError("{} raised nothing".format(f))

    def implicit():
        try:
            raise ImportError("inner, implicit\nsecond line")
        except ImportError:
            raise ImportError("wrapper")

    def explicit():
        try:
            raise ValueError("context, not the cause")
        except ValueError:
            raise ImportError("wrapper") from OSError("inner, explicit")

    def suppressed():
        try:
            raise KeyError("inner, suppressed")
        except KeyError:
            raise ImportError("wrapper") from None

    def deep():
        try:
            implicit()
        except ImportError as e:
            raise RuntimeError("outer") from e

    def bare():
        raise ImportError()

    cases = [
        (implicit, "ImportError: inner, implicit"),
        (explicit, "OSError: inner, explicit"),
        (suppressed, "KeyError: 'inner, suppressed'"),
        (deep, "ImportError: inner, implicit"),
        (bare, "ImportError: "),
    ]
    for f, want in cases:
        got = describe(raised(f))
        assert got == want, "describe({}) is {!r}, not {!r}".format(f.__name__, got, want)
    assert "%" not in DESCRIBE, "DESCRIBE holds a %, which SUB's formatting would take"
    programs = [
        ("import os, signal; os.kill(os.getpid(), signal.SIGKILL)", "signal 9"),
        ("import sys; sys.exit(3)", "exit 3"),
        ("pass", "(no output)"),
        ("print('first'); print(\"ImportError: /abs/dir/mod.so: cannot open '/x/y/lib.so'\")", "ImportError: mod.so: cannot open 'lib.so'"),
    ]
    for program, want in programs:
        got, _ = outcome([], "unused", program)
        assert got == want, "a child running {!r} reads as {!r}, not {!r}".format(program, got, want)


def main(args):
    preload, want = [], {}
    for a in args:
        key, _, value = a.partition("=")
        if key == "preload":
            preload.append(value)
        else:
            want[key] = value
    check_self()
    bad = []
    if sorted(want) != sorted(MODULES):
        bad.append("pinned outcomes for {}, but subinterp_matrix.py checks {}".format(sorted(want), sorted(MODULES)))
    print("python %d.%d.%d" % sys.version_info[:3])
    for module in MODULES:
        got, stderr = outcome(preload, module)
        print("{}: {}".format(module, got))
        if got != want.get(module):
            if got.startswith(("signal", "exit")) and stderr.strip():
                sys.stderr.write(stderr[-2000:])
            bad.append("{}: the outcome is {!r}, the pin says {!r}".format(module, got, want.get(module)))
    assert not bad, "\n".join(bad)


main(sys.argv[1:])
