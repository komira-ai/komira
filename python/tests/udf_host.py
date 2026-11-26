"""A ctypes host of the UDF runtime C ABI (src/udf_abi/komira_udf_runtime.h), for the
tests of libkomira_udf_python.so (libkomira_udf_python.dylib on macOS): it loads the library, hands it options, a
clock and a memory hook it controls, and drives validate, load, open_context,
open_instance and call_batch with Arrow data exported by pyarrow.

Also here: a canonical protobuf encoder for the descriptor subset the runtime
reads, a builder of code bundles (zip files named by their sha256), a reader of
the runtime's trace file and the scratch layout every test starts from.
"""

import ctypes
import hashlib
import importlib.util
import os
import select
import shutil
import sys
import sysconfig
import tempfile
import zipfile
from ctypes import (
    CFUNCTYPE, POINTER, Structure, addressof, byref, c_char_p, c_int32, c_int64,
    c_size_t, c_uint8, c_uint32, c_void_p, sizeof,
)

import pyarrow as pa

OK = 0
ERR_ABI = 1
ERR_DESCRIPTOR = 2
ERR_UNSUPPORTED = 3
ERR_CODE_DIGEST = 4
ERR_LOAD = 5
ERR_RAISED = 6
ERR_RETURN_TYPE = 7
ERR_LENGTH = 8
ERR_CANCELLED = 11
ERR_DEADLINE = 12
ERR_OUT_OF_MEMORY = 13
ERR_INSTANCE_LOST = 14
ERR_INTERNAL = 15
ERR_WORKER_CRASHED = 17
ERR_HOST_CONTRACT = 18
ERR_KILLED = 19
ERR_BAD_OPTION = 21

FEATURE_CONTAINS_CRASHES = 1 << 1
FEATURE_FORCED_STOP = 1 << 2

SHAPE_SCALAR = 1
SHAPE_ROW = 2
SHAPE_MAP_BATCHES_COLUMN = 4
SHAPE_MAP_BATCHES_FRAME = 8

FORM_PACKAGE = 1
FORM_BUNDLE = 2
FORM_VALUE = 3

NULL_MANUAL = 1
NULL_PROPAGATE = 2

VALUES = 1
ARROW = 2
PANDAS = 3

ROLE_BUNDLE = "bundle"


class CSchema(Structure):
    pass


CSchema._fields_ = [
    ("format", c_char_p), ("name", c_char_p), ("metadata", c_char_p),
    ("flags", c_int64), ("n_children", c_int64), ("children", c_void_p),
    ("dictionary", c_void_p), ("release", c_void_p), ("private_data", c_void_p),
]


class CArray(Structure):
    _fields_ = [
        ("length", c_int64), ("null_count", c_int64), ("offset", c_int64),
        ("n_buffers", c_int64), ("n_children", c_int64), ("buffers", c_void_p),
        ("children", c_void_p), ("dictionary", c_void_p), ("release", c_void_p),
        ("private_data", c_void_p),
    ]


_RELEASE = CFUNCTYPE(None, POINTER(CArray))


def _mark_released(array):
    array.contents.release = None


class CDeviceArray(Structure):
    _fields_ = [
        ("array", CArray), ("device_id", c_int64), ("device_type", c_int32),
        ("sync_event", c_void_p), ("reserved", c_int64 * 3),
    ]


class CError(Structure):
    pass


CError._fields_ = [
    ("struct_size", c_size_t), ("code", c_int32), ("message", c_char_p),
    ("user_trace", c_char_p), ("row", c_int64), ("group", c_int64),
    ("release", CFUNCTYPE(None, POINTER(CError))), ("private_data", c_void_p),
]

_MEM_RESERVE = CFUNCTYPE(c_int32, c_void_p, c_int64)
_MEM_RELEASE = CFUNCTYPE(None, c_void_p, c_int64)
_NOW_NS = CFUNCTYPE(c_int64, c_void_p)
_LOG = CFUNCTYPE(None, c_void_p, c_int32, c_char_p)


class CHost(Structure):
    _fields_ = [
        ("struct_size", c_size_t), ("abi_major", c_uint32), ("abi_minor", c_uint32),
        ("host_data", c_void_p), ("mem_reserve", _MEM_RESERVE),
        ("mem_release", _MEM_RELEASE), ("now_ns", _NOW_NS), ("log", _LOG),
        ("n_options", c_size_t), ("options", c_void_p),
    ]


HOST_SIZE_WITHOUT_OPTIONS = CHost.n_options.offset


class CCaps(Structure):
    _fields_ = [
        ("struct_size", c_size_t), ("runtime_id", c_char_p), ("runtime_abi", c_char_p),
        ("max_descriptor_version", c_uint32), ("shapes", c_uint32),
        ("devices", c_uint32), ("features", c_uint32), ("udf_class", c_uint32),
    ]


class CSpec(Structure):
    _fields_ = [
        ("struct_size", c_size_t), ("shape", c_int32), ("form", c_int32),
        ("entry", c_char_p), ("descriptor_version", c_uint32),
        ("descriptor", POINTER(c_uint8)), ("descriptor_len", c_size_t),
        ("args", POINTER(CSchema)), ("result", POINTER(CSchema)),
        ("state", POINTER(CSchema)), ("null_mode", c_int32), ("stability", c_int32),
        ("code_root", c_char_p), ("n_code", c_size_t),
        ("code_roles", POINTER(c_char_p)), ("code_sha256", POINTER(c_uint8 * 32)),
    ]


class CCall(Structure):
    _fields_ = [
        ("struct_size", c_size_t), ("deadline_ns", c_int64), ("call_id", c_int64),
        ("cancel", POINTER(c_int32)),
    ]


_P = c_void_p
_TABLE_FNS = [
    ("describe", CFUNCTYPE(c_int32, _P, POINTER(CCaps))),
    ("validate", CFUNCTYPE(c_int32, _P, POINTER(CSpec), POINTER(CError))),
    ("load", CFUNCTYPE(c_int32, _P, POINTER(CSpec), POINTER(_P), POINTER(CError))),
    ("unload", CFUNCTYPE(None, _P)),
    ("open_context", CFUNCTYPE(c_int32, _P, c_uint32, POINTER(_P), POINTER(CError))),
    ("close_context", CFUNCTYPE(None, _P)),
    ("open_instance", CFUNCTYPE(c_int32, _P, _P, POINTER(_P), POINTER(CError))),
    ("close_instance", CFUNCTYPE(None, _P)),
    ("call_batch", CFUNCTYPE(c_int32, _P, POINTER(CCall), POINTER(CDeviceArray),
                             POINTER(CDeviceArray), POINTER(CError))),
    ("frame_open", _P), ("frame_next", _P), ("frame_close", _P),
    ("agg_open", _P), ("agg_update", _P), ("agg_merge", _P), ("agg_state", _P),
    ("agg_finish", _P), ("agg_close", _P),
    ("shutdown", CFUNCTYPE(None, _P)),
    ("memory_report", _P),
]


class CTable(Structure):
    _fields_ = [("struct_size", c_size_t), ("abi_major", c_uint32),
                ("abi_minor", c_uint32)] + _TABLE_FNS


class Err:
    """What the runtime reported: code, message, trace, row, group."""

    def __init__(self, c):
        self.code = c.code
        self.message = c.message.decode("utf-8") if c.message is not None else None
        self.trace = c.user_trace.decode("utf-8") if c.user_trace is not None else None
        self.row = c.row
        self.group = c.group
        if c.release:
            c.release(byref(c))

    def __repr__(self):
        return "Err(code=%d, message=%r, row=%d)" % (self.code, self.message, self.row)


def _new_error():
    e = CError()
    e.struct_size = sizeof(CError)
    e.row = -2
    e.group = -2
    return e


# ---- descriptor encoding ---------------------------------------------------


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def encode_fields(fields):
    """Fields as given, in order: (number, int | str | bytes). Not sorted, so a
    test can write a non-canonical message."""
    out = b""
    for num, value in fields:
        if isinstance(value, int):
            out += varint(num << 3) + varint(value)
        else:
            raw = value.encode() if isinstance(value, str) else value
            out += varint(num << 3 | 2) + varint(len(raw)) + raw
    return out


def descriptor(entry, shapes, batch_format=VALUES, is_async=False, extra=()):
    """The canonical descriptor: fields ascending, defaults omitted."""
    fields = [(1, entry), (2, shapes)]
    if batch_format:
        fields.append((7, batch_format))
    if is_async:
        fields.append((10, 1))
    fields.extend(extra)
    return encode_fields(sorted(fields, key=lambda f: f[0]))


# ---- bundles, scratch, trace -----------------------------------------------


def make_zip(files):
    """The bytes of a stored zip of {name: source}, the same for the same files."""
    import io

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as z:
        for name in sorted(files):
            info = zipfile.ZipInfo(name, date_time=(2026, 9, 1, 0, 0, 0))
            z.writestr(info, files[name])
    return buf.getvalue()


class Trace:
    def __init__(self, path):
        self.path = path

    def events(self, name=None):
        if not os.path.exists(self.path):
            return []
        out = []
        with open(self.path, encoding="utf-8") as f:
            for line in f.read().splitlines():
                words = line.split(" ")
                ev = {"event": words[0]}
                for w in words[1:]:
                    k, _, v = w.partition("=")
                    ev[k] = v
                out.append(ev)
        return [e for e in out if name is None or e["event"] == name]

    def names(self):
        return [e["event"] for e in self.events()]

    def pids(self, name):
        return [int(e["pid"]) for e in self.events(name)]


def abi_tag():
    return "cp" + sys.implementation.cache_tag.replace("cpython-", "")


def zygote_path():
    import komira._udf  # noqa: F401  (finds the package directory)

    return importlib.util.find_spec("komira._udf.zygote").origin


def runtime_sys_path():
    std = {os.path.realpath(sysconfig.get_path(k)) for k in ("stdlib", "platstdlib")}
    skip = std | {os.path.join(p, "lib-dynload") for p in std}
    return [p for p in sys.path
            if p and os.path.isdir(p) and os.path.realpath(p) not in skip]


# The library's file in the --lib-dir: the staged name on this platform.
LIB_FILE = "libkomira_udf_python.dylib" if sys.platform == "darwin" else "libkomira_udf_python.so"


def _darwin_status(pid):
    """macOS: pbi_status of proc_pidinfo(PROC_PIDTBSDINFO), None once libproc has no
    such process (<sys/proc_info.h>; the reading tools/build/run/proctab_darwin.zig makes)."""
    libc = ctypes.CDLL(None, use_errno=True)
    libc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, c_void_p, ctypes.c_int]
    info = (c_uint8 * 136)()
    got = libc.proc_pidinfo(pid, 3, 0, info, sizeof(info))
    if got != sizeof(info):
        return None
    return int.from_bytes(bytes(info[4:8]), "little")


def process_gone(pid):
    """True once the process has ended, reaped or not: a zombie has ended."""
    if sys.platform == "darwin":
        status = _darwin_status(pid)
        return status is None or status == 5  # SZOMB
    try:
        with open("/proc/%d/stat" % pid, encoding="ascii", errors="replace") as f:
            stat = f.read()
    except (FileNotFoundError, ProcessLookupError):
        return True
    return stat.rpartition(")")[2].split()[0] in ("Z", "X")


# The source of `fd_names()`, for a probe that runs in a worker: its open descriptors,
# by number (a str), each named by what it is. On Linux the target of
# /proc/self/fd/<n> ("/dev/null", "socket:[...]", "/memfd:<name> (deleted)"). On macOS,
# which has neither, the numbers listed in /dev/fd, each named "socket:" when fstat says
# it is a socket, else by its path (fcntl F_GETPATH), else "mode:<st_mode in octal>".
# No "%" in it: the probes are %-formatted.
FD_NAMES = """

def fd_names():
    import os
    import sys
    fds = {}
    if sys.platform == "darwin":
        import fcntl
        import stat
        for name in os.listdir("/dev/fd"):
            try:
                mode = os.fstat(int(name)).st_mode
            except OSError:
                continue  # the listing's own descriptor, closed by now
            if stat.S_ISSOCK(mode):
                fds[name] = "socket:"
                continue
            try:
                fds[name] = fcntl.fcntl(int(name), fcntl.F_GETPATH, bytes(1024)).split(b"\\0")[0].decode()
            except OSError:
                fds[name] = "mode:" + format(mode, "o")
        return fds
    for name in os.listdir("/proc/self/fd"):
        try:
            fds[name] = os.readlink("/proc/self/fd/" + name)
        except FileNotFoundError:
            pass
    return fds
"""


class ExitWatch:
    """Opened on a process known to be running; wait() returns once it has ended, reaped
    or not. A pidfd on Linux (readable once its process terminates); on macOS a kqueue
    with an EVFILT_PROC NOTE_EXIT filter for the pid, where a registration refused with
    ESRCH is a process that has already ended."""

    def __init__(self, pid):
        self.pid = pid
        if sys.platform == "darwin":
            self._fd = None
            self._kq = select.kqueue()
            try:
                self._kq.control([select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD,
                                                select.KQ_NOTE_EXIT)], 0, 0)
            except ProcessLookupError:
                self._kq.close()
                self._kq = None
        else:
            self._kq = None
            self._fd = os.pidfd_open(pid)

    def wait(self):
        """Block until the process has ended; releases the watch."""
        if self._fd is not None:
            try:
                poller = select.poll()
                poller.register(self._fd, select.POLLIN)
                poller.poll()
            finally:
                os.close(self._fd)
                self._fd = None
        elif self._kq is not None:
            try:
                self._kq.control(None, 1)
            finally:
                self._kq.close()
                self._kq = None


class Env:
    """A fresh scratch tree: code_root, the runtime's scratch, a trace file."""

    def __init__(self, lib_dir, check_leaks=True):
        self.check_leaks = check_leaks
        self.lib = os.path.join(os.path.abspath(lib_dir), LIB_FILE)
        self.dir = os.path.realpath(tempfile.mkdtemp(prefix="udf-"))
        self.code_root = self._mk("code")
        self.scratch = self._mk("rt")
        self.trace = Trace(os.path.join(self.dir, "trace.log"))
        self.runtimes = []

    def _mk(self, name):
        p = os.path.join(self.dir, name)
        os.mkdir(p)
        return p

    def path(self, name):
        return os.path.join(self.dir, name)

    def options(self, drop=(), **over):
        values = {
            "interpreter": sys.executable, "zygote": zygote_path(), "abi": abi_tag(),
            "scratch": self.scratch, "trace": self.trace.path,
        }
        values.update(over)
        opts = ["%s=%s" % (k, v) for k, v in values.items() if k not in drop and v is not None]
        opts.extend("sys_path=" + p for p in runtime_sys_path())
        return opts

    def runtime(self, options=None, **kw):
        rt, err = Runtime.init(self.lib, self.options() if options is None else options, **kw)
        assert rt is not None, err
        self.runtimes.append(rt)
        return rt

    def bundle(self, files):
        """Write the zip of {name: source} under code_root by its sha256;
        returns (hex, sha256 bytes)."""
        data = make_zip(files)
        digest = hashlib.sha256(data)
        with open(os.path.join(self.code_root, digest.hexdigest()), "wb") as f:
            f.write(data)
        return digest.hexdigest(), digest.digest()

    def bundle_spec(self, files, entry, **kw):
        hexd, raw = self.bundle(files)
        spec = Spec(entry, code=[(ROLE_BUNDLE, raw)], code_root=self.code_root, **kw)
        spec.hex = hexd
        return spec

    def leaked(self):
        """The zygotes and workers the trace names that are still running."""
        pids = self.trace.pids("spawn") + self.trace.pids("fork")
        return [pid for pid in pids if not process_gone(pid)]

    def close(self, check=False):
        for rt in self.runtimes:
            rt.shutdown()
        leaked = self.leaked() if check else []
        shutil.rmtree(self.dir, ignore_errors=True)
        assert not leaked, "processes of the runtime outlived its shutdown: %s" % leaked

    def __enter__(self):
        return self

    def __exit__(self, kind, *rest):
        # A case that already failed keeps its own error: a leak is reported after a pass only.
        self.close(check=self.check_leaks and kind is None)


# ---- the spec and the runtime ----------------------------------------------


class Spec:
    def __init__(self, entry, shape=SHAPE_SCALAR, form=FORM_BUNDLE,
                 args=(("x", pa.int64()),), result=pa.int64(), batch_format=VALUES,
                 null_mode=NULL_MANUAL, code=(), code_root=None, desc=None,
                 descriptor_version=1, result_field=None, args_field=None):
        self.entry, self.shape, self.form = entry, shape, form
        self.args, self.result = list(args), result
        self.null_mode = null_mode
        self.code, self.code_root = list(code), code_root
        self.descriptor_version = descriptor_version
        self.desc = desc if desc is not None else descriptor(entry, shape, batch_format)
        self.result_field = result_field
        self.args_field = args_field

    def copy(self, **kw):
        s = Spec.__new__(Spec)
        s.__dict__.update(self.__dict__)
        s.__dict__.update(kw)
        return s


class _CSpec:
    """The ctypes view of a Spec, alive for one call."""

    def __init__(self, spec):
        self.spec = spec
        self.schemas = []
        fields = spec.args_field or pa.field("args", pa.struct(
            [pa.field(n, t) for n, t in spec.args]))
        self.args = self._export(fields)
        self.result = self._export(spec.result_field or pa.field("result", spec.result))
        c = CSpec()
        c.struct_size = sizeof(CSpec)
        c.shape, c.form = spec.shape, spec.form
        self.entry = spec.entry.encode()
        c.entry = self.entry
        c.descriptor_version = spec.descriptor_version
        self.desc = (c_uint8 * len(spec.desc)).from_buffer_copy(spec.desc)
        c.descriptor = ctypes.cast(self.desc, POINTER(c_uint8)) if spec.desc else None
        c.descriptor_len = len(spec.desc)
        c.args, c.result = pointer_to(self.args), pointer_to(self.result)
        c.null_mode, c.stability = spec.null_mode, 1
        self.root = spec.code_root.encode() if spec.code_root else None
        c.code_root = self.root
        n = len(spec.code)
        c.n_code = n
        self.roles = (c_char_p * max(n, 1))(*[r.encode() for r, _ in spec.code])
        self.sha = (c_uint8 * 32 * max(n, 1))()
        for i, (_, raw) in enumerate(spec.code):
            ctypes.memmove(self.sha[i], raw, 32)
        c.code_roles = ctypes.cast(self.roles, POINTER(c_char_p)) if n else None
        c.code_sha256 = ctypes.cast(self.sha, POINTER(c_uint8 * 32)) if n else None
        if getattr(spec, "drop_digests", False):  # a host that breaks the ABI
            c.code_sha256 = None
        self.c = c

    def _export(self, field):
        s = CSchema()
        field._export_to_c(addressof(s))
        self.schemas.append(s)
        return s

    def release(self):
        for s in self.schemas:
            if s.release:
                pa.Field._import_from_c(addressof(s))


def pointer_to(obj):
    return ctypes.pointer(obj)


class Runtime:
    def __init__(self, table, rt, host_state):
        self.table, self.rt, self.state = table, rt, host_state
        self.live = True

    @staticmethod
    def init(lib_path, options, struct_size=None, abi_major=1, null_host=False):
        """(Runtime, None) or (None, Err)."""
        state = HostState()
        host = CHost()
        host.struct_size = sizeof(CHost) if struct_size is None else struct_size
        host.abi_major, host.abi_minor = abi_major, 0
        host.mem_reserve, host.mem_release = _MEM_RESERVE(state.reserve), _MEM_RELEASE(state.release)
        host.now_ns, host.log = _NOW_NS(state.now), _LOG(state.log)
        raw = (c_char_p * max(len(options), 1))(*[o.encode() for o in options])
        host.n_options = len(options)
        host.options = ctypes.cast(raw, c_void_p) if options else None
        state.keep = (host, raw)
        lib = ctypes.CDLL(lib_path)
        init = lib.komira_udf_runtime_init_v1
        init.restype = c_void_p
        init.argtypes = [c_void_p, POINTER(c_void_p), POINTER(CError)]
        rt, err = c_void_p(), _new_error()
        table = init(None if null_host else byref(host), byref(rt), byref(err))
        if not table:
            return None, Err(err)
        return Runtime(ctypes.cast(table, POINTER(CTable)).contents, rt, state), None

    def describe(self):
        c = CCaps()
        c.struct_size = sizeof(CCaps)
        assert self.table.describe(self.rt, byref(c)) == OK
        return {"runtime_id": c.runtime_id.decode(), "runtime_abi": c.runtime_abi.decode(),
                "max_descriptor_version": c.max_descriptor_version, "shapes": c.shapes,
                "devices": c.devices, "features": c.features, "udf_class": c.udf_class}

    def validate(self, spec):
        cs, err = _CSpec(spec), _new_error()
        try:
            status = self.table.validate(self.rt, byref(cs.c), byref(err))
        finally:
            cs.release()
        return status, (Err(err) if status != OK else None)

    def load(self, spec):
        """(status, Udf | None, Err | None)."""
        cs, err, out = _CSpec(spec), _new_error(), c_void_p()
        try:
            status = self.table.load(self.rt, byref(cs.c), byref(out), byref(err))
        finally:
            cs.release()
        if status != OK:
            assert not out.value, "a failed load returned a UDF"
            return status, None, Err(err)
        return status, Udf(self, out, spec), None

    def load_ok(self, spec):
        status, udf, err = self.load(spec)
        assert status == OK, err
        return udf

    def open_context(self, slot=0):
        err, out = _new_error(), c_void_p()
        status = self.table.open_context(self.rt, slot, byref(out), byref(err))
        if status != OK:
            return status, None, Err(err)
        return status, Context(self, out), None

    def open_context_ok(self, slot=0):
        status, ctx, err = self.open_context(slot)
        assert status == OK, err
        return ctx

    def shutdown(self):
        if self.live:
            self.live = False
            self.table.shutdown(self.rt)


class HostState:
    """What the host records and decides: the clock, the memory hook, the log."""

    def __init__(self):
        self.now_value = 0
        self.reserved = 0
        self.released = 0
        self.refuse_memory = False
        self.logs = []
        self.keep = None

    def now(self, _data):
        return self.now_value

    def reserve(self, _data, n):
        if self.refuse_memory:
            return ERR_OUT_OF_MEMORY
        self.reserved += n
        return OK

    def release(self, _data, n):
        self.released += n

    def log(self, _data, level, text):
        self.logs.append((level, text.decode() if text else ""))


class Udf:
    def __init__(self, rt, handle, spec):
        self.rt, self.handle, self.spec = rt, handle, spec

    def unload(self):
        self.rt.table.unload(self.handle)


class Context:
    def __init__(self, rt, handle):
        self.rt, self.handle = rt, handle

    def open_instance(self, udf):
        err, out = _new_error(), c_void_p()
        status = self.rt.table.open_instance(self.handle, udf.handle, byref(out), byref(err))
        if status != OK:
            return status, None, Err(err)
        return status, Instance(self.rt, out, udf.spec), None

    def open_instance_ok(self, udf):
        status, inst, err = self.open_instance(udf)
        assert status == OK, err
        return inst

    def close(self):
        self.rt.table.close_context(self.handle)


class Result:
    def __init__(self, status, err, array):
        self.status, self.err, self.array = status, err, array


class Instance:
    def __init__(self, rt, handle, spec):
        self.rt, self.handle, self.spec = rt, handle, spec
        self.next_call = 1
        self.cancel = c_int32(0)

    def call(self, columns, deadline_ns=0, cancel=0):
        """Call with one pyarrow Array per argument; a Result. The result array
        is imported (and so released with the Python object)."""
        names = [n for n, _ in self.spec.args]
        args = CDeviceArray()
        pa.StructArray.from_arrays(list(columns), names=names)._export_to_c(addressof(args))
        args.device_id, args.device_type = 0, 1
        return self.call_raw(args, deadline_ns, cancel)

    def call_raw(self, args, deadline_ns=0, cancel=0):
        """Call with the argument struct `args`, a CDeviceArray the caller built
        (HandArray.device_array() builds one by hand); a Result."""
        out, err = CDeviceArray(), _new_error()
        self.cancel.value = cancel
        c = CCall()
        c.struct_size = sizeof(CCall)
        c.deadline_ns, c.call_id = deadline_ns, self.next_call
        c.cancel = pointer_to(self.cancel)
        self.next_call += 1
        status = self.rt.table.call_batch(self.handle, byref(c), byref(args), byref(out), byref(err))
        assert not args.array.release, "args was not moved in (status %d)" % status
        if status != OK:
            assert not out.array.release, "a failed call returned an array"
            return Result(status, Err(err), None)
        arr = pa.Array._import_from_c(addressof(out.array), self.spec.result)
        return Result(status, None, arr)

    def call_ok(self, columns, **kw):
        r = self.call(columns, **kw)
        assert r.status == OK, r.err
        return r.array

    def close(self):
        self.rt.table.close_instance(self.handle)


class HandArray:
    """A C ArrowArray built field by field, for a call whose argument breaks the
    Arrow C data layout in a way pyarrow will not export. `buffers` holds one
    entry per buffer: bytes, or None for a NULL buffer. `children` are
    HandArrays. `released=True` gives the array a NULL release callback, as a
    child already released would have. Every buffer and child array stays
    alive as long as this object does."""

    def __init__(self, length, buffers, children=(), released=False, offset=0):
        self._bufs = [None if b is None else (c_uint8 * max(len(b), 1)).from_buffer_copy(b or b"\0")
                      for b in buffers]
        self._buffer_ptrs = (c_void_p * max(len(buffers), 1))(
            *[None if b is None else addressof(b) for b in self._bufs])
        self.children = list(children)
        self._child_ptrs = (c_void_p * max(len(self.children), 1))(
            *[addressof(c.c) for c in self.children])
        self._release = _RELEASE(_mark_released)
        self.c = CArray()
        self.c.length, self.c.null_count, self.c.offset = length, 0, offset
        self.c.n_buffers, self.c.n_children = len(buffers), len(self.children)
        self.c.buffers = addressof(self._buffer_ptrs)
        self.c.children = addressof(self._child_ptrs) if self.children else None
        self.c.dictionary = None
        self.c.release = None if released else ctypes.cast(self._release, c_void_p).value
        self.c.private_data = None

    def device_array(self):
        """A CPU CDeviceArray whose array is a copy of this one's fields."""
        dev = CDeviceArray()
        dev.array = self.c
        dev.device_id, dev.device_type = 0, 1
        # The copy points at this object's buffers, child pointers and release
        # callback: it keeps this object alive for as long as it lives.
        dev._owner = self
        return dev
