"""Runs one test script with the hermetic interpreter, as `py_test` does.

    python3.<minor> -I -S pyrun.py --out <file> --tmpdir <dir>
        [--preload <lib>]... [--site <dir>]... [--expect-error <line>]
        -- <script> [<arg>]...

Loads each `--preload` library by path (RTLD_GLOBAL, in the order given),
puts the script's directory first on `sys.path` and each `--site` directory
after the standard library, points `tempfile` at `--tmpdir`, and runs the
script as `__main__` with `sys.argv` set to the script and its arguments.

Time zones: `zoneinfo` looks for a zone only in `TZDIR` (made absolute in the
environment, for the script's children and the native libraries that read
it), or, with no `TZDIR`, only in an importable `tzdata` package: never in
the interpreter's built-in path, which names the worker's /usr/share/zoneinfo.

The script passes when it returns or exits with status 0. With
`--expect-error`, it passes only if it raises an exception whose last
traceback line (`Type: message`) is exactly the given line. On a pass,
`--tmpdir` is emptied and `--out` is written; otherwise this exits 1 and
writes nothing to `--out`.
"""

import ctypes
import os
import runpy
import shutil
import sys
import tempfile
import traceback
import zoneinfo


def _usage(msg):
    sys.stderr.write("pyrun: " + msg + "\n")
    sys.exit(2)


def _parse(argv):
    opts = {"out": None, "tmpdir": None, "preload": [], "site": [], "expect_error": None}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--":
            rest = argv[i + 1 :]
            if not rest:
                _usage("no script after --")
            return opts, rest[0], rest[1:]
        if i + 1 >= len(argv):
            _usage("flag " + a + " needs a value")
        v = argv[i + 1]
        if a == "--out":
            opts["out"] = v
        elif a == "--tmpdir":
            opts["tmpdir"] = v
        elif a == "--preload":
            opts["preload"].append(v)
        elif a == "--site":
            opts["site"].append(v)
        elif a == "--expect-error":
            opts["expect_error"] = v
        else:
            _usage("unknown flag " + a)
        i += 2
    _usage("no -- before the script")


def _last_line(exc):
    return traceback.format_exception_only(type(exc), exc)[-1].rstrip("\n")


def main():
    opts, script, args = _parse(sys.argv[1:])
    if opts["out"] is None or opts["tmpdir"] is None:
        _usage("--out and --tmpdir are required")
    for lib in opts["preload"]:
        ctypes.CDLL(os.path.abspath(lib), mode=ctypes.RTLD_GLOBAL)
    tmpdir = os.path.abspath(opts["tmpdir"])
    os.makedirs(tmpdir, exist_ok=True)
    tempfile.tempdir = tmpdir
    tzdir = os.environ.get("TZDIR")
    if tzdir:
        tzdir = os.path.abspath(tzdir)
        os.environ["TZDIR"] = tzdir
        zoneinfo.reset_tzpath([tzdir])
    else:
        zoneinfo.reset_tzpath([])
    script = os.path.abspath(script)
    sys.path[:] = (
        [os.path.dirname(script)]
        + [p for p in sys.path if p]
        + [os.path.abspath(s) for s in opts["site"]]
    )
    sys.argv = [script] + args

    error = None
    try:
        runpy.run_path(script, run_name="__main__")
    except SystemExit as e:
        if e.code not in (None, 0):
            error = e
    except BaseException as e:  # noqa: BLE001 - every failure of the script is reported
        error = e

    want = opts["expect_error"]
    if want is None:
        if error is not None:
            if not isinstance(error, SystemExit):
                traceback.print_exception(type(error), error, error.__traceback__)
            sys.stderr.write("pyrun: {} failed: {}\n".format(os.path.basename(script), _last_line(error)))
            sys.exit(1)
        verdict = "PASS"
    else:
        if error is None:
            sys.stderr.write("pyrun: {} was expected to fail with '{}', and it passed\n".format(os.path.basename(script), want))
            sys.exit(1)
        got = _last_line(error)
        if got != want:
            traceback.print_exception(type(error), error, error.__traceback__)
            sys.stderr.write("pyrun: {} was expected to fail with '{}', it failed with '{}'\n".format(os.path.basename(script), want, got))
            sys.exit(1)
        verdict = "PASS (failed as expected: {})".format(got)

    sys.stdout.flush()
    for name in os.listdir(tmpdir):
        path = os.path.join(tmpdir, name)
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            os.unlink(path)
    with open(opts["out"], "w") as f:
        f.write(verdict + "\n")


if __name__ == "__main__":
    main()
