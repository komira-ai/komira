# Code objects for the native runtime's tests: a shared library staged under
# a code root as the host's code layer holds it (docs/design/udf_runtime_interface.md
# section 6.1, "The code layer": named by its hex sha256), and the code set
# a spec names it by. The digests are computed with komira_crypto (AWS-LC),
# not with the native runtime's own SHA-256, so a wrong hash there fails a
# load instead of agreeing with itself.

from std.ffi import external_call
from std.os import makedirs
from std.os.path import exists
from std.sys import CompilationTarget

from komira_crypto import sha256
from komira_udf_spike_abi.cases import Case
from komira_udf_spike_abi.runtime import CodeObject, CodeSet


def host_role() -> String:
    """The code role of a library built for this host: `lib:<os>-<cpu>`."""
    var os = "linux" if CompilationTarget.is_linux() else ("darwin" if CompilationTarget.is_macos() else "unknown")
    var cpu = "x86_64" if CompilationTarget.is_x86() else "aarch64"
    return "lib:" + os + "-" + cpu


def other_role() -> String:
    """A code role for a platform that is not this host's."""
    return "lib:linux-aarch64" if CompilationTarget.is_x86() else "lib:linux-x86_64"


def _hex_digit(v: Int) -> String:
    return chr(48 + v if v < 10 else 87 + v)


def hex_of(digest: List[UInt8]) -> String:
    """Lower-case hex, two digits per byte."""
    var out = String()
    for i in range(len(digest)):
        var b = Int(digest[i])
        out += _hex_digit(b >> 4) + _hex_digit(b & 15)
    return out^


def _read(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def _write(path: String, data: List[UInt8]) raises:
    with open(path, "w") as f:
        f.write_bytes(Span(data))


def bytes_of(path: String) raises -> List[UInt8]:
    """The bytes of the file at `path`."""
    return _read(path)


def sha256_of(data: List[UInt8]) -> List[UInt8]:
    """The sha256 of `data`, by komira_crypto."""
    var d = sha256(Span(data))
    var out = List[UInt8]()
    for i in range(32):
        out.append(d[i])
    return out^


def digest_of(path: String) raises -> List[UInt8]:
    """The sha256 of the file at `path`."""
    return sha256_of(_read(path))


def stage(path: String, root: String, role: String) raises -> CodeObject:
    """Copy the library at `path` into `root`, named by its hex sha256, and
    return it as a code object of `role`."""
    makedirs(root, exist_ok=True)
    var d = digest_of(path)
    _write(root + "/" + hex_of(d), _read(path))
    return CodeObject(role, d^)


def stage_under(path: String, root: String, role: String, digest: List[UInt8]) raises -> CodeObject:
    """Store the bytes of `path` under another digest's name: a code object
    whose bytes do not match its sha256."""
    makedirs(root, exist_ok=True)
    _write(root + "/" + hex_of(digest), _read(path))
    return CodeObject(role, digest.copy())


def stage_data(data: List[UInt8], root: String, role: String, digest: List[UInt8]) raises -> CodeObject:
    """Store `data` under `digest`'s name in `root`, whether or not it is
    the sha256 of `data`, and return it as a code object of `role`."""
    makedirs(root, exist_ok=True)
    _write(root + "/" + hex_of(digest), data)
    return CodeObject(role, digest.copy())


def code_set(path: String, root: String) raises -> CodeSet:
    """A code set of one library, `path`, for this host's platform."""
    return CodeSet(root, [stage(path, root, host_role())])


def staged_at(root: String, digest: List[UInt8]) -> Bool:
    return exists(root + "/" + hex_of(digest))


def loaded_objects() -> Int:
    """The objects the dynamic loader has mapped into this process
    (native/probe.c)."""
    return Int(external_call["komira_udf_spike_loaded_objects", Int64]())


def heap_in_use() -> Int:
    """The bytes of the C heap in use (native/probe.c, glibc's mallinfo2)."""
    return Int(external_call["komira_udf_spike_heap_in_use", Int64]())


def open_fds() -> Int:
    """The file descriptors open in this process (native/probe.c)."""
    return Int(external_call["komira_udf_spike_open_fds", Int64]())


def close_stdin() -> Bool:
    """Close descriptor 0, so the next one this process opens is 0
    (native/probe.c)."""
    return external_call["komira_udf_spike_close_stdin", Int64]() == 1


def stdin_open() -> Bool:
    """Descriptor 0 is open (native/probe.c)."""
    return external_call["komira_udf_spike_stdin_open", Int64]() == 1


def stdin_is_library_memfd() -> Bool:
    """Descriptor 0 names the native runtime's library memory file
    (native/probe.c)."""
    return external_call["komira_udf_spike_stdin_is_library_memfd", Int64]() == 1


def with_batch_twins(cases: List[Case]) -> List[Case]:
    """`cases`, then a copy of every case whose entry is double or
    fahrenheit, with the entry double_batch or fahrenheit_batch and the name
    suffixed `_batch`: the batch-loop fixtures (the same functions written
    as one loop per batch) held to the same expectations."""
    var out = List[Case]()
    for i in range(len(cases)):
        out.append(cases[i].copy())
    for i in range(len(cases)):
        if cases[i].spec.entry == "double" or cases[i].spec.entry == "fahrenheit":
            var c = cases[i].copy()
            c.spec.entry = c.spec.entry + "_batch"
            c.name = c.name + "_batch"
            out.append(c^)
    return out^
