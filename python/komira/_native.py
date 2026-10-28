"""Loading and calling libkomira, the shared library's flat C ABI.

This is the only module of the package that knows ctypes exists; everything
above it works in Python values. It is pyarrow-free. The library's contract
is `src/komira_so/README.md` and the header of `src/komira_so/_c_abi.mojo`.

    native = load("/path/to/libkomira.so")     # or load(): next to the package
    ctx = native.ctx_new()
    ...
    native.ctx_free(ctx)

The path is explicit or the default beside this package; no environment
variable is read.
"""

from __future__ import annotations

import ctypes
import os
import sys
from typing import Callable, Optional

__all__ = [
    "ABI_MAJOR",
    "ABI_MIN_MINOR",
    "KomiraError",
    "Native",
    "STATUS_NAMES",
    "KOMIRA_OK",
    "KOMIRA_ERR_NULL_CTX",
    "KOMIRA_ERR_NULL_ARG",
    "KOMIRA_ERR_ENGINE",
    "KOMIRA_ERR_BUFFER_TOO_SMALL",
    "KOMIRA_ERR_TOO_LARGE",
    "default_library_path",
    "load",
    "read_two_call",
]

# The ABI this binding was written against (`komira_abi_version()` is
# `major * 1000 + minor`). A different major is a different ABI and is refused;
# a library whose minor is below ABI_MIN_MINOR lacks a symbol this binding
# binds (1.1 is the first version with all nine exports) and is refused.
# A newer minor only adds symbols and is accepted.
ABI_MAJOR = 1
ABI_MIN_MINOR = 1

KOMIRA_OK = 0
KOMIRA_ERR_NULL_CTX = -1
KOMIRA_ERR_NULL_ARG = -2
KOMIRA_ERR_ENGINE = -3
KOMIRA_ERR_BUFFER_TOO_SMALL = -4
KOMIRA_ERR_TOO_LARGE = -5

STATUS_NAMES = {
    KOMIRA_OK: "KOMIRA_OK",
    KOMIRA_ERR_NULL_CTX: "KOMIRA_ERR_NULL_CTX",
    KOMIRA_ERR_NULL_ARG: "KOMIRA_ERR_NULL_ARG",
    KOMIRA_ERR_ENGINE: "KOMIRA_ERR_ENGINE",
    KOMIRA_ERR_BUFFER_TOO_SMALL: "KOMIRA_ERR_BUFFER_TOO_SMALL",
    KOMIRA_ERR_TOO_LARGE: "KOMIRA_ERR_TOO_LARGE",
}

# How many times the second call of the two-call protocol is repeated when the
# text grew between the calls (a probe says 10 bytes, the answer is now 12).
_MAX_GROWTH_RETRIES = 4


class KomiraError(RuntimeError):
    """An error of the library or of this binding.

    `status` is the `KOMIRA_ERR_*` code the C call returned, or None when no
    C call failed (the library did not load, the ABI was refused, a guard of
    this binding refused first). `last_error` is the context's last-error text
    ("" when there is none or it could not be read). `str(exc)` holds both.
    """

    status: Optional[int]
    last_error: str

    def __init__(self, message: str, status: Optional[int] = None, last_error: str = ""):
        super().__init__(message)
        self.status = status
        self.last_error = last_error


def default_library_path() -> str:
    """`libkomira.so` (`libkomira.dylib` on macOS) beside this package."""
    suffix = ".dylib" if sys.platform == "darwin" else ".so"
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "libkomira" + suffix)


def read_two_call(call: Callable[[object, int, "ctypes._Pointer"], int]):
    """The two-call output protocol.

    `call(buf, cap, out_len_ref)` makes one C call with the given buffer
    (None for the probe), capacity and `byref(c_uint64)`, and returns the
    status. Returns `(status, bytes)`: the bytes only when the status is OK.
    The probe passes capacity 0 and a NULL buffer to learn the length; the
    answer is then read with a buffer of exactly that size. A too-small buffer
    is never written by the library, so a result is never truncated; if the
    length grew between the calls the read is repeated with the new length, at
    most four times.
    """
    n = ctypes.c_uint64(0)
    status = call(None, 0, ctypes.byref(n))
    if status == KOMIRA_OK and n.value == 0:
        return KOMIRA_OK, b""
    for _ in range(_MAX_GROWTH_RETRIES):
        if status not in (KOMIRA_OK, KOMIRA_ERR_BUFFER_TOO_SMALL):
            return status, b""
        cap = n.value
        buf = ctypes.create_string_buffer(cap)
        status = call(buf, cap, ctypes.byref(n))
        if status == KOMIRA_OK:
            return KOMIRA_OK, buf.raw[: n.value]
    return status, b""


def _utf8(text, what: str) -> bytes:
    """A path or name as the NUL-terminated UTF-8 the C side takes."""
    try:
        raw = os.fspath(text)
    except TypeError:
        raw = text
    if isinstance(raw, bytes):
        data = raw
    elif isinstance(raw, str):
        try:
            data = raw.encode("utf-8")
        except UnicodeEncodeError as e:
            raise KomiraError("%s is not valid UTF-8: %s" % (what, e)) from None
    else:
        raise KomiraError("%s must be str, bytes or a path, not %s" % (what, type(raw).__name__))
    if b"\0" in data:
        raise KomiraError("%s holds a NUL byte" % what)
    return data


class Native:
    """The nine exports of one loaded library, typed, behind the ABI check.

    `lib` is a `ctypes.CDLL` (or anything with `komira_abi_version`). The check
    runs before any other symbol is looked up, so a library of another ABI is
    refused by name and not by a missing symbol.
    """

    def __init__(self, lib):
        self.lib = lib
        self.abi_version = self._check_abi(lib)
        self._bind(lib)

    @staticmethod
    def _check_abi(lib) -> int:
        try:
            fn = lib.komira_abi_version
        except AttributeError:
            raise KomiraError("the library has no komira_abi_version: it is not libkomira") from None
        fn.restype = ctypes.c_int32
        fn.argtypes = []
        version = int(fn())
        major, minor = divmod(version, 1000)
        if major != ABI_MAJOR:
            raise KomiraError(
                "libkomira reports ABI %d.%d; this binding needs major %d (ABI %d.%d or a later 1.x)"
                % (major, minor, ABI_MAJOR, ABI_MAJOR, ABI_MIN_MINOR)
            )
        if minor < ABI_MIN_MINOR:
            raise KomiraError(
                "libkomira reports ABI %d.%d; this binding needs %d.%d or later (an export it binds is missing)"
                % (major, minor, ABI_MAJOR, ABI_MIN_MINOR)
            )
        return version

    def _bind(self, lib) -> None:
        # Types follow src/komira_so/_c_abi.mojo exactly. A context is a
        # `void *` (c_void_p, an int or None); a `const char *` is bytes; a
        # byte output is a `uint8_t *` buffer, its capacity and a `uint64_t *`.
        i32, u64, u8 = ctypes.c_int32, ctypes.c_uint64, ctypes.c_uint8
        vp, cp, pu64 = ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint64)
        sigs = {
            "komira_ctx_new": (vp, []),
            "komira_ctx_free": (None, [vp]),
            "komira_last_error": (i32, [vp, vp, u64, pu64]),
            "komira_register_parquet": (i32, [vp, cp, cp]),
            "komira_parquet_schema": (i32, [vp, cp, vp, u64, pu64]),
            "komira_csv_binding": (i32, [vp, cp, u8, i32, i32, vp, u64, pu64]),
            "komira_json_binding": (i32, [vp, cp, vp, u64, pu64]),
            "komira_plan_render": (i32, [vp, cp, u64, vp, u64, pu64]),
        }
        for name, (restype, argtypes) in sigs.items():
            try:
                fn = getattr(lib, name)
            except AttributeError:
                raise KomiraError("libkomira has no export %s" % name) from None
            fn.restype = restype
            fn.argtypes = argtypes

    # --- the handle -------------------------------------------------------

    def ctx_new(self) -> int:
        ctx = self.lib.komira_ctx_new()
        if not ctx:
            raise KomiraError("komira_ctx_new returned NULL")
        return ctx

    def ctx_free(self, ctx) -> None:
        self.lib.komira_ctx_free(ctx)

    # --- errors -----------------------------------------------------------

    def last_error(self, ctx) -> str:
        """The context's last-error text; "" if there is none or it cannot be read."""
        status, data = read_two_call(lambda buf, cap, n: self.lib.komira_last_error(ctx, buf, cap, n))
        return data.decode("utf-8", "replace") if status == KOMIRA_OK else ""

    def check(self, ctx, status: int, what: str) -> None:
        """Raise `KomiraError` carrying `status` and the last-error text unless OK."""
        if status == KOMIRA_OK:
            return
        text = self.last_error(ctx) if ctx else ""
        name = STATUS_NAMES.get(status, "status %d" % status)
        message = "%s failed: %s (%d)" % (what, name, status)
        if text:
            message += ": " + text
        raise KomiraError(message, status=status, last_error=text)

    # --- calls ------------------------------------------------------------

    def register_parquet(self, ctx, name, path) -> None:
        status = self.lib.komira_register_parquet(ctx, _utf8(name, "name"), _utf8(path, "path"))
        self.check(ctx, status, "komira_register_parquet")

    def parquet_schema(self, ctx, path) -> bytes:
        """`komira.plan.v1` WireSchema bytes of the Parquet file's schema."""
        p = _utf8(path, "path")
        return self._bytes(ctx, "komira_parquet_schema", lambda b, c, n: self.lib.komira_parquet_schema(ctx, p, b, c, n))

    def csv_binding(self, ctx, path, delimiter: int = ord(","), has_header: bool = True, all_varchar: bool = False) -> bytes:
        p = _utf8(path, "path")
        if not 0 <= delimiter <= 255:
            raise KomiraError("delimiter must be one byte, not %r" % (delimiter,))
        return self._bytes(
            ctx,
            "komira_csv_binding",
            lambda b, c, n: self.lib.komira_csv_binding(ctx, p, delimiter, int(bool(has_header)), int(bool(all_varchar)), b, c, n),
        )

    def json_binding(self, ctx, path) -> bytes:
        p = _utf8(path, "path")
        return self._bytes(ctx, "komira_json_binding", lambda b, c, n: self.lib.komira_json_binding(ctx, p, b, c, n))

    def plan_render(self, ctx, plan: bytes) -> str:
        if not isinstance(plan, (bytes, bytearray, memoryview)):
            raise KomiraError("plan must be bytes, not %s" % type(plan).__name__)
        plan = bytes(plan)
        data = self._bytes(
            ctx, "komira_plan_render", lambda b, c, n: self.lib.komira_plan_render(ctx, plan, len(plan), b, c, n)
        )
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            raise KomiraError("komira_plan_render returned text that is not UTF-8") from None

    def _bytes(self, ctx, what: str, call) -> bytes:
        status, data = read_two_call(call)
        self.check(ctx, status, what)
        return data


def load(path: Optional[str] = None) -> Native:
    """Load libkomira from `path` (default: beside this package) and check its ABI."""
    path = default_library_path() if path is None else os.fspath(path)
    try:
        lib = ctypes.CDLL(path)
    except OSError as e:
        raise KomiraError("cannot load libkomira from %s: %s" % (path, e)) from None
    return Native(lib)
