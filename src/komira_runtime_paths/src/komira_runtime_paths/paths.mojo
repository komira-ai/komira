from std.ffi import external_call
from std.os import getenv
from std.sys.info import CompilationTarget

comptime _PATH_CAP: Int = 4096


def _zeroed(n: Int) -> List[UInt8]:
    var buf = List[UInt8]()
    for _ in range(n):
        buf.append(UInt8(0))
    return buf^


def _decode(buf: List[UInt8]) -> String:
    """The bytes of `buf` before its first NUL."""
    var out = String("")
    var i = 0
    while i < len(buf) and buf[i] != UInt8(0):
        out += chr(Int(buf[i]))
        i += 1
    return out^


def executable_path() raises -> String:
    """The absolute, symlink-free path of the running executable.

    Linux reads /proc/self/exe, which the kernel keeps resolved. macOS asks
    dyld (_NSGetExecutablePath) and resolves the answer with realpath(3).
    Raises if neither gives a path.
    """
    var buf = _zeroed(_PATH_CAP)
    comptime if CompilationTarget.is_macos():
        var size = List[UInt32]()
        size.append(UInt32(_PATH_CAP - 1))
        # SAFETY: `buf` and `size` are locals that outlive the call; dyld
        # writes at most `*size` bytes, NUL included, and neither pointer is
        # kept after the call.
        var rc = external_call["_NSGetExecutablePath", Int32](
            buf.unsafe_ptr(), size.unsafe_ptr()
        )
        if rc != 0:
            raise Error("executable_path: _NSGetExecutablePath failed")
        var resolved = _zeroed(_PATH_CAP)
        # SAFETY: `buf` is NUL-terminated (zero-filled, one byte spare) and
        # `resolved` holds PATH_MAX (1024 on macOS) bytes; realpath writes
        # into `resolved` only and returns it or NULL.
        var r = external_call["realpath", Int](
            buf.unsafe_ptr(), resolved.unsafe_ptr()
        )
        if r == 0:
            raise Error("executable_path: realpath failed on " + _decode(buf))
        return _decode(resolved)
    else:
        var link = String("/proc/self/exe")
        # SAFETY: `link` and `buf` are locals that outlive the call; readlink
        # writes at most `_PATH_CAP - 1` bytes into the zero-filled `buf`, so
        # the byte after them is a NUL.
        var n = external_call["readlink", Int](
            link.as_c_string_slice().unsafe_ptr(),
            buf.unsafe_ptr(),
            UInt(_PATH_CAP - 1),
        )
        if n <= 0:
            raise Error("executable_path: readlink(/proc/self/exe) failed")
        return _decode(buf)


def _parent(p: String) -> String:
    var i = p.rfind("/")
    if i <= 0:
        return String("/")
    return String(p[byte=:i])


def install_root() raises -> String:
    """`<root>`: the parent of the directory holding the executable."""
    return _parent(_parent(executable_path()))


def share_dir() raises -> String:
    """`<root>/share`, where a bundle's `data` and a test's declared data sit."""
    return install_root() + "/share"


def _check_relative(rel: String) raises:
    if rel == "" or rel.startswith("/"):
        raise Error("data path must be relative to share/: '" + rel + "'")
    for part in rel.split("/"):
        if part == "" or part == "." or part == "..":
            raise Error(
                "data path must not hold an empty, '.' or '..' segment: '"
                + rel
                + "'"
            )


def data_path(rel: String) raises -> String:
    """The absolute path of declared data file `rel` (a path under share/).

    `rel` is the destination the BUCK file gave the file: its key in a `data`
    dict, or its path from the cell root in a `data` list. The file is not
    opened; a path that was not declared names nothing.
    """
    _check_relative(rel)
    return share_dir() + "/" + rel


def read_data(rel: String) raises -> String:
    """The contents of declared data file `rel`. Raises if it is absent."""
    with open(data_path(rel), "r") as f:
        return f.read()


def test_tmpdir() raises -> String:
    """$TEST_TMPDIR: an empty directory private to this run.

    Raises when it is unset or empty rather than falling back to /tmp, which
    other runs on the same machine share.
    """
    var d = getenv("TEST_TMPDIR", "")
    if d == "":
        raise Error("test_tmpdir: TEST_TMPDIR is unset; run under a test runner")
    return d^
