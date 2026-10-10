"""Installs one wheel into a directory, as `python_wheel` does; no pip.

    python3.<minor> -I -S wheel_install.py --wheel <file.whl> --name <distribution>
        --version <version> --out <dir>

Refuses (exit 2) a wheel that does not hold exactly one `.dist-info`
directory, or whose `.dist-info` directory name or METADATA `Name` and
`Version` are not the pinned distribution and version. Then writes every
member of the wheel under `--out` at its path, except the members of
`<name>-<version>.data/`: those under `purelib/` and `platlib/` are written at
their path below that directory, and those under `scripts/`, `headers/` and
`data/` are not written. A member whose path is absolute or leaves `--out` is
refused.
"""

import email.parser
import os
import re
import shutil
import sys
import zipfile


def _fail(msg):
    sys.stderr.write("wheel_install: " + msg + "\n")
    sys.exit(2)


def normalize(name):
    """The PEP 503 normalized form of a distribution name."""
    return re.sub(r"[-_.]+", "-", name).lower()


def _parse(argv):
    opts = {}
    if len(argv) % 2:
        _fail("flags come in pairs: " + " ".join(argv))
    for i in range(0, len(argv), 2):
        key = argv[i]
        if key not in ("--wheel", "--name", "--version", "--out"):
            _fail("unknown flag " + key)
        opts[key[2:]] = argv[i + 1]
    for key in ("wheel", "name", "version", "out"):
        if key not in opts:
            _fail("--{} is required".format(key))
    return opts


def install(wheel, name, version, out):
    with zipfile.ZipFile(wheel) as z:
        tops = sorted({m.split("/", 1)[0] for m in z.namelist()})
        infos = [t for t in tops if t.endswith(".dist-info")]
        if len(infos) != 1:
            _fail("{} holds {} .dist-info directories ({}), not 1".format(os.path.basename(wheel), len(infos), ", ".join(infos)))
        info = infos[0]
        stem = info[: -len(".dist-info")]
        got_name, _, got_version = stem.partition("-")
        if normalize(got_name) != normalize(name) or got_version != version:
            _fail("{} holds {}, the pin says {} {}".format(os.path.basename(wheel), info, name, version))
        meta = email.parser.Parser().parsestr(z.read(info + "/METADATA").decode("utf-8"), headersonly=True)
        if normalize(meta.get("Name", "")) != normalize(name) or meta.get("Version", "") != version:
            _fail("{} METADATA says {} {}, the pin says {} {}".format(os.path.basename(wheel), meta.get("Name"), meta.get("Version"), name, version))
        data = stem + ".data/"
        root = os.path.abspath(out)
        os.makedirs(root, exist_ok=True)
        for member in z.infolist():
            path = member.filename
            if path.startswith(data):
                kind, _, path = path[len(data) :].partition("/")
                if kind not in ("purelib", "platlib"):
                    continue
            if member.is_dir() or not path:
                continue
            dest = os.path.normpath(os.path.join(root, path))
            if os.path.isabs(path) or not dest.startswith(root + os.sep):
                _fail("{}: member {} leaves the install directory".format(os.path.basename(wheel), member.filename))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with z.open(member) as src, open(dest, "wb") as dst:
                shutil.copyfileobj(src, dst)


def main():
    opts = _parse(sys.argv[1:])
    install(opts["wheel"], opts["name"], opts["version"], opts["out"])


if __name__ == "__main__":
    main()
