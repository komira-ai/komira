"""The ctypes loader of libkomira (src/so/README.md, the C surface).

`load` opens the library from a directory, once per process, checks that its
ABI major version is the one this package was written for, and binds the
calls of ABI 1.1; every failure is a `LibraryLoadError` that says which
library and why. `Native` holds the bound calls and turns their status codes
into `KomiraError`, with the context's last error, read with the two-call
protocol, as the message.

Before the library is opened, `load` calls two hooks: `_check_cpu()` here and
`_runtime.check_loaded_runtime(<directory>/lib)` (Linux only; it does nothing
on macOS); an error either raises stops the load before the library is mapped.
`_check_cpu` refuses, on Linux x86_64, a CPU without the flags of x86-64-v3,
the level libkomira is compiled for there, with `UnsupportedCpuError`: an older
CPU would otherwise die of an illegal instruction inside the library. The
runtime check refuses a Mojo runtime already in the process that is another
build than the one in `lib/` beside the library.

The library is found only where `load` is told: the directory a test passes
(`--lib-dir` of a `python_binding_test`), or, with no directory, the
package's own `_lib/`, where a wheel stages it (`libkomira.so`, or
`libkomira.dylib` on macOS) with its native owners (Linux only) and the Mojo
runtime in `_lib/lib/`. The library's own run path (`$ORIGIN/lib` on Linux,
`@loader_path/lib` on macOS) finds those. No environment variable and no
search of the working directory picks it (docs/design/python_package.md,
decision 6).
It is opened with `RTLD_LOCAL`, so neither it nor the runtime it brings joins
the process's global symbol scope, where it would take the place of another
Mojo library's own definitions. The library is never closed: the Mojo runtime
does not support unloading, so a refused library stays mapped too, and ctypes
never closes one.

The calls that return protobuf bytes or plan text (`parquet_schema`,
`csv_binding`, `json_binding`, `plan_render`) are private: they have no
Python type yet and no stability promise.
"""

from __future__ import annotations

import ctypes
import os
import platform
import sys
import threading
from collections.abc import Callable

from . import _runtime
from ._errors import KomiraError, LibraryLoadError, UnsupportedCpuError

# The ABI major version this package calls: komira_abi_version() is
# major * 1000 + minor, and a library of another major is refused. Any minor
# is accepted.
ABI_MAJOR = 1

# The two status codes the loader itself tells apart; every other one is a
# failure the caller reports.
KOMIRA_OK = 0
KOMIRA_ERR_BUFFER_TOO_SMALL = -4

_LIB_NAME = "libkomira.dylib" if sys.platform == "darwin" else "libkomira.so"

# The directory an installed package loads the library from.
_PACKAGE_LIB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_lib")

_OutBuf = ctypes.POINTER(ctypes.c_uint8)
_OutLen = ctypes.POINTER(ctypes.c_uint64)
_Out = [_OutBuf, ctypes.c_uint64, _OutLen]

# The calls `Native` binds beyond komira_abi_version, which is read first:
# name -> (the minor version of ABI 1 that added it, result type, argument
# types), from src/so/abi/komira.tsv. A call the library's minor includes must
# be there; a later one may be missing, and calling it then raises.
_FUNCTIONS: dict[str, tuple[int, object, list[object]]] = {
    "komira_ctx_new": (0, ctypes.c_void_p, []),
    "komira_ctx_free": (0, None, [ctypes.c_void_p]),
    "komira_last_error": (0, ctypes.c_int32, [ctypes.c_void_p] + _Out),
    "komira_register_parquet": (1, ctypes.c_int32, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]),
    "komira_parquet_schema": (1, ctypes.c_int32, [ctypes.c_void_p, ctypes.c_char_p] + _Out),
    "komira_csv_binding": (
        1,
        ctypes.c_int32,
        [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint8, ctypes.c_int32, ctypes.c_int32] + _Out,
    ),
    "komira_json_binding": (1, ctypes.c_int32, [ctypes.c_void_p, ctypes.c_char_p] + _Out),
    "komira_plan_render": (1, ctypes.c_int32, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint64] + _Out),
}

_lock = threading.Lock()
_loaded: Native | None = None


# The CPU flags of x86-64-v3, the level linux-x86_64 libkomira is compiled
# for (`target_cpu` in tools/build/platforms/table.bzl), spelled as the
# `flags` line of Linux's /proc/cpuinfo spells them: x86-64-v2's SSE3 (`pni`),
# SSSE3, CMPXCHG16B (`cx16`), SSE4.1, SSE4.2, POPCNT and LAHF/SAHF
# (`lahf_lm`), then x86-64-v3's own AVX, AVX2, BMI1, BMI2, F16C, FMA, LZCNT
# (`abm`) and MOVBE. The kernel lists avx, avx2, f16c and fma only when it
# also saves the AVX registers, so the line answers what the OS supports too.
# A refusal names the missing flags in this order.
_X86_64_V3_FLAGS = (
    "pni",
    "ssse3",
    "cx16",
    "sse4_1",
    "sse4_2",
    "popcnt",
    "lahf_lm",
    "avx",
    "avx2",
    "bmi1",
    "bmi2",
    "f16c",
    "fma",
    "abm",
    "movbe",
)

# Where `_check_cpu` reads the flags unless it is given a file.
_CPUINFO = "/proc/cpuinfo"


def _cpu_flags(text: str) -> set[str]:
    """The flags every processor of /proc/cpuinfo text lists on its `flags`
    line: a thread may run on any of them. Other lines, `vmx flags` among
    them, are not read. No `flags` line is no flags."""
    common: set[str] | None = None
    for line in text.splitlines():
        key, sep, value = line.partition(":")
        if not sep or key.strip() != "flags":
            continue
        flags = set(value.split())
        common = flags if common is None else common & flags
    return set() if common is None else common


def _check_cpu(
    cpuinfo: str | os.PathLike[str] | None = None, *, system: str | None = None, machine: str | None = None
) -> None:
    """Refuses, before the library is opened, a CPU the library was not built
    for.

    On Linux x86_64 it reads the CPU flags from `cpuinfo` (/proc/cpuinfo when
    None; tests pass a file) and raises `UnsupportedCpuError` naming the flags
    of x86-64-v3 the CPU lacks, or `LibraryLoadError` when the file cannot be
    read. `system` and `machine` are `sys.platform` and `platform.machine()`
    when None; on any other platform (aarch64 Linux, macOS) nothing is read
    and nothing is refused.
    """
    system = sys.platform if system is None else system
    machine = platform.machine() if machine is None else machine
    if system != "linux" or machine != "x86_64":
        return
    path = _CPUINFO if cpuinfo is None else os.fspath(cpuinfo)
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as e:
        raise LibraryLoadError(
            "cannot read the CPU flags from {}, so it is not known whether this CPU implements x86-64-v3, "
            "which libkomira for Linux x86_64 needs: {}".format(path, e)
        ) from None
    flags = _cpu_flags(text)
    missing = [f for f in _X86_64_V3_FLAGS if f not in flags]
    if missing:
        raise UnsupportedCpuError(
            "libkomira for Linux x86_64 needs an x86-64-v3 CPU (Haswell or newer); "
            "this CPU lacks {} (the flags {} lists)".format(", ".join(missing), path)
        )


def _two_call(op: str, call: Callable[[object, int, object], int]) -> tuple[int, bytes]:
    """The bytes of a call that follows the two-call protocol, and its status.

    `call(out_buf, out_cap, out_len)` makes the C call. The first call has no
    buffer and capacity 0: success means the answer is empty, and
    KOMIRA_ERR_BUFFER_TOO_SMALL gives its length. The second call gets a buffer
    of exactly that length. Any other status of either call is returned with no
    bytes, for the caller to report. A second call that reports another length
    is a KomiraError: its bytes are not the answer the first call measured.
    """
    need = ctypes.c_uint64(0)
    status = call(None, 0, ctypes.byref(need))
    if status != KOMIRA_ERR_BUFFER_TOO_SMALL:
        return status, b""
    n = need.value
    buf = (ctypes.c_uint8 * n)()
    got = ctypes.c_uint64(0)
    status = call(buf, n, ctypes.byref(got))
    if status == KOMIRA_OK and got.value == n:
        return status, bytes(buf)
    if status in (KOMIRA_OK, KOMIRA_ERR_BUFFER_TOO_SMALL):
        raise KomiraError("{} changed its length between the two calls: {} bytes, then {}".format(op, n, got.value))
    return status, b""


def _c_string(what: str, value: object) -> bytes:
    """`value` as the NUL-terminated UTF-8 a `const char *` argument takes."""
    if not isinstance(value, str):
        raise TypeError("{} must be a str, not {}".format(what, type(value).__name__))
    if "\0" in value:
        raise ValueError("{} holds a NUL byte".format(what))
    try:
        return value.encode("utf-8")
    except UnicodeEncodeError:
        raise ValueError("{} is not valid UTF-8".format(what)) from None


def _c_path(value: object) -> bytes:
    """A path argument: a `str` or a `str` `os.PathLike`, as UTF-8."""
    if isinstance(value, os.PathLike):
        value = os.fspath(value)
    return _c_string("path", value)


def _flag(what: str, value: object) -> int:
    if not isinstance(value, bool):
        raise TypeError("{} must be a bool, not {}".format(what, type(value).__name__))
    return int(value)


class Native:
    """The calls of one loaded libkomira. `path` is the file it was loaded
    from and `abi_version` its komira_abi_version(). A context is the integer
    address komira_ctx_new returned; the caller frees it with ctx_free."""

    path: str
    abi_version: int

    def __init__(self, path: str, abi_version: int, functions: dict[str, ctypes._CFuncPtr | None]) -> None:
        self.path = path
        self.abi_version = abi_version
        self._functions = functions

    def _fn(self, name: str) -> ctypes._CFuncPtr:
        """The bound call `name`, or a KomiraError when this library's minor
        version is older than the call's."""
        fn = self._functions[name]
        if fn is None:
            raise KomiraError(
                "{} needs libkomira ABI version {}.{}; the library at {} is {}.{}".format(
                    name, ABI_MAJOR, _FUNCTIONS[name][0], self.path, *divmod(self.abi_version, 1000)
                )
            )
        return fn

    def ctx_new(self) -> int:
        ctx = self._fn("komira_ctx_new")()
        if not ctx:
            raise KomiraError("komira_ctx_new returned NULL")
        return int(ctx)

    def ctx_free(self, ctx: int) -> None:
        self._fn("komira_ctx_free")(ctx)

    def last_error(self, ctx: int) -> str:
        """The context's last error text, empty when there is none."""
        fn = self._fn("komira_last_error")
        status, text = _two_call("komira_last_error", lambda buf, cap, n: fn(ctx, buf, cap, n))
        if status != KOMIRA_OK:
            raise KomiraError("komira_last_error failed with status {}".format(status), status=status)
        # The library writes UTF-8; a byte that is not becomes U+FFFD rather
        # than an error raised while reporting another.
        return text.decode("utf-8", "replace")

    def register_parquet(self, ctx: int, name: str, path: str | os.PathLike[str]) -> None:
        """Registers the Parquet file at `path` in the context as the table `name`."""
        op = "komira_register_parquet"
        fn = self._fn(op)
        self._check(op, ctx, fn(ctx, _c_string("name", name), _c_path(path)))

    def parquet_schema(self, ctx: int, path: str | os.PathLike[str]) -> bytes:
        """The `WireSchema` bytes of the Parquet file at `path`."""
        c_path = _c_path(path)
        return self._out("komira_parquet_schema", ctx, lambda fn, b, c, n: fn(ctx, c_path, b, c, n))

    def csv_binding(
        self, ctx: int, path: str | os.PathLike[str], *, delimiter: str, has_header: bool, all_varchar: bool
    ) -> bytes:
        """The `WireScanBinding` bytes of the CSV file at `path`."""
        c_path = _c_path(path)
        if not isinstance(delimiter, str):
            raise TypeError("delimiter must be a str, not {}".format(type(delimiter).__name__))
        if len(delimiter) != 1 or ord(delimiter) > 127:
            raise ValueError("delimiter must be one ASCII character, not {!r}".format(delimiter))
        d, h, a = ord(delimiter), _flag("has_header", has_header), _flag("all_varchar", all_varchar)
        return self._out("komira_csv_binding", ctx, lambda fn, b, c, n: fn(ctx, c_path, d, h, a, b, c, n))

    def json_binding(self, ctx: int, path: str | os.PathLike[str]) -> bytes:
        """The `WireScanBinding` bytes of the newline-delimited JSON file at `path`."""
        c_path = _c_path(path)
        return self._out("komira_json_binding", ctx, lambda fn, b, c, n: fn(ctx, c_path, b, c, n))

    def plan_render(self, ctx: int, plan: bytes) -> str:
        """The text of the serialized plan `plan` (which may hold NUL bytes)."""
        if not isinstance(plan, (bytes, bytearray, memoryview)):
            raise TypeError("plan must be bytes, not {}".format(type(plan).__name__))
        data = bytes(plan)
        out = self._out("komira_plan_render", ctx, lambda fn, b, c, n: fn(ctx, data, len(data), b, c, n))
        return out.decode("utf-8", "replace")

    def _out(self, op: str, ctx: int, call: Callable[[ctypes._CFuncPtr, object, int, object], int]) -> bytes:
        """The bytes of the two-call `op`, or its KomiraError."""
        fn = self._fn(op)
        status, data = _two_call(op, lambda b, c, n: call(fn, b, c, n))
        self._check(op, ctx, status)
        return data

    def _check(self, op: str, ctx: int, status: int) -> None:
        """Raises the KomiraError of a call `op` on `ctx` that returned `status`,
        unless it is KOMIRA_OK. The message is the context's last error."""
        if status == KOMIRA_OK:
            return
        try:
            text = self.last_error(ctx)
        except KomiraError as e:
            raise KomiraError(
                "{} failed with status {}; its last error could not be read: {}".format(op, status, e),
                status=status,
            ) from e
        if not text:
            raise KomiraError("{} failed with status {} and no message".format(op, status), status=status)
        raise KomiraError(text, status=status)


def _resolve(lib: ctypes.CDLL, name: str) -> ctypes._CFuncPtr | None:
    try:
        return getattr(lib, name)
    except AttributeError:
        return None


def _bind(lib: ctypes.CDLL, path: str) -> Native:
    """The library's calls, after its ABI major version is checked: the
    version is read before any other symbol is looked up, so a library of
    another major is refused by its version, not by a symbol it lacks."""
    abi_version = _resolve(lib, "komira_abi_version")
    if abi_version is None:
        raise LibraryLoadError("libkomira at {} has no symbol komira_abi_version".format(path))
    abi_version.restype = ctypes.c_int32
    abi_version.argtypes = []
    version = abi_version()
    if version < 0:
        raise LibraryLoadError(
            "libkomira at {} reports ABI version {}, which is not major * 1000 + minor".format(path, version)
        )
    major, minor = divmod(version, 1000)
    if major != ABI_MAJOR:
        raise LibraryLoadError(
            "libkomira at {} has ABI version {}.{}; this package needs major {}".format(path, major, minor, ABI_MAJOR)
        )
    functions: dict[str, ctypes._CFuncPtr | None] = {}
    for name, (added, restype, argtypes) in _FUNCTIONS.items():
        fn = _resolve(lib, name)
        if fn is None and added <= minor:
            raise LibraryLoadError(
                "libkomira at {} has ABI version {}.{} and no symbol {}".format(path, major, minor, name)
            )
        if fn is not None:
            fn.restype = restype
            fn.argtypes = argtypes
        functions[name] = fn
    return Native(path, version, functions)


def load(lib_dir: str | os.PathLike[str] | None = None) -> Native:
    """The process's libkomira.

    With `lib_dir`, the library is `<lib_dir>/libkomira.so` (`libkomira.dylib`
    on macOS); with None, it is the one already loaded, or else the package's
    `_lib/` copy. The first load that succeeds is kept: a later call naming
    the same file returns the same `Native`, and one naming another file is
    refused, since a process holds one library. A refused load leaves nothing
    loaded. A file
    missing from the directory is a `LibraryLoadError` that names it.
    """
    global _loaded
    with _lock:
        if lib_dir is None and _loaded is not None:
            return _loaded
        directory = _PACKAGE_LIB_DIR if lib_dir is None else os.fspath(lib_dir)
        path = os.path.abspath(os.path.join(directory, _LIB_NAME))
        if _loaded is not None:
            if _loaded.path == path:
                return _loaded
            raise LibraryLoadError(
                "libkomira is already loaded from {}; it cannot also be loaded from {}".format(_loaded.path, path)
            )
        _check_cpu()
        _runtime.check_loaded_runtime(os.path.join(os.path.dirname(path), "lib"))
        try:
            lib = ctypes.CDLL(path, mode=ctypes.RTLD_LOCAL)
        except OSError as e:
            raise LibraryLoadError("cannot load libkomira from {}: {}".format(path, e)) from None
        _loaded = _bind(lib, path)
        return _loaded
