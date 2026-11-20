"""The ctypes loader of libkomira (src/so/README.md, the C surface).

`load` opens the library from a directory, once per process, checks that its
ABI major version is the one this package was written for, and binds the
functions the package calls; every failure is a `LibraryLoadError` that says
which library and why. `Native` holds the bound functions and turns their
status codes into `KomiraError`, with the context's last error, read with the
two-call protocol, as the message.

The library is found only where `load` is told: the directory a test passes
(`--lib-dir` of a `python_binding_test`), or, with no directory, the
package's own `_lib/`, where a wheel stages it. No environment variable and no
search of the working directory picks it (docs/design/python_package.md,
decision 6). The library is never closed: the Mojo runtime does not support
unloading, so a refused library stays mapped too, and ctypes never closes one.
"""

from __future__ import annotations

import ctypes
import os
import sys
import threading
from collections.abc import Callable

from ._errors import KomiraError, LibraryLoadError

# The ABI major version this package calls: komira_abi_version() is
# major * 1000 + minor, and a library of another major is refused.
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

# The functions `Native` binds beyond komira_abi_version, read first: name,
# result type, argument types (src/so/abi/komira.tsv).
_FUNCTIONS: dict[str, tuple[object, list[object]]] = {
    "komira_ctx_new": (ctypes.c_void_p, []),
    "komira_ctx_free": (None, [ctypes.c_void_p]),
    "komira_last_error": (ctypes.c_int32, [ctypes.c_void_p, _OutBuf, ctypes.c_uint64, _OutLen]),
    "komira_register_parquet": (ctypes.c_int32, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]),
}

_lock = threading.Lock()
_loaded: Native | None = None


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
    return value.encode("utf-8")


class Native:
    """The functions of one loaded libkomira. `path` is the file it was loaded
    from and `abi_version` its komira_abi_version(). A context is the integer
    address komira_ctx_new returned; the caller frees it with ctx_free."""

    path: str
    abi_version: int

    def __init__(self, path: str, abi_version: int, functions: dict[str, ctypes._CFuncPtr]) -> None:
        self.path = path
        self.abi_version = abi_version
        self._ctx_new = functions["komira_ctx_new"]
        self._ctx_free = functions["komira_ctx_free"]
        self._last_error = functions["komira_last_error"]
        self._register_parquet = functions["komira_register_parquet"]

    def ctx_new(self) -> int:
        ctx = self._ctx_new()
        if not ctx:
            raise KomiraError("komira_ctx_new returned NULL")
        return int(ctx)

    def ctx_free(self, ctx: int) -> None:
        self._ctx_free(ctx)

    def last_error(self, ctx: int) -> str:
        """The context's last error text, empty when there is none."""
        status, text = _two_call(
            "komira_last_error",
            lambda buf, cap, n: self._last_error(ctx, buf, cap, n),
        )
        if status != KOMIRA_OK:
            raise KomiraError("komira_last_error failed with status {}".format(status), status=status)
        # The library writes UTF-8; a byte that is not becomes U+FFFD rather
        # than an error raised while reporting another.
        return text.decode("utf-8", "replace")

    def register_parquet(self, ctx: int, name: str, path: str | os.PathLike[str]) -> None:
        """Registers the Parquet file at `path` in the context as the table `name`."""
        c_name = _c_string("name", name)
        c_path = _c_string("path", os.fspath(path))
        self._check("komira_register_parquet", ctx, self._register_parquet(ctx, c_name, c_path))

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


def _resolve(lib: ctypes.CDLL, path: str, name: str) -> ctypes._CFuncPtr:
    try:
        return getattr(lib, name)
    except AttributeError:
        raise LibraryLoadError("libkomira at {} has no symbol {}".format(path, name)) from None


def _bind(lib: ctypes.CDLL, path: str) -> Native:
    """The library's functions, after its ABI major version is checked: the
    version is read before any other symbol is looked up, so a library of
    another major is refused by its version, not by a symbol it lacks."""
    abi_version = _resolve(lib, path, "komira_abi_version")
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
    functions = {}
    for name, (restype, argtypes) in _FUNCTIONS.items():
        fn = _resolve(lib, path, name)
        fn.restype = restype
        fn.argtypes = argtypes
        functions[name] = fn
    return Native(path, version, functions)


def load(lib_dir: str | os.PathLike[str] | None = None) -> Native:
    """The process's libkomira, opened from `lib_dir` (the package's `_lib/`
    when it is None) on the first call that succeeds.

    A later call with the same file returns the same `Native`; with another
    file it is refused, since a process holds one library. A refused load
    leaves nothing loaded, so a later call may load another file.
    """
    global _loaded
    directory = _PACKAGE_LIB_DIR if lib_dir is None else os.fspath(lib_dir)
    path = os.path.abspath(os.path.join(directory, _LIB_NAME))
    with _lock:
        if _loaded is not None:
            if _loaded.path == path:
                return _loaded
            raise LibraryLoadError(
                "libkomira is already loaded from {}; it cannot also be loaded from {}".format(_loaded.path, path)
            )
        try:
            lib = ctypes.CDLL(path)
        except OSError as e:
            raise LibraryLoadError("cannot load libkomira from {}: {}".format(path, e)) from None
        _loaded = _bind(lib, path)
        return _loaded
