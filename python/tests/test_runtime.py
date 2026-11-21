"""The Mojo runtime hook (komira/_runtime.py) on stand-in libraries: the check
of a runtime already in the process (the bundled flavour), the GNU build id
reader it compares files with, the external flavour's record and its load of
Modular's installed runtime, and which of the two `prepare` runs.

    test_runtime.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/<case>/ours/`, `<dir>/<case>/other/` and `<dir>/<case>/site/modular/lib/`
hold stand-ins of fake_runtime_lib.c (tests/BUCK) with the SONAME
`libfake_rt_<case>.so` and the build id of their target: `ours` plays
komira's `_lib/lib`, `other` a runtime loaded by someone else, `site` a site
directory where Modular's package installed the runtime. Each case has its own
SONAME, since a library is never unloaded: a case loads its copy by path with
ctypes, or has the hook load it, then runs the check. Files that are never
opened are written to a scratch directory. `--runtime-dir`, which the rule
passes, is not read.
"""

import ctypes
import os
import struct
import sys
import tempfile

from komira import LibraryLoadError
from komira import _runtime


def name(case):
    return "libfake_rt_{}.so".format(case)


def refused(call):
    try:
        call()
    except LibraryLoadError as e:
        assert type(e) is LibraryLoadError, repr(e)
        assert e.status is None, e.status
        return str(e)
    raise AssertionError("the check did not refuse")


def elf_with_notes(notes, *, phnum=None):
    """A 64-bit little-endian ELF header, a PT_LOAD and a PT_NOTE program
    header, and the notes [(owner, type, desc)] the PT_NOTE covers."""
    body = b""
    for owner, kind, desc in notes:
        pad = lambda b: b + b"\0" * (-len(b) % 4)
        body += struct.pack("<III", len(owner), len(desc), kind) + pad(owner) + pad(desc)
    phoff, phentsize = 64, 56
    count = 2 if phnum is None else phnum
    notes_at = phoff + 2 * phentsize
    head = b"\x7fELF\x02\x01\x01" + b"\0" * 9
    head += struct.pack("<HHIQQQIHHHHHH", 3, 62, 1, 0, phoff, 0, 0, 64, phentsize, count, 0, 0, 0)
    load = struct.pack("<IIQQQQQQ", 1, 5, 0, 0, 0, 0, 0, 0x1000)
    note = struct.pack("<IIQQQQQQ", 4, 4, notes_at, 0, 0, len(body), len(body), 4)
    return head + load + note + body


def write(directory, base, data):
    path = os.path.join(directory, base)
    with open(path, "wb") as f:
        f.write(data)
    return path


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    scratch = tempfile.mkdtemp()

    def ours(case):
        return os.path.join(lib_dir, case, "ours")

    def other(case):
        return os.path.join(lib_dir, case, "other")

    def check(case, **kw):
        return _runtime.check_loaded_runtime(ours(case), names=[name(case)], platform="linux", **kw)

    # The build id reader: the stand-ins' ids as their targets set them; none
    # for a library linked without one, a file that is not a 64-bit
    # little-endian ELF, a program header table past the end of the file, and
    # notes that are not a GNU build id; the build id after another note; an
    # unreadable file raises.
    got = _runtime.build_id(os.path.join(ours("b"), name("b")))
    assert got == bytes.fromhex("0b0b0b0b"), "the build id of b/ours is {!r}".format(got)
    got = _runtime.build_id(os.path.join(other("d"), name("d")))
    assert got is None, "d/other has the build id {!r}".format(got)
    assert _runtime.build_id(write(scratch, "text", b"not an ELF file at all, but long enough" * 4)) is None
    assert _runtime.build_id(write(scratch, "elf32", b"\x7fELF\x01\x01" + b"\0" * 58)) is None
    assert _runtime.build_id(write(scratch, "short", b"\x7fELF\x02\x01")) is None
    assert _runtime.build_id(write(scratch, "cut", elf_with_notes([], phnum=9))) is None
    no_id = [(b"GNU\0", 5, b"\x01\x02\x03\x04"), (b"Go\0\0", 3, b"go-build-id")]
    assert _runtime.build_id(write(scratch, "no_id", elf_with_notes(no_id))) is None
    with_id = no_id + [(b"GNU\0", 3, b"\xaa\xbb\xcc")]
    assert _runtime.build_id(write(scratch, "with_id", elf_with_notes(with_id))) == b"\xaa\xbb\xcc"
    try:
        _runtime.build_id(os.path.join(scratch, "absent"))
    except FileNotFoundError:
        pass
    else:
        raise AssertionError("an absent file has a build id")

    # Nothing loaded by that name: nothing to check, and NOLOAD opened nothing.
    assert _runtime.loaded_directory(name("none")) is None
    assert check("none") is None
    assert _runtime.loaded_directory(name("none")) is None

    # Not Linux: nothing is checked, even with a refusing runtime in place.
    assert _runtime.check_loaded_runtime(ours("c"), names=[name("c")], platform="darwin") is None

    # Komira's own copy is loaded: the same file, accepted.
    ctypes.CDLL(os.path.join(ours("a"), name("a")))
    assert os.path.realpath(_runtime.loaded_directory(name("a"))) == os.path.realpath(ours("a"))
    assert check("a") is None

    # Another copy of the same build (another file, the same build id), as
    # Modular's mojo-compiler of komira's version is: accepted.
    ctypes.CDLL(os.path.join(other("b"), name("b")))
    assert os.path.realpath(_runtime.loaded_directory(name("b"))) == os.path.realpath(other("b"))
    assert check("b") is None

    # Another build, and a copy without a build id: refused, naming the
    # library, where it is loaded from and komira's copy.
    for case in ("c", "d"):
        ctypes.CDLL(os.path.join(other(case), name(case)))
        there = _runtime.loaded_directory(name(case))
        assert os.path.realpath(there) == os.path.realpath(other(case)), there
        want = (
            "the Mojo runtime library {} is already loaded from {}, and it is another build than komira's "
            "({}): a process holds one Mojo runtime, so komira cannot be loaded beside Mojo code built "
            "with another Mojo version".format(name(case), there, os.path.join(ours(case), name(case)))
        )
        got = refused(lambda: check(case))
        assert got == want, got

    # Komira's copy is missing (a damaged install) while another is loaded:
    # refused, naming the missing file.
    ctypes.CDLL(os.path.join(other("e"), name("e")))
    absent = os.path.join(ours("e"), name("e"))
    got = refused(lambda: check("e"))
    assert got == "cannot read the Mojo runtime library {}: No such file or directory".format(absent), got

    # The loaded file cannot be read back (it was removed after it was
    # loaded): its build id is not known, so it is refused.
    gone = os.path.join(scratch, "gone")
    got = refused(lambda: check("b", find=lambda n: gone))
    assert got.startswith("the Mojo runtime library {} is already loaded from {}, ".format(name("b"), gone)), got

    external(lib_dir, scratch)
    dispatch(scratch)

    print(
        "runtime: the check accepts komira's copy and a copy of its build, and refuses every other; the "
        "external flavour loads Modular's runtime of the record's build and refuses every other"
    )


EXTERNAL = "this is the external flavour of komira, which loads the runtime from Modular's package"


def gnu_id(hex_id):
    """A stand-in ELF file whose GNU build id is `hex_id`, never opened."""
    return elf_with_notes([(b"GNU\0", 3, bytes.fromhex(hex_id))])


def record_text(requirement, rows):
    return "".join(["requirement\t{}\n".format(requirement)] + ["{}\t{}\n".format(n, i) for n, i in rows])


def external(lib_dir, scratch):
    """The external flavour: the record read and refused; the installed
    runtime found, held to the record and opened; one already loaded."""
    def site_lib(case):
        return os.path.join(lib_dir, case, "site", "modular", "lib")

    def make(directory, files):
        os.makedirs(directory, exist_ok=True)
        for base, data in files.items():
            write(directory, base, data)
        return directory

    # The record: the requirement, then each library's build id, in order.
    path = write(scratch, "good.tsv", record_text("mojo-compiler==1.0.0", [("libA.so", "0a0b"), ("libB.so", "ff")]).encode())
    got = _runtime.read_record(path)
    assert got == _runtime.Record("mojo-compiler==1.0.0", {"libA.so": b"\x0a\x0b", "libB.so": b"\xff"}), got
    assert list(got.build_ids) == ["libA.so", "libB.so"], got

    # An unreadable, non-text or malformed record is refused by its file.
    absent = os.path.join(scratch, "absent.tsv")
    got = refused(lambda: _runtime.read_record(absent))
    assert got == "cannot read komira's record of the Mojo runtime {}: No such file or directory".format(absent), got
    binary = write(scratch, "binary.tsv", b"requirement\t\xff\xfe\n")
    got = refused(lambda: _runtime.read_record(binary))
    assert got == "komira's record of the Mojo runtime {} is not UTF-8 text".format(binary), got
    for text, line_no, line in [
        ("name\tmojo-compiler==1.0.0\nlibA.so\t0a\n", 1, "name\tmojo-compiler==1.0.0"),
        ("requirement mojo-compiler==1.0.0\n", 1, "requirement mojo-compiler==1.0.0"),
        ("requirement\t\n", 1, "requirement\t"),
        ("requirement\tr==1\nlibA.so\tzz\n", 2, "libA.so\tzz"),
        ("requirement\tr==1\nlibA.so\t0a\t0b\n", 2, "libA.so\t0a\t0b"),
        ("requirement\tr==1\nlibA.so\t0a\nlibA.so\t0a\n", 3, "libA.so\t0a"),
        ("requirement\tr==1\n\tab\n", 2, "\tab"),
        ("requirement\tr==1\nrequirement\tr==2\n", 2, "requirement\tr==2"),
    ]:
        bad = write(scratch, "bad.tsv", text.encode())
        got = refused(lambda: _runtime.read_record(bad))
        want = "komira's record of the Mojo runtime {} is malformed: line {} is {!r}".format(bad, line_no, line)
        assert got == want, (got, want)
    for text in ["", "requirement\tr==1\n"]:
        bad = write(scratch, "short.tsv", text.encode())
        got = refused(lambda: _runtime.read_record(bad))
        assert got == "komira's record of the Mojo runtime {} names no requirement or no library".format(bad), got

    nothing_loaded = lambda n: None  # noqa: E731
    two = _runtime.Record("mojo-compiler==1.0.0", {"libA.so": b"\x0a", "libB.so": b"\x0b"})

    # Not installed: every directory searched, a relative entry and a repeat
    # skipped, and the libraries missing from the directory holding the most
    # of them named, with the install line.
    s1 = os.path.join(scratch, "s1")
    s2 = os.path.join(scratch, "s2")
    make(os.path.join(s2, "modular", "lib"), {"libB.so": gnu_id("0b")})
    search = ["", "relative/dir", s1, s1 + "/", s2, b"/bytes/entry"]
    got = refused(lambda: _runtime.load_installed_runtime(two, search_path=search, find=nothing_loaded))
    want = "the Mojo runtime komira loads is not installed: libA.so not found (searched {}, {}); {}: install it with: pip install mojo-compiler==1.0.0".format(
        os.path.join(s1, "modular", "lib"), os.path.join(s2, "modular", "lib"), EXTERNAL
    )
    assert got == want, got
    got = refused(lambda: _runtime.load_installed_runtime(two, search_path=[s1], find=nothing_loaded))
    want = "the Mojo runtime komira loads is not installed: libA.so, libB.so not found (searched {}); {}: install it with: pip install mojo-compiler==1.0.0".format(
        os.path.join(s1, "modular", "lib"), EXTERNAL
    )
    assert got == want, got
    got = refused(lambda: _runtime.load_installed_runtime(two, search_path=["rel"], find=nothing_loaded))
    want = "the Mojo runtime komira loads is not installed: libA.so, libB.so not found (searched no absolute directory); {}: install it with: pip install mojo-compiler==1.0.0".format(
        EXTERNAL
    )
    assert got == want, got

    # Found in the first directory holding all of them, and one of them is
    # another build, or has no build id: refused by name with the install
    # line, before anything is opened. A later directory of the right build
    # is not looked at.
    s3 = os.path.join(scratch, "s3")
    s4 = os.path.join(scratch, "s4")
    lib3 = make(os.path.join(s3, "modular", "lib"), {"libA.so": gnu_id("0a"), "libB.so": gnu_id("0c")})
    make(os.path.join(s4, "modular", "lib"), {"libA.so": gnu_id("0a"), "libB.so": gnu_id("0b")})
    cdll = ctypes.CDLL
    opened = []

    def recording_cdll(path, mode=0):
        opened.append((path, mode))

    ctypes.CDLL = recording_cdll
    try:
        got = refused(lambda: _runtime.load_installed_runtime(two, search_path=[s2, s3, s4], find=nothing_loaded))
        want = "the Mojo runtime library libB.so in {} is another build than the one komira was built with (mojo-compiler==1.0.0): {}: install it with: pip install mojo-compiler==1.0.0".format(
            lib3, EXTERNAL
        )
        assert got == want, got
        write(lib3, "libB.so", b"not ELF")
        got = refused(lambda: _runtime.load_installed_runtime(two, search_path=[s3], find=nothing_loaded))
        assert got == want, got
        assert opened == [], opened

        # The right build: each opened by path with RTLD_LOCAL, the library
        # the others need first; one already loaded (of the right build) is
        # not opened again.
        lib4 = os.path.join(s4, "modular", "lib")
        assert _runtime.load_installed_runtime(two, search_path=[s3 + "/missing", s4], find=nothing_loaded) is None
        want = [(os.path.join(lib4, "libB.so"), ctypes.RTLD_LOCAL), (os.path.join(lib4, "libA.so"), ctypes.RTLD_LOCAL)]
        assert opened == want, opened
        opened.clear()
        loaded_b = lambda n: lib4 if n == "libB.so" else None  # noqa: E731
        assert _runtime.load_installed_runtime(two, search_path=[s4], find=loaded_b) is None
        assert opened == [(os.path.join(lib4, "libA.so"), ctypes.RTLD_LOCAL)], opened
    finally:
        ctypes.CDLL = cdll

    # A file of the right build that the loader cannot open: refused with
    # the loader's reason.
    got = refused(lambda: _runtime.load_installed_runtime(two, search_path=[s4], find=nothing_loaded))
    prefix = "cannot load the Mojo runtime library {}: ".format(os.path.join(lib4, "libB.so"))
    assert got.startswith(prefix) and len(got) > len(prefix), got

    # The real stand-in, installed in a site directory: opened from there.
    f_record = _runtime.Record("mojo-compiler==1.0.0", {name("f"): bytes.fromhex("1f1f1f1f")})
    assert _runtime.loaded_directory(name("f")) is None
    assert _runtime.load_installed_runtime(f_record, search_path=[os.path.join(lib_dir, "f", "site")]) is None
    there = _runtime.loaded_directory(name("f"))
    assert os.path.realpath(there) == os.path.realpath(site_lib("f")), there

    # Already loaded, of the record's build: nothing is searched (the search
    # path is empty) and nothing more is opened.
    ctypes.CDLL(os.path.join(lib_dir, "g", "other", name("g")))
    g_record = _runtime.Record("mojo-compiler==1.0.0", {name("g"): bytes.fromhex("20202020")})
    assert _runtime.load_installed_runtime(g_record, search_path=[]) is None

    # Already loaded, of another build: refused, naming the library, where it
    # is loaded from and the build the record names.
    ctypes.CDLL(os.path.join(lib_dir, "h", "other", name("h")))
    h_record = _runtime.Record("mojo-compiler==1.0.0", {name("h"): bytes.fromhex("22222222")})
    there = _runtime.loaded_directory(name("h"))
    got = refused(lambda: _runtime.load_installed_runtime(h_record, search_path=[]))
    want = (
        "the Mojo runtime library {} is already loaded from {}, and it is another build than the one komira was "
        "built with (mojo-compiler==1.0.0): a process holds one Mojo runtime, so komira cannot be loaded beside "
        "Mojo code built with another Mojo version".format(name("h"), there)
    )
    assert got == want, got


def dispatch(scratch):
    """Which hook `prepare` runs: the check of the runtime inside the package
    when any of its libraries is in lib/, or when there is no record; the
    external load otherwise; nothing off Linux."""
    asked = []

    def find(n):
        asked.append(n)
        return None

    def package(case, runtime_inside, record):
        lib = os.path.join(scratch, "pkg_" + case)
        os.makedirs(os.path.join(lib, "lib"), exist_ok=True)
        if runtime_inside:
            write(os.path.join(lib, "lib"), _runtime.RUNTIME_LIBRARIES[1], gnu_id("01"))
        if record:
            # malformed, so reading it is a refusal that names it
            write(lib, _runtime.RECORD, b"not a record\n")
        return lib

    # The runtime inside and a record: the runtime inside wins; the check asks
    # for each runtime library by name, and the record is not read.
    lib = package("both", True, True)
    assert _runtime.prepare(lib, platform="linux", find=find) is None
    assert asked == list(_runtime.RUNTIME_LIBRARIES), asked
    # Neither: the check of the runtime inside, whose load names the file.
    asked.clear()
    lib = package("neither", False, False)
    assert _runtime.prepare(lib, platform="linux", find=find) is None
    assert asked == list(_runtime.RUNTIME_LIBRARIES), asked
    # A record and no runtime inside: the external load, which reads it.
    asked.clear()
    lib = package("external", False, True)
    got = refused(lambda: _runtime.prepare(lib, platform="linux", find=find))
    want = "komira's record of the Mojo runtime {} is malformed: line 1 is 'not a record'".format(os.path.join(lib, _runtime.RECORD))
    assert got == want, got
    assert asked == [], asked
    # Off Linux nothing is read or asked.
    assert _runtime.prepare(lib, platform="darwin", find=find) is None
    assert asked == [], asked


if __name__ == "__main__":
    main(sys.argv[1:])
