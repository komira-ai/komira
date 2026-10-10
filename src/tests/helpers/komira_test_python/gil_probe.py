"""Holds a CPython 3.14 interpreter and its closure to the pins, and records which imports enable the GIL.

Arguments:

- `python=<version>`: the interpreter's version (`sys.version_info`);
- `build=gil` or `build=freethreaded`: whether the interpreter is a
  free-threaded build (`Py_GIL_DISABLED`), and so whether the GIL is enabled
  when the script starts (`sys._is_gil_enabled()`);
- `preload=<path>`, repeated: the shared libraries `py_test` loaded before
  the script, which each child interpreter loads too;
- `<distribution>=<version>`, one per wheel of the closure;
- `gil:<distribution>=<state>`, one per wheel: the GIL's state after a fresh
  interpreter imports the distribution's module, `disabled`, `enabled`
  (it was enabled before the import), or `enabled by <module>[, <module>]`:
  the modules CPython names in the warning it gives when it enables the GIL
  to load an extension module that does not declare it can run without it;
- `gil-every:<distribution>=<state>`, one per wheel: the same after the
  module and then every extension module the distribution installs are
  imported, followed by `; failed to import <module> (<ExceptionType>), ...`
  for those that do not import alone.

Each distribution is imported in a child interpreter of its own (the same
executable, `-I -S`), since the GIL, once enabled, stays enabled for the
process. Fails unless the version and the build are the pins, the
distributions named are exactly MODULES, each imports at its pinned version,
the GIL is in its build's state at the start of the script and of every
child, each import leaves the GIL in the pinned state, and the self-checks
pass (check_state: the warning parser over synthetic results, and on 3.14t
the warning's text in the interpreter's own files; check_child: how a
child's result or failure is read). No import of the pinned closure enables
the GIL, so the `enabled by <module>` reading and the before/after
distinction are proved by check_state alone, not by a real import. Every row is
printed before the verdict, so one failing run shows the whole table.
"""

import json
import os
import re
import subprocess
import sys
import sysconfig

# distribution -> the module a UDF would import.
MODULES = {
    "cloudpickle": "cloudpickle",
    "joblib": "joblib",
    "narwhals": "narwhals",
    "numpy": "numpy",
    "pandas": "pandas",
    "pyarrow": "pyarrow",
    "python-dateutil": "dateutil",
    "scikit-learn": "sklearn",
    "scipy": "scipy",
    "six": "six",
    "threadpoolctl": "threadpoolctl",
    "tzdata": "tzdata",
}

# Run as `python -I -S -c CHILD <json>`; prints one JSON object.
# With `every` set, it then imports each extension module the distribution
# installs, in name order, and lists those that fail to import.
CHILD = r"""
import ctypes, importlib, importlib.machinery, importlib.metadata, json, sys, warnings
preload, path, module, dist, every = json.loads(sys.argv[1])
for lib in preload:
    ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)
sys.path[:] = path
before = sys._is_gil_enabled()
failed = []
with warnings.catch_warnings(record=True) as caught:
    warnings.simplefilter("always")
    importlib.import_module(module)
    if every:
        names = set()
        for f in importlib.metadata.files(dist) or []:
            # A tagged suffix (`.cpython-314t-x86_64-linux-gnu.so`, `.abi3.so`):
            # a file ending only in the bare ".so" is a shared library the
            # wheel bundles (libarrow_python.so, OpenBLAS), not a module.
            hits = [x for x in importlib.machinery.EXTENSION_SUFFIXES if x != ".so" and str(f).endswith(x)]
            if hits:
                names.add(str(f)[: -len(max(hits, key=len))].replace("/", "."))
        for name in sorted(names):
            try:
                importlib.import_module(name)
            except Exception as e:
                failed.append("%s (%s)" % (name, type(e).__name__))
after = sys._is_gil_enabled()
print(json.dumps({
    "before": before,
    "after": after,
    "failed": failed,
    "version": importlib.metadata.version(dist),
    "warnings": [str(w.message) for w in caught],
}))
"""

ENABLED_TO_LOAD = re.compile(r"has been enabled to load module '([^']+)'")


def state(result):
    """The GIL's state after the imports, in the form of a `gil:` pin."""
    if not result["after"]:
        got = "disabled"
    elif result["before"]:
        got = "enabled"
    else:
        named = sorted({m.group(1) for w in result["warnings"] for m in [ENABLED_TO_LOAD.search(w)] if m})
        got = "enabled by " + ", ".join(named) if named else "enabled by no warning"
    if result["failed"]:
        got += "; failed to import " + ", ".join(result["failed"])
    return got


# The warning CPython 3.14 gives when it enables the GIL to load an extension
# module (Python/import.c), as the free-threaded interpreter holds it, with
# the module's name for `%U`.
WARNING = "The global interpreter lock (GIL) has been enabled to load module '%U', which has not declared that it can run safely without the GIL."


def check_state(freethreaded):
    """state() reads each kind of result, and the warning it parses is the interpreter's own text."""
    def result(before, after, warnings=(), failed=()):
        return {"before": before, "after": after, "warnings": list(warnings), "failed": list(failed)}

    one = WARNING.replace("%U", "pkg._native")
    two = WARNING.replace("%U", "pkg._other")
    cases = [
        (result(False, False), "disabled"),
        (result(True, True), "enabled"),
        (result(False, True, [two, "an unrelated warning", one]), "enabled by pkg._native, pkg._other"),
        (result(False, True), "enabled by no warning"),
        (result(False, False, failed=["pkg._x (ImportError)"]), "disabled; failed to import pkg._x (ImportError)"),
    ]
    for r, want in cases:
        got = state(r)
        assert got == want, "state({}) is {!r}, not {!r}".format(r, got, want)
    if freethreaded:
        template = WARNING.split("%U")[0].encode() + b"%U'"
        found = []
        for d, _, files in os.walk(sys.prefix):
            for f in files:
                p = os.path.join(d, f)
                if (p == os.path.realpath(sys.executable) or f.startswith("libpython")) and not os.path.islink(p):
                    with open(p, "rb") as fh:
                        if template in fh.read():
                            found.append(os.path.relpath(p, sys.prefix))
        assert found, "no file of the interpreter holds the warning text {!r}".format(template)
        print("warning text found in", ", ".join(sorted(found)))


def child(preload, module, dist, every, program=CHILD):
    """The child's JSON result, or why it gave none; `program` replaces the child's code (check_child)."""
    proc = subprocess.run(
        [sys.executable, "-I", "-S", "-c", program, json.dumps([preload, sys.path, module, dist, every])],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        tail = proc.stderr.strip().splitlines()[-1:] or ["(no output)"]
        return None, "exit {}: {}".format(proc.returncode, tail[0])
    return json.loads(proc.stdout.strip().splitlines()[-1]), None


def check_child():
    """child() reads the last line of a child that exits 0, and reports a child that does not by its status and last error line."""
    programs = [
        ("print('noise'); print('{\"after\": false}')", ({"after": False}, None)),
        ("import sys; sys.stderr.write('first\\nlast line\\n'); sys.exit(3)", (None, "exit 3: last line")),
        ("import sys; sys.exit(2)", (None, "exit 2: (no output)")),
        ("import os, signal; os.kill(os.getpid(), signal.SIGKILL)", (None, "exit -9: (no output)")),
    ]
    for program, want in programs:
        got = child([], "unused", "unused", False, program)
        assert got == want, "a child running {!r} reads as {!r}, not {!r}".format(program, got, want)


def main(args):
    pins, gil, gil_every, preload = {}, {}, {}, []
    for a in args:
        key, _, value = a.partition("=")
        if key == "preload":
            preload.append(value)
        elif key.startswith("gil:"):
            gil[key[len("gil:") :]] = value
        elif key.startswith("gil-every:"):
            gil_every[key[len("gil-every:") :]] = value
        else:
            pins[key] = value
    want_python = pins.pop("python")
    build = pins.pop("build")
    assert build in ("gil", "freethreaded"), "build is {!r}, not gil or freethreaded".format(build)
    freethreaded = build == "freethreaded"
    check_state(freethreaded)
    check_child()

    bad = []
    got_python = "%d.%d.%d" % sys.version_info[:3]
    if got_python != want_python:
        bad.append("python is {}, the pin says {}".format(got_python, want_python))
    got_ft = bool(sysconfig.get_config_var("Py_GIL_DISABLED"))
    if got_ft != freethreaded:
        bad.append("Py_GIL_DISABLED is {}, the pin says build={}".format(sysconfig.get_config_var("Py_GIL_DISABLED"), build))
    if sys._is_gil_enabled() == freethreaded:
        bad.append("the GIL is {} at startup on a build={} interpreter".format("enabled" if freethreaded else "disabled", build))
    print("python", got_python, "build", build, "gil at startup", "enabled" if sys._is_gil_enabled() else "disabled")
    if sorted(pins) != sorted(MODULES) or sorted(gil) != sorted(MODULES) or sorted(gil_every) != sorted(MODULES):
        bad.append("pinned {} with gil states for {} and {}, but gil_probe.py checks {}".format(sorted(pins), sorted(gil), sorted(gil_every), sorted(MODULES)))

    for dist in sorted(MODULES):
        for every, pinned in [(False, gil), (True, gil_every)]:
            what = "every extension module of " + dist if every else "import " + MODULES[dist]
            result, err = child(preload, MODULES[dist], dist, every)
            if err is not None:
                bad.append("{}: {} failed: {}".format(dist, what, err))
                continue
            got = state(result)
            print("{} {}, {}: {}".format(dist, result["version"], what, got))
            if result["version"] != pins.get(dist):
                bad.append("{} is {}, the pin says {}".format(dist, result["version"], pins.get(dist)))
            if result["before"] == freethreaded:
                bad.append("{}: the GIL is {} when a child starts".format(dist, "enabled" if freethreaded else "disabled"))
            if got != pinned.get(dist):
                bad.append("{}: after {} the GIL is {!r}, the pin says {!r}".format(dist, what, got, pinned.get(dist)))
    assert not bad, "\n".join(bad)


main(sys.argv[1:])
