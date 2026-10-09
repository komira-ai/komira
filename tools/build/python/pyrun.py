"""Runs one test script with the hermetic interpreter, as `py_test` does.

    python3.<minor> -I -S pyrun.py --out <file> --tmpdir <dir>
        [--preload <lib>]... [--site <dir>]... [--expect-error <line>]
        [--report <file> --run-id <file> --target <label>]
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

Reports: with `--report`, everything the script and its children write to
file descriptor 1 is captured (not shown), and the script passes only if
that is one JSON object without a `run_id` or `target` key, and without
NaN or an infinity. The object is written to `--report` with `run_id` (the
content of the `--run-id` file, one line of at most 128 characters from
`A-Z a-z 0-9 . _ : + -`, starting with a letter or a digit) and `target` (the
`--target` label) put first. A script that fails has its captured output
copied to standard error, and writes no report. `--report`, `--run-id` and
`--target` come together, and not with `--expect-error`.
"""

import ctypes
import json
import math
import os
import re
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
    opts = {
        "out": None,
        "tmpdir": None,
        "preload": [],
        "site": [],
        "expect_error": None,
        "report": None,
        "run_id": None,
        "target": None,
    }
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
        elif a == "--report":
            opts["report"] = v
        elif a == "--run-id":
            opts["run_id"] = v
        elif a == "--target":
            opts["target"] = v
        else:
            _usage("unknown flag " + a)
        i += 2
    _usage("no -- before the script")


_RUN_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:+-]{0,127}")


def _run_id(path):
    """The run id the file at `path` holds: its one line, without the newline."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    line = text[:-1] if text.endswith("\n") else text
    if not _RUN_ID.fullmatch(line):
        _usage("the run id file {} holds {!r}, not one run id (A-Z a-z 0-9 . _ : + -, at most 128)".format(path, text))
    return line


def _refuse_constant(name):
    raise ValueError("{} is not a number JSON allows".format(name))


def _finite(text):
    """A JSON number with a fraction or an exponent, refused outside the range of a double (json.loads reads 1e999 as infinity)."""
    v = float(text)
    if math.isinf(v):
        raise ValueError("{} is out of the range of a double".format(text))
    return v


def _no_duplicates(pairs):
    """An object's members, refused if a key is written twice (a dict would keep only the last value)."""
    obj = {}
    for k, v in pairs:
        if k in obj:
            raise ValueError("key '{}' written twice".format(k))
        obj[k] = v
    return obj


def _report(captured, run_id, target):
    """The report: the script's JSON object, `run_id` and `target` first; or the reason it is none."""
    try:
        obj = json.loads(
            captured.decode("utf-8"),
            parse_constant=_refuse_constant,
            parse_float=_finite,
            object_pairs_hook=_no_duplicates,
        )
    except (UnicodeDecodeError, ValueError) as e:
        return None, "its standard output is not one JSON object ({})".format(e)
    if not isinstance(obj, dict):
        return None, "its standard output is a JSON {}, not an object".format(type(obj).__name__)
    for key in ("run_id", "target"):
        if key in obj:
            return None, "its JSON object sets '{}', which the runner writes".format(key)
    out = {"run_id": run_id, "target": target}
    out.update(obj)
    return out, None


def _last_line(exc):
    return traceback.format_exception_only(type(exc), exc)[-1].rstrip("\n")


def main():
    opts, script, args = _parse(sys.argv[1:])
    if opts["out"] is None or opts["tmpdir"] is None:
        _usage("--out and --tmpdir are required")
    reporting = [opts[k] is not None for k in ("report", "run_id", "target")]
    if any(reporting) and not all(reporting):
        _usage("--report, --run-id and --target come together")
    if opts["report"] is not None and opts["expect_error"] is not None:
        _usage("--report does not go with --expect-error")
    run_id = _run_id(opts["run_id"]) if opts["report"] is not None else None
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

    capture = None
    if opts["report"] is not None:
        # At the descriptor, so the script's children and native code are
        # captured too; the file is under tmpdir, emptied on a pass.
        sys.stdout.flush()
        capture = tempfile.TemporaryFile(dir=tmpdir)
        saved = os.dup(1)
        os.dup2(capture.fileno(), 1)

    error = None
    try:
        runpy.run_path(script, run_name="__main__")
    except SystemExit as e:
        if e.code not in (None, 0):
            error = e
    except BaseException as e:  # noqa: BLE001 - every failure of the script is reported
        error = e

    report = None
    if capture is not None:
        sys.stdout.flush()
        os.dup2(saved, 1)
        os.close(saved)
        capture.seek(0)
        captured = capture.read()
        capture.close()
        if error is None:
            report, why = _report(captured, run_id, opts["target"])
            if why is not None:
                error = ValueError("report: " + why)
        if error is not None:
            sys.stderr.write(captured.decode("utf-8", "replace"))

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
    if report is not None:
        with open(opts["report"], "w", encoding="utf-8") as f:
            f.write(json.dumps(report, indent=2, allow_nan=False) + "\n")
    with open(opts["out"], "w") as f:
        f.write(verdict + "\n")


if __name__ == "__main__":
    main()
