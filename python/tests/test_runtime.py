"""The check of a Mojo runtime already in the process (komira/_runtime.py), on
stand-in libraries, and the GNU build id reader it compares files with. The
cases are: no runtime loaded by the name, komira's own copy loaded, another
copy of the same build id (accepted), another build id and a copy with no
build id (refused, naming the library, where it is loaded from and komira's
copy), komira's copy missing while another is loaded (refused, naming the
missing file), a loaded copy that cannot be read back, and nothing checked off
Linux; then the build id reader, on the stand-ins and on hand-written ELF
headers.

    test_runtime.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/<case>/ours/` and `<dir>/<case>/other/` hold stand-ins of
fake_runtime_lib.c (tests/BUCK) with the SONAME `libfake_rt_<case>.so` and the
build id of their target: `ours` plays komira's `_lib/lib`, `other` a runtime
loaded by someone else. Each case has its own SONAME, since a library is never
unloaded: a case loads its copy by path with ctypes, then runs the check.
`--runtime-dir`, which the rule passes, is not read.
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

    print("runtime: the check accepts komira's copy and a copy of its build, and refuses every other")


if __name__ == "__main__":
    main(sys.argv[1:])
