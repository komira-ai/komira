"""The ctypes loader of libkomira (src/so/README.md, the C surface).

`load` opens the library from a directory, once per process, checks that its
ABI major version is the one this package was written for, and binds the
calls of `_FUNCTIONS` (the newest from ABI 1.11); every failure is a `LibraryLoadError` that says which
library and why. `Native` holds the bound calls and turns their status codes
into `KomiraError`, with the context's last error, read with the two-call
protocol, as the message, and, from ABI 1.7, its code and step as the error's
`code` and `step`; `_errors.error_class` picks the subclass from them.

Before the library is opened, `load` picks the file and checks the CPU, then
calls `_runtime.check_loaded_runtime(<directory>/lib)` (Linux only; it does
nothing on macOS); an error either raises stops the load before the library is
mapped. How the file is picked depends on the directory:

- A directory with a `VARIANTS` manifest holds libkomira at more than one CPU
  level (docs/design/isa_variants.md, decision 5). `_select_variant` reads the
  manifest, reads the CPU's features from /proc/cpuinfo when a line lists any,
  and picks the last line, the highest level, whose features the CPU all has;
  a CPU without the features of the first line, the floor, is refused with
  `UnsupportedCpuError`. A listed file that is missing is a
  `LibraryLoadError`, never a load of a lower level in its place.
- A directory without one holds a single `libkomira.so` (`libkomira.dylib`
  on macOS), built for the row's own CPU. `_check_cpu` refuses, on Linux
  x86_64, a CPU without the flags of x86-64-v3, the level that library is
  compiled for, with `UnsupportedCpuError`.

Either way an older CPU is refused before it could die of an illegal
instruction inside the library. The runtime check refuses a Mojo runtime
already in the process that is another build than the one in `lib/` of the
directory.

The library is found only where `load` is told: the directory a test passes
(`--lib-dir` of a `python_binding_test`), or, with no directory, the
package's own `_lib/`, where a wheel stages it (`libkomira.so`, or
`libkomira.dylib` on macOS) with its native owners (Linux only) and the Mojo
runtime in `_lib/lib/`. The library's own run path (`$ORIGIN/lib` on Linux,
`@loader_path/lib` on macOS; a variant under `variants/<level>/` also has
`$ORIGIN/../../lib`) finds those. No environment variable and no
search of the working directory picks it (docs/design/python_package.md,
decision 6).
It is opened with `RTLD_LOCAL`, so neither it nor the runtime it brings joins
the process's global symbol scope, where it would take the place of another
Mojo library's own definitions. The library is never closed: the Mojo runtime
does not support unloading, so a refused library stays mapped too, and ctypes
never closes one.

The calls that return protobuf bytes or plan text (`parquet_schema`,
`csv_binding`, `json_binding`, `plan_render`) are private: they have no
Python type yet and no stability promise. So are the three credential calls
(`credential_add`, `credential_set`, `credential_seal`), which
`Session._seal_credential` makes; the engine refusing one of them
(`KOMIRA_ERR_ENGINE`, which the library answers only with
`CREDENTIALS_INVALID`) raises `CredentialsError`. `sql_stream` runs one SQL
statement and returns its filled `_arrow.ArrowArrayStream`, which
`Session.sql` hands to pyarrow (`_arrow.import_stream`) and wraps in a
`Result`; `plan_stream` does the same for a serialized plan, which a
DataFrame's terminal sends (komira/_frame.py). The run handle calls of ABI 1.6 (`run_new`, `run_free`,
`run_cancel`, `run_progress`) and `sql_stream_run`, which runs a statement
under a handle that another thread cancels and reads the progress of, are what
`_run.run_sql` makes; `has` says whether the library has a call.
`register_arrow_stream` (ABI 1.9) drains an Arrow C stream into a table
held in memory, which `Session.register` hands it from a frame or any object
with the Arrow PyCapsule stream interface.
`add_sql_binding` (ABI 1.10) binds a SQL name to the bytes of a
`WireBoundSource`, which `Session.add_sql_binding` makes of a `komira.files`
source after it seals the source's credential.
"""

from __future__ import annotations

import ctypes
import logging
import os
import platform
import sys
import threading
from collections.abc import Callable

from . import _arrow, _runtime
from ._errors import CredentialsError, KomiraError, LibraryLoadError, UnsupportedCpuError, error_class

# The ABI major version this package calls: komira_abi_version() is
# major * 1000 + minor, and a library of another major is refused. Any minor
# is accepted.
ABI_MAJOR = 1

# The two status codes the loader itself tells apart; every other one is a
# failure the caller reports.
KOMIRA_OK = 0
KOMIRA_ERR_ENGINE = -3
KOMIRA_ERR_BUFFER_TOO_SMALL = -4
# A run stopped by komira_run_cancel (ABI 1.6).
KOMIRA_ERR_CANCELLED = -6

# The scope a credential is sealed in and a source is bound in: the session
# (src/so/abi/komira.tsv).
KOMIRA_BIND_SESSION = 1

# The Hive partitioning modes of komira_parquet_source (the KOMIRA_HIVE_*
# constants of src/so/abi/komira.tsv): partition columns when every file has
# the same keys, partition columns with files whose keys differ refused, none.
KOMIRA_HIVE_AUTO = 0
KOMIRA_HIVE_ON = 1
KOMIRA_HIVE_OFF = 2

# The step of a refusal, komira_last_error_step's answer, as the name the
# error's `step` carries (the KOMIRA_STEP_* constants of src/so/abi/komira.tsv).
# KOMIRA_STEP_NONE, and a number a later library adds, have no name.
_STEPS = {1: "parse", 2: "bind", 3: "optimize", 4: "lower", 5: "execute"}

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
    "komira_ctx_new_with_options": (4, ctypes.c_void_p, [ctypes.c_int64, ctypes.c_int64]),
    "komira_ctx_free": (0, None, [ctypes.c_void_p]),
    "komira_last_error": (0, ctypes.c_int32, [ctypes.c_void_p] + _Out),
    "komira_last_error_code": (7, ctypes.c_int32, [ctypes.c_void_p] + _Out),
    "komira_last_error_step": (7, ctypes.c_int32, [ctypes.c_void_p]),
    "komira_register_parquet": (1, ctypes.c_int32, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]),
    "komira_parquet_schema": (1, ctypes.c_int32, [ctypes.c_void_p, ctypes.c_char_p] + _Out),
    "komira_parquet_source": (11, ctypes.c_int32, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32] + _Out),
    "komira_csv_binding": (
        1,
        ctypes.c_int32,
        [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint8, ctypes.c_int32, ctypes.c_int32] + _Out,
    ),
    "komira_json_binding": (1, ctypes.c_int32, [ctypes.c_void_p, ctypes.c_char_p] + _Out),
    "komira_plan_render": (1, ctypes.c_int32, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint64] + _Out),
    "komira_credential_add": (
        2,
        ctypes.c_int32,
        [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p, ctypes.POINTER(ctypes.c_int32)],
    ),
    "komira_credential_set": (
        2,
        ctypes.c_int32,
        [ctypes.c_void_p, ctypes.c_int32, ctypes.c_int32, ctypes.c_char_p, ctypes.c_uint64],
    ),
    "komira_credential_seal": (2, ctypes.c_int32, [ctypes.c_void_p, ctypes.c_int32, ctypes.c_int32]),
    "komira_sql_stream": (
        3,
        ctypes.c_int32,
        [ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(_arrow.ArrowArrayStream)],
    ),
    "komira_register_csv": (
        5,
        ctypes.c_int32,
        [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint8, ctypes.c_int32, ctypes.c_int32],
    ),
    "komira_register_json": (5, ctypes.c_int32, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]),
    "komira_run_new": (6, ctypes.c_void_p, []),
    "komira_run_free": (6, None, [ctypes.c_void_p]),
    "komira_run_cancel": (6, ctypes.c_int32, [ctypes.c_void_p]),
    "komira_run_progress": (
        6,
        ctypes.c_int32,
        [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint64)],
    ),
    "komira_sql_stream_run": (
        6,
        ctypes.c_int32,
        [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(_arrow.ArrowArrayStream)],
    ),
    "komira_plan_stream": (
        8,
        ctypes.c_int32,
        [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint64, ctypes.POINTER(_arrow.ArrowArrayStream)],
    ),
    "komira_register_arrow_stream": (9, ctypes.c_int32, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p]),
    "komira_add_sql_binding": (
        10,
        ctypes.c_int32,
        [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint64, ctypes.c_int32],
    ),
}

_log = logging.getLogger("komira")

_lock = threading.Lock()
_loaded: Native | None = None
# The absolute directory `_loaded` was loaded from.
_loaded_dir: str | None = None


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

# Where `_check_cpu` and `_select_variant` read the CPU's features unless
# they are given a file.
_CPUINFO = "/proc/cpuinfo"

# The manifest of a directory with more than one CPU level of libkomira: one
# line per level, lowest first, of three tab-separated fields: the level's
# name, its file's path relative to the directory, and the space-separated
# /proc/cpuinfo features it needs. Fields after the third are ignored. The
# build writes it from the platform row
# (tools/build/platforms/isa_variants.bzl, `variants_manifest`).
_MANIFEST = "VARIANTS"

# The /proc/cpuinfo key whose words are a processor's features, by
# `platform.machine()` on Linux: `flags` on x86_64, `Features` on aarch64.
_FEATURE_KEYS = {"x86_64": "flags", "aarch64": "Features"}


def _cpu_flags(text: str, key: str = "flags") -> set[str]:
    """The features every processor of /proc/cpuinfo text lists on its `key`
    line (`flags` on x86, `Features` on arm64): a thread may run on any of
    them. Other lines, `vmx flags` among them, are not read. No `key` line is
    no features."""
    common: set[str] | None = None
    for line in text.splitlines():
        name, sep, value = line.partition(":")
        if not sep or name.strip() != key:
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


def _read_manifest(directory: str) -> list[tuple[str, str, list[str]]]:
    """The lines of `<directory>/VARIANTS` as (name, path, features), in the
    file's order. A manifest that cannot be read, is not UTF-8, has no line,
    or has a line without a name, a path inside the directory and a features
    field is a `LibraryLoadError` naming the file (and the line)."""
    path = os.path.join(directory, _MANIFEST)
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        raise LibraryLoadError("cannot read the variant manifest {}: {}".format(path, e)) from None
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        raise LibraryLoadError("the variant manifest {} is not UTF-8: {}".format(path, e)) from None
    lines = text.split("\n")
    if lines[-1] == "":
        lines.pop()
    if not lines:
        raise LibraryLoadError("the variant manifest {} names no variant".format(path))
    variants = []
    for number, line in enumerate(lines, 1):
        fields = line.split("\t")
        if len(fields) < 3 or not fields[0] or not fields[1]:
            raise LibraryLoadError(
                "line {} of the variant manifest {} is not `<name><TAB><path><TAB><features>`: {!r}".format(
                    number, path, line
                )
            )
        if os.path.isabs(fields[1]) or ".." in fields[1].split("/"):
            raise LibraryLoadError(
                "line {} of the variant manifest {} names {!r}, which is not a path inside its directory".format(
                    number, path, fields[1]
                )
            )
        variants.append((fields[0], fields[1], fields[2].split()))
    return variants


def _select_variant(
    directory: str | os.PathLike[str],
    cpuinfo: str | os.PathLike[str] | None = None,
    *,
    system: str | None = None,
    machine: str | None = None,
) -> str:
    """The absolute path of the variant of libkomira in `directory` that this
    CPU runs fastest: the last line of `<directory>/VARIANTS` whose features
    the CPU all has (docs/design/isa_variants.md, decision 5).

    The CPU's features are read only when a line lists any: from `cpuinfo`
    (/proc/cpuinfo when None; tests pass a file), the words of the key
    `_FEATURE_KEYS` names for `machine` that every processor lists. `system`
    and `machine` are `sys.platform` and `platform.machine()` when None.

    Raises `LibraryLoadError` when the manifest is missing or malformed (see
    `_read_manifest`), when it lists features and this is not Linux on x86_64
    or aarch64, when `cpuinfo` cannot be read, and when the picked line's file
    is missing: a lower variant is never loaded in its place. Raises
    `UnsupportedCpuError`, naming the floor (the first line) and the features
    of it the CPU lacks, when the CPU has the features of no line.
    """
    directory = os.path.abspath(os.fspath(directory))
    manifest = os.path.join(directory, _MANIFEST)
    variants = _read_manifest(directory)
    have: set[str] = set()
    path = key = ""
    if any(features for _, _, features in variants):
        system = sys.platform if system is None else system
        machine = platform.machine() if machine is None else machine
        key = _FEATURE_KEYS.get(machine, "") if system == "linux" else ""
        if not key:
            raise LibraryLoadError(
                "the variant manifest {} lists CPU features, which are read from /proc/cpuinfo only on Linux "
                "x86_64 and aarch64, and this is {} {}".format(manifest, system, machine)
            )
        path = _CPUINFO if cpuinfo is None else os.fspath(cpuinfo)
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError as e:
            raise LibraryLoadError(
                "cannot read the CPU features from {}, so it is not known which variant of libkomira in {} "
                "this CPU runs: {}".format(path, directory, e)
            ) from None
        have = _cpu_flags(text, key)
    chosen = None
    for name, rel, features in variants:
        if all(f in have for f in features):
            chosen = (name, rel)
    if chosen is None:
        floor, _, features = variants[0]
        raise UnsupportedCpuError(
            "this CPU runs no variant of libkomira in {}: the lowest, {}, needs {}, which the `{}` lines of {} "
            "do not all list".format(directory, floor, ", ".join(f for f in features if f not in have), key, path)
        )
    name, rel = chosen
    file = os.path.join(directory, rel)
    if not os.path.isfile(file):
        raise LibraryLoadError(
            "the variant manifest {} names {} for {}, the variant this CPU runs, and there is no such file; "
            "no lower variant is loaded in its place".format(manifest, file, name)
        )
    return file


def _missing_runtime(lib_dir: str) -> list[str]:
    """The paths of the Mojo runtime libraries (`_runtime.RUNTIME_LIBRARIES`,
    spelled `.dylib` on macOS) that `lib_dir` does not hold, in the order the
    list names them. A symlink to a file that is gone counts as missing. `load`
    asks only when libkomira itself is there, so a directory with no library
    in it is not reported as an incomplete package."""
    suffix = ".dylib" if sys.platform == "darwin" else ".so"
    names = [name[: -len(".so")] + suffix for name in _runtime.RUNTIME_LIBRARIES]
    paths = [os.path.join(lib_dir, name) for name in names]
    return [p for p in paths if not os.path.exists(p)]


def _library_path(directory: str) -> str:
    """The file `load` opens from `directory` (absolute), once the CPU has
    been checked: the variant `_select_variant` picks when the directory
    holds a VARIANTS manifest, else `<directory>/libkomira.so` after
    `_check_cpu`."""
    if os.path.lexists(os.path.join(directory, _MANIFEST)):
        return _select_variant(directory)
    _check_cpu()
    return os.path.join(directory, _LIB_NAME)


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


def _delimiter(value: object) -> int:
    """A CSV delimiter argument: one ASCII character, as the byte the call takes."""
    if not isinstance(value, str):
        raise TypeError("delimiter must be a str, not {}".format(type(value).__name__))
    if len(value) != 1 or ord(value) > 127:
        raise ValueError("delimiter must be one ASCII character, not {!r}".format(value))
    return ord(value)


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

    def has(self, name: str) -> bool:
        """Whether this library has the call `name` (one of `_FUNCTIONS`):
        its minor version is the call's or later."""
        return self._functions[name] is not None

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

    def ctx_new_with_options(self, worker_count: int, memory_budget_bytes: int) -> int:
        """A context whose engine runs `worker_count` workers within
        `memory_budget_bytes`; 0 for either is the engine's own value. Needs
        ABI 1.4. The engine refuses an option it cannot start with (NULL)."""
        ctx = self._fn("komira_ctx_new_with_options")(worker_count, memory_budget_bytes)
        if not ctx:
            raise KomiraError(
                "komira_ctx_new_with_options returned NULL for {} workers and a budget of {} bytes".format(
                    worker_count, memory_budget_bytes
                )
            )
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

    def last_error_code(self, ctx: int) -> str | None:
        """The named code of the context's last error, or None when it has
        none, there is no error, or the library is older than ABI 1.7."""
        if self._functions["komira_last_error_code"] is None:
            return None
        fn = self._fn("komira_last_error_code")
        status, text = _two_call("komira_last_error_code", lambda buf, cap, n: fn(ctx, buf, cap, n))
        if status != KOMIRA_OK:
            raise KomiraError("komira_last_error_code failed with status {}".format(status), status=status)
        return text.decode("utf-8", "replace") or None

    def last_error_step(self, ctx: int) -> str | None:
        """The step ("parse", "bind", "optimize", "lower" or "execute") of the
        context's last error, or None when it has none, a number this package
        does not know, or the library is older than ABI 1.7."""
        fn = self._functions["komira_last_error_step"]
        if fn is None:
            return None
        return _STEPS.get(fn(ctx))

    def register_parquet(self, ctx: int, name: str, path: str | os.PathLike[str]) -> None:
        """Registers the Parquet file at `path` in the context as the table `name`."""
        op = "komira_register_parquet"
        fn = self._fn(op)
        self._check(op, ctx, fn(ctx, _c_string("name", name), _c_path(path)))

    def register_csv(
        self,
        ctx: int,
        name: str,
        path: str | os.PathLike[str],
        *,
        delimiter: str,
        header: bool,
        all_varchar: bool,
    ) -> None:
        """Registers the CSV file at `path` in the context as the table
        `name`, read with `delimiter` and, when `header`, its first line as
        the column names; `all_varchar` makes every column a string. The
        library infers the schema now."""
        op = "komira_register_csv"
        fn = self._fn(op)
        c_name, c_path = _c_string("name", name), _c_path(path)
        d, h, a = _delimiter(delimiter), _flag("header", header), _flag("all_varchar", all_varchar)
        self._check(op, ctx, fn(ctx, c_name, c_path, d, h, a))

    def register_json(self, ctx: int, name: str, path: str | os.PathLike[str]) -> None:
        """Registers the newline-delimited JSON file at `path` in the context
        as the table `name`. The library infers the schema now."""
        op = "komira_register_json"
        fn = self._fn(op)
        self._check(op, ctx, fn(ctx, _c_string("name", name), _c_path(path)))

    def parquet_schema(self, ctx: int, path: str | os.PathLike[str]) -> bytes:
        """The `WireSchema` bytes of the Parquet file at `path`."""
        c_path = _c_path(path)
        return self._out("komira_parquet_schema", ctx, lambda fn, b, c, n: fn(ctx, c_path, b, c, n))

    def parquet_source(self, ctx: int, path: str | os.PathLike[str], hive_partitioning: int) -> bytes:
        """The `WireParquetSource` bytes of the Parquet files at `path` (one
        file, a glob or a directory), with the Hive partition columns the
        `KOMIRA_HIVE_*` mode `hive_partitioning` asks for. Needs ABI 1.11."""
        c_path = _c_path(path)
        return self._out(
            "komira_parquet_source", ctx, lambda fn, b, c, n: fn(ctx, c_path, hive_partitioning, b, c, n)
        )

    def csv_binding(
        self, ctx: int, path: str | os.PathLike[str], *, delimiter: str, has_header: bool, all_varchar: bool
    ) -> bytes:
        """The `WireScanBinding` bytes of the CSV file at `path`."""
        c_path = _c_path(path)
        d, h, a = _delimiter(delimiter), _flag("has_header", has_header), _flag("all_varchar", all_varchar)
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

    def credential_add(self, ctx: int, kind: int, name: str) -> int:
        """Opens the definition of a credential of `kind` (a `KOMIRA_CRED_*`)
        named `name`, and returns its id."""
        op = "komira_credential_add"
        fn = self._fn(op)
        out_id = ctypes.c_int32(0)
        self._check(op, ctx, fn(ctx, kind, _c_string("name", name), ctypes.byref(out_id)), CredentialsError)
        return out_id.value

    def credential_set(self, ctx: int, cred_id: int, field: int, value: bytes) -> None:
        """Sets the field `field` (a `KOMIRA_FIELD_*`) of the open definition
        `cred_id` to the bytes `value`, which may hold NUL bytes."""
        op = "komira_credential_set"
        fn = self._fn(op)
        if not isinstance(value, bytes):
            raise TypeError("value must be bytes, not {}".format(type(value).__name__))
        self._check(op, ctx, fn(ctx, cred_id, field, value, len(value)), CredentialsError)

    def credential_seal(self, ctx: int, cred_id: int, scope: int = KOMIRA_BIND_SESSION) -> None:
        """Makes the definition `cred_id` the value of its name in `scope`."""
        op = "komira_credential_seal"
        fn = self._fn(op)
        self._check(op, ctx, fn(ctx, cred_id, scope), CredentialsError)

    def sql_stream(self, ctx: int, query: str) -> _arrow.ArrowArrayStream:
        """Runs the SQL statement `query` on the context and returns its
        answer, the Arrow C stream the library filled; the caller releases
        it. A refusal raises KomiraError before any stream exists: the
        library leaves the struct as it was given, zeroed, on failure."""
        op = "komira_sql_stream"
        fn = self._fn(op)
        text = _c_string("query", query)
        stream = _arrow.ArrowArrayStream()
        self._check(op, ctx, fn(ctx, text, ctypes.byref(stream)))
        return stream

    def run_new(self) -> int:
        """A new run handle (komira_run_new): not cancelled, at 0 of 0
        segments. The caller frees it with run_free once no call given it is
        running."""
        run = self._fn("komira_run_new")()
        if not run:
            raise KomiraError("komira_run_new returned NULL")
        return int(run)

    def run_free(self, run: int) -> None:
        self._fn("komira_run_free")(run)

    def run_cancel(self, run: int) -> None:
        """Cancels the run in flight under `run`, and every later one; any
        thread may call it while the run runs."""
        status = self._fn("komira_run_cancel")(run)
        if status != KOMIRA_OK:
            raise KomiraError("komira_run_cancel failed with status {}".format(status), status=status)

    def run_progress(self, run: int) -> tuple[int, int]:
        """(done, total): the plan segments the runs given `run` finished and
        counted. Any thread may call it while the run runs."""
        fn = self._fn("komira_run_progress")
        done, total = ctypes.c_uint64(0), ctypes.c_uint64(0)
        status = fn(run, ctypes.byref(done), ctypes.byref(total))
        if status != KOMIRA_OK:
            raise KomiraError("komira_run_progress failed with status {}".format(status), status=status)
        return done.value, total.value

    def sql_stream_run(self, ctx: int, query: str | bytes, run: int) -> _arrow.ArrowArrayStream:
        """`sql_stream` under the run handle `run`: a cancel of `run` while
        it runs raises KomiraError with status KOMIRA_ERR_CANCELLED and the
        library's `QUERY_CANCELLED: ...` message, and makes no stream. `query`
        may be the bytes `_c_string` made of it."""
        op = "komira_sql_stream_run"
        fn = self._fn(op)
        text = query if isinstance(query, bytes) else _c_string("query", query)
        stream = _arrow.ArrowArrayStream()
        self._check(op, ctx, fn(ctx, text, run, ctypes.byref(stream)))
        return stream

    def plan_stream(self, ctx: int, plan: bytes) -> _arrow.ArrowArrayStream:
        """Runs the serialized plan `plan` (a `WirePlanEnvelope`, which may
        hold NUL bytes) on the context and returns its answer, the Arrow C
        stream the library filled; the caller releases it. No SQL front end
        is involved: the library decodes, optimizes, lowers and runs the
        plan. A refusal raises KomiraError before any stream exists, as
        `sql_stream`'s does."""
        op = "komira_plan_stream"
        fn = self._fn(op)
        if not isinstance(plan, (bytes, bytearray, memoryview)):
            raise TypeError("plan must be bytes, not {}".format(type(plan).__name__))
        data = bytes(plan)
        stream = _arrow.ArrowArrayStream()
        self._check(op, ctx, fn(ctx, data, len(data), ctypes.byref(stream)))
        return stream

    def register_arrow_stream(self, ctx: int, name: str, stream: int) -> None:
        """Drains the Arrow C stream at the address `stream` into a table the
        context holds in memory and registers it as `name`, replacing any
        table of that name. The library calls the stream's `release` once,
        whatever the status, unless it was released already; the caller
        keeps the struct. Needs ABI 1.9."""
        op = "komira_register_arrow_stream"
        fn = self._fn(op)
        self._check(op, ctx, fn(ctx, _c_string("name", name), stream))

    def add_sql_binding(self, ctx: int, name: str, source: bytes, scope: int = KOMIRA_BIND_SESSION) -> None:
        """Binds the SQL name `name` on the context to the source `source`,
        the bytes of a `WireBoundSource` (which may hold NUL bytes), in
        `scope`, replacing any table of that name. Needs ABI 1.10."""
        op = "komira_add_sql_binding"
        fn = self._fn(op)
        if not isinstance(source, bytes):
            raise TypeError("source must be bytes, not {}".format(type(source).__name__))
        self._check(op, ctx, fn(ctx, _c_string("name", name), source, len(source), scope))

    def _out(self, op: str, ctx: int, call: Callable[[ctypes._CFuncPtr, object, int, object], int]) -> bytes:
        """The bytes of the two-call `op`, or its KomiraError."""
        fn = self._fn(op)
        status, data = _two_call(op, lambda b, c, n: call(fn, b, c, n))
        self._check(op, ctx, status)
        return data

    def _check(self, op: str, ctx: int, status: int, refused: type[KomiraError] = KomiraError) -> None:
        """Raises the KomiraError of a call `op` on `ctx` that returned `status`,
        unless it is KOMIRA_OK. The message is the context's last error. When
        the engine refused (KOMIRA_ERR_ENGINE) and the context holds that
        message, the error's class is `error_class`'s pick from its code and
        step, `refused` (the subclass the call's refusals have) when they name
        none; every other failure is a plain KomiraError. `code` and `step`
        are the context's last error's, None from a library without them."""
        if status == KOMIRA_OK:
            return
        try:
            text = self.last_error(ctx)
            code = self.last_error_code(ctx)
        except KomiraError as e:
            raise KomiraError(
                "{} failed with status {}; its last error could not be read: {}".format(op, status, e),
                status=status,
            ) from e
        step = self.last_error_step(ctx)
        if not text:
            raise KomiraError("{} failed with status {} and no message".format(op, status), status=status)
        raise error_class(status, code, step, refused)(text, status=status, code=code, step=step)


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

    With `lib_dir`, the library is the one in that directory: the variant
    `_select_variant` picks for this CPU when it holds a VARIANTS manifest,
    else `<lib_dir>/libkomira.so` (`libkomira.dylib` on macOS). With None, it
    is the one already loaded, or else the one in the package's `_lib/`. The
    first load that succeeds is kept: a later call naming the same directory
    returns the same `Native`, without reading the CPU again, and one naming
    another directory is refused, since a process holds one library. A
    refused load leaves nothing loaded. A file missing from the directory is
    a `LibraryLoadError` that names it.
    """
    global _loaded, _loaded_dir
    with _lock:
        if lib_dir is None and _loaded is not None:
            return _loaded
        directory = os.path.abspath(_PACKAGE_LIB_DIR if lib_dir is None else os.fspath(lib_dir))
        if _loaded is not None:
            if _loaded_dir == directory:
                return _loaded
            raise LibraryLoadError(
                "libkomira is already loaded from {}; it cannot also be loaded from {}".format(
                    _loaded.path, os.path.join(directory, _LIB_NAME)
                )
            )
        path = _library_path(directory)
        _runtime.check_loaded_runtime(os.path.join(directory, "lib"))
        try:
            lib = ctypes.CDLL(path, mode=ctypes.RTLD_LOCAL)
        except OSError as e:
            missing = _missing_runtime(os.path.join(directory, "lib")) if os.path.exists(path) else []
            if missing:
                raise LibraryLoadError(
                    "cannot load libkomira from {}: the package is incomplete (reinstall komira), "
                    "{} missing: {}; the loader says: {}".format(
                        path, "this file is" if len(missing) == 1 else "these files are", ", ".join(missing), e
                    )
                ) from None
            raise LibraryLoadError("cannot load libkomira from {}: {}".format(path, e)) from None
        _loaded = _bind(lib, path)
        _loaded_dir = directory
        _log.debug("loaded libkomira ABI %d.%d from %s", *divmod(_loaded.abi_version, 1000), path)
        return _loaded
