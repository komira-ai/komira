"""Installs wheels into an empty prefix and runs one test with the prefix's
interpreter, as a user who ran `pip install` into a new virtual environment
would; the action of `wheel_install_test` (python/install_test.bzl).

    python3.<minor> -I -S wheel_install_run.py --installer <wheel_install.py>
        --out <file> --tmpdir <dir> --wheel <file.whl>... [--skip-requirements]
        [--upgrade]
        [--host-lib <lib>]... [--arg <text>]... [--path-arg <flag>=<path>]...
        [--expect-failure <line>] --script <test.py>

Run with the hermetic interpreter, which is also the interpreter of the
prefix. In order:

1. The prefix is `<tmpdir>/prefix`, a virtual environment of this
   interpreter: `pyvenv.cfg` naming this interpreter's directory as `home`,
   `bin/python3.<minor>` a link to it, and nothing in
   `lib/python3.<minor>/site-packages/`, its one site directory.
2. Each wheel's tag must be one this interpreter installs: a Python tag `py3`,
   `py3<minor>` or `cp3<minor>` with the ABI tag `none` or `cp3<minor>` (an
   extension module built for this minor alone, pyarrow's), or the stable ABI
   `cp3<k>-abi3` with <k> at most this minor (built for 3.<k> and later,
   protobuf's), and the platform `any`
   or `manylinux_2_<n>_<machine>` (or `manylinux2014_<machine>`) with this
   machine and <n> at most the C library's minor version, or, on macOS,
   `macosx_<major>_<minor>_<machine>` with this machine (`arm64`) or
   `universal2` and a version at most the macOS version this runs on.
3. Each wheel is installed into the site directory by `install` of
   `--installer` (tools/build/python/wheel_install.py, what `python_wheel`
   runs): every member at its path, a `.data/` directory's `purelib/` and
   `platlib/` merged in. Its distribution and version are read from its file
   name, and the installer holds its `.dist-info` to them. With `--upgrade`,
   the wheels are the releases of one distribution in the order they are
   installed (a release's requirements may come first), and each replaces the
   one installed before it as `pip install`
   of a newer version does: first every file the installed release's RECORD
   lists is deleted, and the directories that leave empty, then the new
   release is installed. Without it, an installed distribution is not
   uninstalled, and a second wheel of it is refused.
4. Every installed distribution's `Requires-Python` must hold for this
   interpreter, and, unless `--skip-requirements` (pip's `--no-deps`), every
   one of its `Requires-Dist` must be met by an installed distribution. A
   requirement with an environment marker other than an extra is refused:
   none of the pinned wheels has one, and this is not a marker evaluator.
5. `--script` runs as `<prefix>/bin/python3.<minor> -I <script>`, from the
   empty directory `<tmpdir>/run`, with this process's environment unchanged
   (the rule sets no library path), and the arguments `--site <site directory>`,
   `--host-lib <absolute path>` for each `--host-lib`, each `--arg`, each
   `--path-arg` as `<flag> <absolute path>`, and, after an upgrade, `--removed
   <path below the site directory>` for each file the replaced release had
   that the new one does not (its `.dist-info` files left out): what the
   script holds to be gone.

A refusal of steps 2 to 4 is the line `install: <reason>`; a failure of the
script is the last line it wrote to stderr (the traceback's `Type: message`).
Without `--expect-failure`, any failure fails this run. With it, the run
passes only if there is a failure and its line equals the given one once the
site directory is written `<site>` and this interpreter's prefix `<python>`.
On a pass, `--tmpdir` is emptied and `--out` written; otherwise this exits 1.
"""

import csv
import email.parser
import importlib.util
import os
import platform
import re
import shutil
import subprocess
import sys


class Refused(Exception):
    """A wheel or an installed distribution the prefix cannot take."""


def _usage(msg):
    sys.stderr.write("wheel_install_run: " + msg + "\n")
    sys.exit(2)


_VALUED = ("--installer", "--out", "--tmpdir", "--wheel", "--host-lib", "--arg", "--path-arg", "--expect-failure", "--script")
_REPEATED = ("--wheel", "--host-lib", "--arg", "--path-arg")


def parse(argv):
    """The options of `argv`, as {name: value or list}; exits 2 on a malformed
    command line."""
    opts = {k[2:].replace("-", "_"): [] for k in _REPEATED}
    opts["skip_requirements"] = False
    opts["upgrade"] = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--skip-requirements", "--upgrade"):
            opts[a[2:].replace("-", "_")] = True
            i += 1
            continue
        if a not in _VALUED:
            _usage("unknown flag " + a)
        if i + 1 >= len(argv):
            _usage("flag " + a + " needs a value")
        key = a[2:].replace("-", "_")
        if a in _REPEATED:
            opts[key].append(argv[i + 1])
        elif key in opts:
            _usage("flag " + a + " given twice")
        else:
            opts[key] = argv[i + 1]
        i += 2
    for key in ("installer", "out", "tmpdir", "script"):
        if key not in opts:
            _usage("--{} is required".format(key))
    if not opts["wheel"]:
        _usage("no --wheel")
    for p in opts["path_arg"]:
        if "=" not in p:
            _usage("--path-arg {} is not <flag>=<path>".format(p))
    return opts


def normalize(name):
    """The PEP 503 normalized form of a distribution name."""
    return re.sub(r"[-_.]+", "-", name).lower()


def _version_tuple(text):
    if not re.fullmatch(r"[0-9]+(\.[0-9]+)*", text):
        raise Refused("version {} is not a plain release version".format(text))
    return tuple(int(p) for p in text.split("."))


def _cmp(a, b):
    n = max(len(a), len(b))
    a = a + (0,) * (n - len(a))
    b = b + (0,) * (n - len(b))
    return (a > b) - (a < b)


_OPS = {
    "==": lambda c: c == 0,
    "!=": lambda c: c != 0,
    ">=": lambda c: c >= 0,
    "<=": lambda c: c <= 0,
    ">": lambda c: c > 0,
    "<": lambda c: c < 0,
}


def satisfies(version, specifier):
    """Whether `version` (a plain release, `1.0.0`) meets every clause of
    `specifier` (`>=3.13`, `==1.0.0`, `>=1,<2`); an empty one is met."""
    have = _version_tuple(version)
    for clause in [c.strip() for c in specifier.split(",") if c.strip()]:
        m = re.fullmatch(r"(==|!=|>=|<=|>|<)\s*([0-9.]+)", clause)
        if not m:
            raise Refused("specifier clause {} is not one of ==, !=, >=, <=, >, < and a version".format(clause))
        if not _OPS[m.group(1)](_cmp(have, _version_tuple(m.group(2)))):
            return False
    return True


def parse_requirement(line):
    """(normalized name, specifier) of a `Requires-Dist` line, or None for one
    that only an extra turns on; refuses any other environment marker."""
    text, _, marker = line.partition(";")
    marker = marker.strip()
    if marker:
        if re.fullmatch(r"extra\s*==\s*['\"][^'\"]*['\"]", marker):
            return None
        raise Refused("the requirement {} has the environment marker {}, which is not evaluated here".format(line.strip(), marker))
    m = re.fullmatch(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*(\[[^\]]*\])?\s*\(?([^)]*)\)?\s*", text)
    if not m:
        raise Refused("the requirement {} is not <name><specifier>".format(line.strip()))
    return normalize(m.group(1)), m.group(3).strip()


def supported(tag, minor, machine, glibc, system="linux", macos=(0, 0)):
    """Whether this interpreter installs a wheel tagged `tag`
    (`py3-none-manylinux_2_34_x86_64`, `py3-none-macosx_11_0_arm64`,
    `cp310-abi3-manylinux2014_x86_64`; each part may be a `.`-joined set):
    CPython 3.<minor> on `machine` with glibc
    `glibc` ((major, minor)) when `system` is "linux", or on macOS version
    `macos` ((major, minor)) when it is "darwin". A `manylinux` platform
    needs Linux and a `macosx` one needs macOS."""
    parts = tag.split("-")
    if len(parts) != 3:
        return False
    pys, abis, plats = (p.split(".") for p in parts)
    exact = bool(set(pys) & {"py3", "py3{}".format(minor), "cp3{}".format(minor)}) and bool(
        set(abis) & {"none", "cp3{}".format(minor)}
    )
    # The stable ABI: `cp3<k>-abi3` is built for CPython 3.<k> and runs on
    # every later CPython 3, as pip installs it.
    stable = "abi3" in abis and any(
        re.fullmatch(r"cp3(\d+)", py) and int(py[3:]) <= minor for py in pys
    )
    if not (exact or stable):
        return False
    for plat in plats:
        if plat == "any":
            return True
        if system == "darwin":
            m = re.fullmatch(r"macosx_(\d+)_(\d+)_(.+)", plat)
            # `universal2` holds both arm64 and x86_64 code.
            if m and m.group(3) in (machine, "universal2") and (int(m.group(1)), int(m.group(2))) <= macos:
                return True
            continue
        if system != "linux":
            continue
        m = re.fullmatch(r"manylinux_(\d+)_(\d+)_(.+)", plat) or re.fullmatch(r"manylinux2014_()()(.+)", plat)
        if not m or m.group(3) != machine:
            continue
        floor = (2, 17) if m.group(1) == "" else (int(m.group(1)), int(m.group(2)))
        if floor <= glibc:
            return True
    return False


def wheel_name_version_tag(path):
    """(distribution, version, tag) of a wheel's file name
    (`<name>-<version>-<python>-<abi>-<platform>.whl`)."""
    base = os.path.basename(path)
    if not base.endswith(".whl"):
        raise Refused("{} is not a .whl file".format(base))
    parts = base[: -len(".whl")].split("-")
    if len(parts) != 5:
        raise Refused("{} is not <name>-<version>-<python>-<abi>-<platform>.whl".format(base))
    return parts[0], parts[1], "-".join(parts[2:])


def glibc_version():
    """The C library's (major, minor), or (0, 0) when it is not glibc."""
    try:
        text = os.confstr("CS_GNU_LIBC_VERSION") or ""
    except (ValueError, OSError):
        return (0, 0)
    m = re.fullmatch(r"glibc (\d+)\.(\d+).*", text)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


def macos_version():
    """The macOS (major, minor) this runs on (platform.mac_ver()), or (0, 0)
    when it is not macOS."""
    text = platform.mac_ver()[0]
    m = re.match(r"(\d+)\.(\d+)", text) or re.fullmatch(r"(\d+)()", text)
    version = (int(m.group(1)), int(m.group(2) or 0)) if m else (0, 0)
    # An interpreter built against an SDK older than macOS 11 is told 10.16
    # on every macOS 11 or newer: it means at least 11.0.
    return (11, 0) if version == (10, 16) else version


def installed(site):
    """{normalized name: (version, Requires-Python, [Requires-Dist])} of every
    `.dist-info` directory in `site`."""
    out = {}
    for entry in sorted(os.listdir(site)):
        if not entry.endswith(".dist-info"):
            continue
        with open(os.path.join(site, entry, "METADATA"), encoding="utf-8") as f:
            meta = email.parser.Parser().parse(f, headersonly=True)
        out[normalize(meta.get("Name", ""))] = (
            meta.get("Version", ""),
            meta.get("Requires-Python", ""),
            meta.get_all("Requires-Dist") or [],
        )
    return out


def check_installed(dists, python_version, skip_requirements):
    """Refuses the first distribution of `dists` (installed()) whose
    Requires-Python `python_version` does not meet, or, unless
    `skip_requirements`, one of whose requirements no installed distribution
    meets."""
    for name in sorted(dists):
        version, requires_python, requires = dists[name]
        if requires_python and not satisfies(python_version, requires_python):
            raise Refused("{} requires Python {}; this interpreter is {}".format(name, requires_python, python_version))
        if skip_requirements:
            continue
        for line in requires:
            req = parse_requirement(line)
            if req is None:
                continue
            want, spec = req
            if want not in dists:
                raise Refused("{} {} requires {}, which is not installed".format(name, version, line.strip()))
            if not satisfies(dists[want][0], spec):
                raise Refused("{} {} requires {}; {} {} is installed".format(name, version, line.strip(), want, dists[want][0]))


def make_prefix(prefix, minor):
    """An empty virtual environment of this interpreter at `prefix`; returns
    (its interpreter, its site directory)."""
    exe = os.path.realpath(sys.executable)
    os.makedirs(os.path.join(prefix, "bin"))
    site = os.path.join(prefix, "lib", "python3.{}".format(minor), "site-packages")
    os.makedirs(site)
    with open(os.path.join(prefix, "pyvenv.cfg"), "w", encoding="utf-8") as f:
        f.write("home = {}\ninclude-system-site-packages = false\nversion = {}\n".format(os.path.dirname(exe), platform.python_version()))
    venv_exe = os.path.join(prefix, "bin", "python3.{}".format(minor))
    os.symlink(exe, venv_exe)
    return venv_exe, site


def _load_installer(path):
    spec = importlib.util.spec_from_file_location("wheel_install", os.path.abspath(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def installed_files(site, name):
    """The paths (relative to `site`, `/`-separated) of the RECORD of the
    installed distribution `name`, or None when it is not installed. Raises
    Refused for a distribution installed more than once or with no RECORD."""
    dirs = [
        e
        for e in sorted(os.listdir(site))
        if e.endswith(".dist-info") and normalize(e[: -len(".dist-info")].rpartition("-")[0]) == normalize(name)
    ]
    if not dirs:
        return None
    if len(dirs) > 1:
        raise Refused("{} is installed more than once: {}".format(normalize(name), ", ".join(dirs)))
    record = os.path.join(site, dirs[0], "RECORD")
    if not os.path.isfile(record):
        raise Refused("{} has no RECORD, so it cannot be uninstalled".format(dirs[0]))
    with open(record, encoding="utf-8", newline="") as f:
        return [row[0] for row in csv.reader(f) if row]


def uninstall(site, paths):
    """Deletes the files `paths` (relative to `site`) and the directories that
    leave empty, never `site` itself; a path that is gone is skipped."""
    root = os.path.abspath(site)
    for rel in paths:
        path = os.path.normpath(os.path.join(root, rel))
        if os.path.isabs(rel) or not path.startswith(root + os.sep):
            raise Refused("the RECORD path {} leaves the site directory".format(rel))
        if os.path.lexists(path):
            os.unlink(path)
        parent = os.path.dirname(path)
        while parent != root and os.path.isdir(parent) and not os.listdir(parent):
            os.rmdir(parent)
            parent = os.path.dirname(parent)


def install_all(installer, wheels, site, minor, upgrade=False):
    """Installs each of `wheels` into `site` after checking its tag. With
    `upgrade`, a wheel replaces the installed release of its distribution
    (see the module docstring). Returns the files the last replaced release had
    that its replacement lacks, sorted, `.dist-info` files left out: empty when
    nothing was replaced."""
    machine = platform.machine()
    system = "darwin" if sys.platform == "darwin" else "linux"
    glibc = glibc_version()
    macos = macos_version()
    removed = []
    for wheel in wheels:
        name, version, tag = wheel_name_version_tag(wheel)
        if not supported(tag, minor, machine, glibc, system, macos):
            raise Refused(
                "the wheel of {} is tagged {}, which this interpreter (CPython 3.{} on {}{}) does not install".format(
                    normalize(name), tag, minor, "macOS " + platform.mac_ver()[0] + " " if system == "darwin" else "", machine
                )
            )
        old = installed_files(site, name)
        if old is not None and not upgrade:
            raise Refused("{} is already installed, and a second wheel of it is installed only with --upgrade".format(normalize(name)))
        if old is not None:
            uninstall(site, old)
        installer.install(os.path.abspath(wheel), name, version, site)
        if old is not None:
            kept = set(installed_files(site, name))
            removed = sorted(p for p in set(old) - kept if ".dist-info/" not in p)
    return removed


def normalized(line, site, python_prefix):
    """`line` with the site directory written `<site>` and the interpreter's
    prefix `<python>`, each in its given and its resolved spelling."""
    for path, token in ((site, "<site>"), (python_prefix, "<python>")):
        for spelling in sorted({os.path.realpath(path), os.path.abspath(path)}, key=len, reverse=True):
            line = line.replace(spelling, token)
    return line


def last_line(text):
    lines = [l for l in text.splitlines() if l.strip()]
    return lines[-1] if lines else ""


def run(opts):
    """The failure line of the install and the run, or None when both passed."""
    minor = sys.version_info.minor
    tmp = os.path.abspath(opts["tmpdir"])
    os.makedirs(tmp, exist_ok=True)
    prefix = os.path.join(tmp, "prefix")
    workdir = os.path.join(tmp, "run")
    os.makedirs(workdir)
    venv_exe, site = make_prefix(prefix, minor)
    try:
        removed = install_all(_load_installer(opts["installer"]), opts["wheel"], site, minor, opts["upgrade"])
        check_installed(installed(site), platform.python_version(), opts["skip_requirements"])
    except Refused as e:
        return "install: {}".format(e), site
    cmd = [venv_exe, "-I", os.path.abspath(opts["script"]), "--site", site]
    for lib in opts["host_lib"]:
        cmd += ["--host-lib", os.path.abspath(lib)]
    for a in opts["arg"]:
        cmd.append(a)
    for p in removed:
        cmd += ["--removed", p]
    for p in opts["path_arg"]:
        flag, _, path = p.partition("=")
        cmd += [flag, os.path.abspath(path)]
    proc = subprocess.run(cmd, cwd=workdir, env=dict(os.environ), capture_output=True, text=True)
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr)
    if proc.returncode == 0:
        return None, site
    return last_line(proc.stderr) or "exit status {}".format(proc.returncode), site


def main():
    opts = parse(sys.argv[1:])
    failure, site = run(opts)
    want = opts.get("expect_failure")
    got = None if failure is None else normalized(failure, site, sys.prefix)
    if want is None:
        if got is not None:
            sys.stderr.write("wheel_install_run: failed: {}\n".format(got))
            sys.exit(1)
        verdict = "PASS"
    else:
        if got is None:
            sys.stderr.write("wheel_install_run: was expected to fail with '{}', and it passed\n".format(want))
            sys.exit(1)
        if got != want:
            sys.stderr.write("wheel_install_run: was expected to fail with '{}', it failed with '{}'\n".format(want, got))
            sys.exit(1)
        verdict = "PASS (failed as expected: {})".format(got)
    tmp = os.path.abspath(opts["tmpdir"])
    for name in os.listdir(tmp):
        path = os.path.join(tmp, name)
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            os.unlink(path)
    with open(opts["out"], "w", encoding="utf-8") as f:
        f.write(verdict + "\n")


if __name__ == "__main__":
    main()
