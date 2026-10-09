"""Runs one oracle script twice and keeps its output only if both runs agree, as `python_oracle` does.

    python3.<minor> -I -S oracle_run.py --out <dir> --tmpdir <dir> --data <dir>
        [--preload <lib>]... [--site <dir>]... [--outs <path>]...
        -- <script> [<arg>]...

Runs the script in two child interpreters, one after the other. Each child is
`python3.<minor> -s -S -P` with the environment `LC_ALL=C`,
`PYTHONHASHSEED=0`, `TZ=UTC0` and, if this process has one, `TZDIR` made
absolute, and nothing else, so `str` and `bytes` hashes, and with them the
iteration order of a set of strings, are the same in every run. A child
makes `TZDIR` `zoneinfo`'s only search path (with no `TZDIR`, the path is
empty and only an importable `tzdata` package is read): never the
interpreter's built-in path, which names the worker's /usr/share/zoneinfo. A
child loads each `--preload` library by path (RTLD_GLOBAL, in the order
given), puts the script's directory first on `sys.path` and each `--site`
directory after the standard library, points `tempfile` at a directory of
its own (also its current directory), and runs the script as `__main__` with

    sys.argv = [<script>, <output directory>, <data directory>, <arg>...]

The first run writes into `--out`, the second into a directory under
`--tmpdir`. The oracle passes when both runs exit 0 and the two directories
hold the same tree: the same relative paths, each a directory or a regular
file, files with the same bytes and the same executable bit. A symlink is
refused. With `--outs`, the files written must be exactly those paths; without
it, at least one file must be written. On a pass `--tmpdir` is emptied;
otherwise this exits 1 with one line naming the first difference, in the
order of a sorted walk:

    python_oracle: <script> failed: <last traceback line>
    python_oracle: two runs of <script> differ at <path>: <what>
    python_oracle: <script> wrote <path>, which outs does not declare
    python_oracle: <script> did not write <path>
    python_oracle: <script> wrote nothing
    python_oracle: <script> wrote a symlink at <path>
    python_oracle: the <first|second> run of <script> exited <status>

(the last when a child ends other than by exiting 0 or 1, e.g. on a signal).
"""

import ctypes
import os
import runpy
import shutil
import stat
import subprocess
import sys
import tempfile
import traceback
import zoneinfo

_CHILD = "--child"
# TZ is a POSIX rule, so the C library's local time is UTC from no file.
_ENV = {"LC_ALL": "C", "PYTHONHASHSEED": "0", "TZ": "UTC0"}


def _usage(msg):
    sys.stderr.write("oracle_run: " + msg + "\n")
    sys.exit(2)


def _parse(argv):
    opts = {"out": None, "tmpdir": None, "data": None, "preload": [], "site": [], "outs": []}
    lists = {"--preload": "preload", "--site": "site", "--outs": "outs"}
    single = {"--out": "out", "--tmpdir": "tmpdir", "--data": "data"}
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
        if a in lists:
            opts[lists[a]].append(argv[i + 1])
        elif a in single:
            opts[single[a]] = argv[i + 1]
        else:
            _usage("unknown flag " + a)
        i += 2
    _usage("no -- before the script")


def _last_line(exc):
    return traceback.format_exception_only(type(exc), exc)[-1].rstrip("\n")


def _child(argv):
    """In a child interpreter: run the script once; exit 0 only if it passed."""
    # argv: <out> <tmp> <data> <script> <preload count> <preload>... <site>... -- <arg>...
    out, tmp, data, script, n = argv[0], argv[1], argv[2], argv[3], int(argv[4])
    preload = argv[5 : 5 + n]
    rest = argv[5 + n :]
    sep = rest.index("--")
    sites, args = rest[:sep], rest[sep + 1 :]
    if sys.flags.hash_randomization:
        sys.stderr.write("python_oracle: the child interpreter hashes with a random seed (PYTHONHASHSEED is not 0)\n")
        sys.exit(1)
    for lib in preload:
        ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)
    tzdir = os.environ.get("TZDIR")
    zoneinfo.reset_tzpath([tzdir] if tzdir else [])
    tempfile.tempdir = tmp
    os.chdir(tmp)
    sys.path[:] = [os.path.dirname(script)] + [p for p in sys.path if p] + sites
    sys.argv = [script, out, data] + args
    error = None
    try:
        runpy.run_path(script, run_name="__main__")
    except SystemExit as e:
        if e.code in (None, 0):
            return
        error = e
    except BaseException as e:  # noqa: BLE001 - every failure of the script is reported
        traceback.print_exception(type(e), e, e.__traceback__)
        error = e
    if error is None:
        return
    sys.stderr.write("python_oracle: {} failed: {}\n".format(os.path.basename(script), _last_line(error)))
    sys.exit(1)


def _tree(root):
    """{relative path: ("dir",) | ("file", executable)} of `root`, or a symlink's path."""
    entries = {}
    for parent, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(dirs + files):
            path = os.path.join(parent, name)
            rel = os.path.relpath(path, root)
            mode = os.lstat(path).st_mode
            if stat.S_ISLNK(mode):
                return rel
            if stat.S_ISDIR(mode):
                entries[rel] = ("dir",)
            else:
                entries[rel] = ("file", bool(mode & stat.S_IXUSR))
    return entries


def _same_bytes(a, b):
    with open(a, "rb") as fa, open(b, "rb") as fb:
        while True:
            x = fa.read(1 << 16)
            y = fb.read(1 << 16)
            if x != y:
                return False
            if not x:
                return True


def _verdict(name, first, second, outs):
    """None when the two output trees agree and match `outs`, else the failure line."""
    trees = []
    for root in (first, second):
        t = _tree(root)
        if isinstance(t, str):
            return "{} wrote a symlink at {}".format(name, t)
        trees.append(t)
    a, b = trees
    for rel in sorted(set(a) | set(b)):
        if rel not in a or rel not in b:
            return "two runs of {} differ at {}: only the {} run wrote it".format(name, rel, "first" if rel in a else "second")
        if a[rel][0] != b[rel][0]:
            return "two runs of {} differ at {}: a {} in the first run, a {} in the second".format(name, rel, a[rel][0], b[rel][0])
        if a[rel][0] == "file":
            if a[rel][1] != b[rel][1]:
                return "two runs of {} differ at {}: the executable bit".format(name, rel)
            if not _same_bytes(os.path.join(first, rel), os.path.join(second, rel)):
                return "two runs of {} differ at {}: the bytes".format(name, rel)
    files = sorted(rel for rel, kind in a.items() if kind[0] == "file")
    if outs:
        for rel in files:
            if rel not in outs:
                return "{} wrote {}, which outs does not declare".format(name, rel)
        for rel in sorted(outs):
            if rel not in a or a[rel][0] != "file":
                return "{} did not write {}".format(name, rel)
    elif not files:
        return "{} wrote nothing".format(name)
    return None


def _empty(path):
    for name in os.listdir(path):
        p = os.path.join(path, name)
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p)
        else:
            os.unlink(p)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == _CHILD:
        _child(sys.argv[2:])
        return
    opts, script, args = _parse(sys.argv[1:])
    for flag in ("out", "tmpdir", "data"):
        if opts[flag] is None:
            _usage("--out, --tmpdir and --data are required")
    name = os.path.basename(script)
    script = os.path.abspath(script)
    data = os.path.abspath(opts["data"])
    tmp = os.path.abspath(opts["tmpdir"])
    os.makedirs(tmp, exist_ok=True)
    first = os.path.abspath(opts["out"])
    second = os.path.join(tmp, "second", "out")
    os.makedirs(first, exist_ok=True)
    os.makedirs(second)
    preload = [os.path.abspath(p) for p in opts["preload"]]
    sites = [os.path.abspath(s) for s in opts["site"]]
    python = os.path.abspath(sys.executable)
    env = dict(_ENV)
    tzdir = os.environ.get("TZDIR")
    if tzdir:
        env["TZDIR"] = os.path.abspath(tzdir)
    for run, out in (("first", first), ("second", second)):
        run_tmp = os.path.join(tmp, run, "tmp")
        os.makedirs(run_tmp)
        argv = [python, "-s", "-S", "-P", os.path.abspath(__file__), _CHILD, out, run_tmp, data, script, str(len(preload))]
        code = subprocess.call(argv + preload + sites + ["--"] + args, env=dict(env))
        if code != 0:
            # A child that exits 1 has printed its own line.
            if code != 1:
                sys.stderr.write("python_oracle: the {} run of {} exited {}\n".format(run, name, code))
            sys.exit(1)
    failure = _verdict(name, first, second, set(opts["outs"]))
    if failure is not None:
        sys.stderr.write("python_oracle: " + failure + "\n")
        sys.exit(1)
    _empty(tmp)


if __name__ == "__main__":
    main()
