"""The Mojo runtime libkomira binds to: the one inside the package, or
Modular's installed one.

The wheel comes in two flavours (docs/design/python_package.md, "The two
flavours"). `prepare` runs before libkomira is opened and does what the
flavour needs; `_native.load` calls it with the directory libkomira is in.

The bundled wheel carries the three Mojo runtime libraries in
`komira/_lib/lib/`, where libkomira's run path (`$ORIGIN/lib`; `@loader_path/lib` in the macOS wheel) finds them. The
dynamic loader matches a NEEDED name against every library already loaded in
the process, by file name or SONAME, before it reads any run path. So when
another Mojo runtime is already loaded (Modular's `mojo-compiler` or `max`, or
Mojo code of the user's own), libkomira binds to that one and komira's copy is
never opened. That is the same runtime when the other copy is one of the same
build, which the loader cannot tell; a copy of another Mojo version would be
used silently. `check_loaded_runtime` tells: for each runtime library already
loaded from another file than komira's own copy, it compares the GNU build id
(the ELF note the linker writes, the same for the copies of one build however
they were packaged) of that file with komira's copy's. A library with another
build id, or with none, is a `LibraryLoadError` naming the library and both
files; a library missing from komira's copy is a `LibraryLoadError` naming
that file. Nothing is opened.

The external wheel carries none of them. It requires Modular's
`mojo-compiler`, which installs them in `<site-packages>/modular/lib/`, and
carries in their place `mojo_runtime.tsv` beside libkomira: the record of the
requirement and of each library's build id as the compiler that built
libkomira ships it (python/flavour.bzl, `runtime_record`).
`load_installed_runtime` holds the runtime to the record: a library already
loaded must be that build; the others are found in `<dir>/modular/lib/` of the
first absolute directory `<dir>` of the search path (`sys.path` unless a test
passes its own; a relative entry, the empty string of `python -c` among them,
is skipped, so the working directory never supplies a library) that holds all
of them, each must be that build, and they are opened by path, with
`RTLD_LOCAL`, the libraries a library needs first, so libkomira's NEEDED names
then resolve to them. No directory holding all of them, a library of another
build, and one that cannot be opened are each a `LibraryLoadError` naming the
library, and the first two give the `pip install` line that provides the
right one.

The runtime inside the package is used when any of its libraries is in
`lib/`, or when there is no record: a damaged bundled install then fails
naming the file it lacks. Linux only, like the run-path layout and the build
ids: on another platform `prepare` does nothing.
"""

from __future__ import annotations

import ctypes
import os
import struct
import sys
from collections.abc import Callable, Sequence
from typing import NamedTuple

from ._errors import LibraryLoadError

# The Mojo runtime libraries, as libkomira's NEEDED entries and their own name
# them: libkomira needs the first, which needs the other two.
RUNTIME_LIBRARIES = ("libKGENCompilerRTShared.so", "libAsyncRTRuntimeGlobals.so", "libMSupportGlobals.so")

# The record the external wheel carries beside libkomira.
RECORD = "mojo_runtime.tsv"

# Where Modular's mojo-compiler installs the runtime, under a site directory.
_MODULAR_SUBDIR = os.path.join("modular", "lib")

# What a refusal of the external flavour says before its install line.
_EXTERNAL = "this is the external flavour of komira, which loads the runtime from Modular's package"

# dlinfo(3) request for the directory a loaded library came from.
_RTLD_DI_ORIGIN = 6

# The ELF note of a GNU build id: owner "GNU", type NT_GNU_BUILD_ID.
_PT_NOTE = 4
_NT_GNU_BUILD_ID = 3


def _align4(n: int) -> int:
    return (n + 3) & ~3


def build_id(path: str) -> bytes | None:
    """The GNU build id of the 64-bit little-endian ELF file at `path`, or None
    when it is not one or carries none. An unreadable file raises OSError."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:6] != b"\x7fELF\x02\x01" or len(data) < 64:
        return None
    phoff, = struct.unpack_from("<Q", data, 0x20)
    phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
    for i in range(phnum):
        at = phoff + i * phentsize
        if at + 56 > len(data):
            return None
        p_type, = struct.unpack_from("<I", data, at)
        if p_type != _PT_NOTE:
            continue
        offset, = struct.unpack_from("<Q", data, at + 8)
        size, = struct.unpack_from("<Q", data, at + 32)
        note, end = offset, min(offset + size, len(data))
        while note + 12 <= end:
            namesz, descsz, kind = struct.unpack_from("<III", data, note)
            name_at = note + 12
            desc_at = name_at + _align4(namesz)
            if kind == _NT_GNU_BUILD_ID and data[name_at : name_at + namesz] == b"GNU\0":
                return data[desc_at : desc_at + descsz]
            note = desc_at + _align4(descsz)
    return None


def loaded_directory(name: str) -> str | None:
    """The directory the library with file name or SONAME `name` was loaded
    from, or None when no library of that name is loaded. Opens nothing:
    `RTLD_NOLOAD` only finds a library already in the process."""
    try:
        lib = ctypes.CDLL(name, mode=os.RTLD_NOLOAD | os.RTLD_LOCAL)
    except OSError:
        return None
    buf = ctypes.create_string_buffer(4096)
    dlinfo = ctypes.CDLL(None).dlinfo
    dlinfo.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    dlinfo.restype = ctypes.c_int
    # On a handle dlopen just returned, RTLD_DI_ORIGIN only copies the
    # directory the loader recorded for it.
    dlinfo(lib._handle, _RTLD_DI_ORIGIN, buf)
    return os.fsdecode(buf.value)


def check_loaded_runtime(
    lib_dir: str,
    *,
    names: Sequence[str] = RUNTIME_LIBRARIES,
    platform: str | None = None,
    find: Callable[[str], str | None] = loaded_directory,
) -> None:
    """Refuses a Mojo runtime library already loaded in the process that is not
    komira's copy in `lib_dir` (`<package>/_lib/lib`) or a copy of the same
    build. `names` are the library names to check, `platform` is
    `sys.platform` when None (nothing is checked but on "linux"), and `find`
    gives the directory a name is loaded from; tests pass their own."""
    if (sys.platform if platform is None else platform) != "linux":
        return
    for name in names:
        theirs_dir = find(name)
        if theirs_dir is None:
            continue
        ours = os.path.join(lib_dir, name)
        theirs = os.path.join(theirs_dir, name)
        if os.path.realpath(theirs) == os.path.realpath(ours):
            continue
        try:
            want = build_id(ours)
        except OSError as e:
            raise LibraryLoadError("cannot read the Mojo runtime library {}: {}".format(ours, e.strerror)) from None
        try:
            got = build_id(theirs)
        except OSError:
            got = None
        if want is not None and got == want:
            continue
        raise LibraryLoadError(
            "the Mojo runtime library {} is already loaded from {}, and it is another build than komira's "
            "({}): a process holds one Mojo runtime, so komira cannot be loaded beside Mojo code built "
            "with another Mojo version".format(name, theirs_dir, ours)
        )


class Record(NamedTuple):
    """The external wheel's record of the runtime it loads: the requirement
    that installs it, and each library's build id, the library libkomira
    needs first and then the ones it needs."""

    requirement: str
    build_ids: dict[str, bytes]


def read_record(path: str) -> Record:
    """The record at `path`: a `requirement\t<requirement>` line, then one
    `<file name>\t<build id in hex>` line per library. An unreadable or
    malformed record is a `LibraryLoadError` naming the file."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        raise LibraryLoadError("cannot read komira's record of the Mojo runtime {}: {}".format(path, e.strerror)) from None
    except UnicodeDecodeError:
        raise LibraryLoadError("komira's record of the Mojo runtime {} is not UTF-8 text".format(path)) from None
    requirement = None
    build_ids: dict[str, bytes] = {}
    for n, line in enumerate(lines, 1):
        key, sep, value = line.partition("\t")
        bad = not sep or not key or not value or "\t" in value or key in build_ids
        if not bad and n == 1:
            bad = key != "requirement"
            requirement = value
        elif not bad:
            try:
                build_ids[key] = bytes.fromhex(value)
            except ValueError:
                bad = True
            bad = bad or not build_ids.get(key)
        if bad:
            raise LibraryLoadError("komira's record of the Mojo runtime {} is malformed: line {} is {!r}".format(path, n, line))
    if requirement is None or not build_ids:
        raise LibraryLoadError("komira's record of the Mojo runtime {} names no requirement or no library".format(path))
    return Record(requirement, build_ids)


def _candidates(search_path: Sequence[str | os.PathLike[str]]) -> list[str]:
    """`<dir>/modular/lib` for each absolute entry `<dir>` of `search_path`,
    in order, without repeats."""
    out: list[str] = []
    for entry in search_path:
        directory = os.fspath(entry)
        if not isinstance(directory, str) or not os.path.isabs(directory):
            continue
        libdir = os.path.join(os.path.normpath(directory), _MODULAR_SUBDIR)
        if libdir not in out:
            out.append(libdir)
    return out


def _find_installed(names: Sequence[str], candidates: Sequence[str], record: Record) -> str:
    """The first of `candidates` holding every one of `names`, or the
    LibraryLoadError naming those missing from the candidate that holds the
    most of them (the first such; all of them when none holds any)."""
    best = list(names)
    for libdir in candidates:
        missing = [n for n in names if not os.path.isfile(os.path.join(libdir, n))]
        if not missing:
            return libdir
        if len(missing) < len(best):
            best = missing
    raise LibraryLoadError(
        "the Mojo runtime komira loads is not installed: {} not found (searched {}); {}: install it with: pip install {}".format(
            ", ".join(best), ", ".join(candidates) or "no absolute directory", _EXTERNAL, record.requirement
        )
    )


def _build_id_or_none(path: str) -> bytes | None:
    try:
        return build_id(path)
    except OSError:
        return None


def load_installed_runtime(
    record: Record,
    *,
    search_path: Sequence[str | os.PathLike[str]] | None = None,
    find: Callable[[str], str | None] = loaded_directory,
) -> None:
    """Opens the runtime `record` describes from Modular's installed package,
    unless it is loaded already; refuses one of another build. `search_path`
    is the directories to look in, each for `modular/lib/`, `sys.path` when
    None; `find` gives the directory a name is loaded from. Tests pass their
    own."""
    names = list(record.build_ids)
    loaded = set()
    for name in names:
        theirs_dir = find(name)
        if theirs_dir is None:
            continue
        if _build_id_or_none(os.path.join(theirs_dir, name)) != record.build_ids[name]:
            raise LibraryLoadError(
                "the Mojo runtime library {} is already loaded from {}, and it is another build than the one komira "
                "was built with ({}): a process holds one Mojo runtime, so komira cannot be loaded beside Mojo code "
                "built with another Mojo version".format(name, theirs_dir, record.requirement)
            )
        loaded.add(name)
    if len(loaded) == len(names):
        return
    libdir = _find_installed(names, _candidates(sys.path if search_path is None else search_path), record)
    for name in names:
        if _build_id_or_none(os.path.join(libdir, name)) != record.build_ids[name]:
            raise LibraryLoadError(
                "the Mojo runtime library {} in {} is another build than the one komira was built with ({}): "
                "{}: install it with: pip install {}".format(name, libdir, record.requirement, _EXTERNAL, record.requirement)
            )
    for name in reversed(names):
        if name in loaded:
            continue
        path = os.path.join(libdir, name)
        try:
            ctypes.CDLL(path, mode=ctypes.RTLD_LOCAL)
        except OSError as e:
            raise LibraryLoadError("cannot load the Mojo runtime library {}: {}".format(path, e)) from None


def prepare(
    lib_dir: str,
    *,
    search_path: Sequence[str | os.PathLike[str]] | None = None,
    platform: str | None = None,
    find: Callable[[str], str | None] = loaded_directory,
) -> None:
    """Before libkomira at `<lib_dir>/libkomira.so` is opened: with the
    runtime inside the package (any of its libraries in `<lib_dir>/lib`, or
    no record at `<lib_dir>/mojo_runtime.tsv`), `check_loaded_runtime` of
    that copy; otherwise `load_installed_runtime` of the record. `platform`
    is `sys.platform` when None (nothing is done but on "linux"); the other
    arguments are handed on, and tests pass their own."""
    if (sys.platform if platform is None else platform) != "linux":
        return
    inside = os.path.join(lib_dir, "lib")
    record = os.path.join(lib_dir, RECORD)
    if any(os.path.isfile(os.path.join(inside, n)) for n in RUNTIME_LIBRARIES) or not os.path.isfile(record):
        check_loaded_runtime(inside, platform="linux", find=find)
        return
    load_installed_runtime(read_record(record), search_path=search_path, find=find)
