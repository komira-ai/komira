"""The Mojo runtime libkomira binds to, when another one is already loaded.

The wheel carries the three Mojo runtime libraries in `komira/_lib/lib/`, where
libkomira's run path (`$ORIGIN/lib`; `@loader_path/lib` in the macOS wheel) finds them (docs/design/python_package.md,
decision 6). The dynamic loader matches a NEEDED name against every library
already loaded in the process, by file name or SONAME, before it reads any run
path. So when another Mojo runtime is already loaded (Modular's `mojo-compiler`
or `max`, or Mojo code of the user's own), libkomira binds to that one and
komira's copy is never opened.

That is the same runtime when the other copy is one of the same build, which
the loader cannot tell; a copy of another Mojo version would be used silently.
`check_loaded_runtime` tells: before libkomira is opened, for each runtime
library already loaded from another file than komira's own copy, it compares
the GNU build id (the ELF note the linker writes, the same for the copies of
one build however they were packaged) of that file with komira's copy's. A
library with another build id, or with none, is a `LibraryLoadError` naming
the library and both files; a library missing from komira's copy is a
`LibraryLoadError` naming that file. Nothing is opened.

Linux only, because it reads ELF build ids and asks glibc's dlinfo where a
library came from: on another platform (macOS among them) it does nothing.
"""

from __future__ import annotations

import ctypes
import os
import struct
import sys
from collections.abc import Callable, Sequence

from ._errors import LibraryLoadError

# The Mojo runtime libraries, as libkomira's NEEDED entries and their own name
# them: libkomira needs the first, which needs the other two.
RUNTIME_LIBRARIES = ("libKGENCompilerRTShared.so", "libAsyncRTRuntimeGlobals.so", "libMSupportGlobals.so")

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
