"""The worker: the loop that runs in a process the zygote forked, serving one context.

`serve` never returns; it ends the process. The protocol is only on the worker's socket:
user code's stdout and stderr go to the inherited descriptors 1 and 2.
"""

import mmap
import os
import signal
import socket
import struct
import sys
import tempfile
import traceback

_wire = sys.modules.get("_komira_udf_wire")
if _wire is None:
    import importlib.util as _ilu

    _spec = _ilu.spec_from_file_location(
        "_komira_udf_wire", os.path.join(os.path.dirname(os.path.abspath(__file__)), "wire.py")
    )
    _wire = _ilu.module_from_spec(_spec)
    sys.modules["_komira_udf_wire"] = _wire
    _spec.loader.exec_module(_wire)
wire = _wire

_HERE = os.path.dirname(os.path.abspath(__file__)) + os.sep
_PR_SET_PDEATHSIG = 1


class _Fail(Exception):
    """A call ends with this ERROR reply."""

    def __init__(self, code, message, row=-1, trace=""):
        super().__init__(message)
        self.code = code
        self.message = message
        self.row = row
        self.trace = trace


def _trimmed_traceback(exc):
    """The formatted traceback of `exc`, with the frames of this package removed."""
    frames = [f for f in traceback.extract_tb(exc.__traceback__) if not os.path.abspath(f.filename).startswith(_HERE)]
    lines = []
    if frames:
        lines.append("Traceback (most recent call last):\n")
        lines.extend(traceback.format_list(frames))
    lines.extend(traceback.format_exception_only(type(exc), exc))
    return "".join(lines)


def _raised(exc, row):
    name = type(exc).__name__
    text = str(exc)
    message = "%s: %s" % (name, text) if text else name
    return _Fail(wire.ERR_RAISED, message, row, _trimmed_traceback(exc))


def _setup(sock_fd, cancel_fd, ctl_sock, wakeup_fds, zygote_pid, scratch):
    """Post-fork setup in the child; returns (socket, cancel-word mmap)."""
    for fd in wakeup_fds:
        try:
            os.close(fd)
        except OSError:
            pass
    try:
        ctl_sock.close()
    except OSError:
        pass
    signal.set_wakeup_fd(-1)
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    if sys.platform.startswith("linux"):
        import ctypes

        libc = ctypes.CDLL(None, use_errno=True)
        libc.prctl(_PR_SET_PDEATHSIG, int(signal.SIGKILL), 0, 0, 0)
        if os.getppid() != zygote_pid:
            os._exit(0)
    root = tempfile.mkdtemp(dir=scratch, prefix="worker-")
    for sub in ("home", "tmp", "cwd"):
        os.mkdir(os.path.join(root, sub), 0o700)
    os.chdir(os.path.join(root, "cwd"))
    os.environ["HOME"] = os.path.join(root, "home")
    os.environ["TMPDIR"] = os.path.join(root, "tmp")
    tempfile.tempdir = None
    import pyarrow

    pyarrow.set_cpu_count(1)
    sock = socket.socket(fileno=sock_fd)
    cancel = mmap.mmap(cancel_fd, 8, mmap.MAP_SHARED, mmap.PROT_READ)
    os.close(cancel_fd)
    return sock, cancel


def _decode_schemas(entry):
    """The (args schema, result type) of a registry entry, decoded once per worker."""
    cached = entry.get("decoded")
    if cached is None:
        import pyarrow as pa

        def read(raw):
            buf = pa.py_buffer(raw)
            try:
                return pa.ipc.read_schema(buf)
            except Exception:
                return pa.ipc.read_schema(pa.ipc.read_message(buf))

        args = read(entry["schema_args"])
        result = read(entry["schema_result"]).field(0).type
        cached = entry["decoded"] = (args, result)
    return cached


def _check_value(value, rtype, row):
    """Return `value` as an exact member of `rtype` (or None), else raise ERR_RETURN_TYPE."""
    import pyarrow as pa

    def bad():
        return _Fail(
            wire.ERR_RETURN_TYPE,
            "row %d returned %s %r, which is not %s without loss" % (row, type(value).__name__, value, rtype),
            row,
        )

    if value is None:
        return None
    if pa.types.is_floating(rtype):
        if isinstance(value, bool):
            raise bad()
        if isinstance(value, float):
            return value
        if isinstance(value, int):
            try:
                ok = float(value) == value and int(float(value)) == value
            except OverflowError:
                ok = False
            if ok:
                return float(value)
        raise bad()
    if isinstance(value, bool) or not isinstance(value, int):
        raise bad()
    bits = rtype.bit_width
    if not -(1 << (bits - 1)) <= value < (1 << (bits - 1)):
        raise bad()
    return value


def _run_values(fn, batch, rtype, cancel, call_id):
    import pyarrow as pa

    columns = [c.to_pylist() for c in batch.columns]
    out = []
    for i in range(batch.num_rows):
        if call_id != 0 and struct.unpack_from("<q", cancel, 0)[0] == call_id:
            raise _Fail(wire.ERR_CANCELLED, "cancelled at row %d" % i, i)
        try:
            value = fn(*[c[i] for c in columns])
        except MemoryError:
            raise
        except BaseException as e:  # user code may raise anything, SystemExit included
            raise _raised(e, i) from None
        out.append(_check_value(value, rtype, i))
    return pa.array(out, type=rtype)


def _run_arrow(fn, batch, rtype):
    import pyarrow as pa
    import pyarrow.compute as pc

    try:
        result = fn(*batch.columns)
    except MemoryError:
        raise
    except BaseException as e:  # user code may raise anything, SystemExit included
        raise _raised(e, -1) from None
    if isinstance(result, pa.ChunkedArray):
        result = result.combine_chunks()
    if not isinstance(result, pa.Array):
        raise _Fail(wire.ERR_RETURN_TYPE, "returned %s, not a pyarrow Array" % type(result).__name__)
    if result.type != rtype:
        lossy = _Fail(wire.ERR_RETURN_TYPE, "returned %s, which is not %s without loss" % (result.type, rtype))
        try:
            cast = pc.cast(result, rtype, safe=True)
            back = pc.cast(cast, result.type, safe=True)
        except (pa.ArrowInvalid, pa.ArrowNotImplementedError, pa.ArrowTypeError):
            raise lossy from None
        if not back.equals(result):
            raise lossy
        result = cast
    if len(result) != batch.num_rows:
        raise _Fail(wire.ERR_LENGTH, "returned %d values for %d rows" % (len(result), batch.num_rows))
    return result


def _call_batch(instance, body, call_id, cancel):
    import pyarrow as pa

    entry = instance["entry"]
    args_schema, rtype = _decode_schemas(entry)
    batch = pa.ipc.read_record_batch(pa.py_buffer(body), args_schema)
    fn = entry["fn"]
    if entry["shape"] == wire.SHAPE_SCALAR and entry["batch_format"] == wire.FORMAT_VALUES:
        result = _run_values(fn, batch, rtype, cancel, call_id)
    else:
        result = _run_arrow(fn, batch, rtype)
    out = pa.RecordBatch.from_arrays([result], names=["result"])
    return out.serialize().to_pybytes()


def serve(sock_fd, cancel_fd, ctl_sock, wakeup_fds, zygote_pid, scratch, registry):
    """Run the worker loop in the forked child; ends the process, never returns."""
    try:
        sock, cancel = _setup(sock_fd, cancel_fd, ctl_sock, wakeup_fds, zygote_pid, scratch)
    except BaseException:
        traceback.print_exc()
        os._exit(1)
    instances = {}
    next_instance = 1
    while True:
        try:
            msg = wire.recv_message(sock)
        except (wire.WireError, OSError):
            msg = None
        if msg is None:
            _leave(0)
        for fd in msg.fds:
            os.close(fd)
        try:
            handle, _deadline, call_id, body = wire.split_request(msg.payload)
            if msg.op == wire.OP_OPEN_INSTANCE:
                entry = registry.get(handle)
                if entry is None:
                    raise _Fail(wire.ERR_INTERNAL, "udf %d is not in this worker's registry" % handle)
                instances[next_instance] = {"entry": entry}
                reply = struct.pack("<Q", next_instance)
                next_instance += 1
            elif msg.op == wire.OP_CLOSE_INSTANCE:
                instances.pop(handle, None)
                reply = b""
            elif msg.op == wire.OP_CALL_BATCH:
                instance = instances.get(handle)
                if instance is None:
                    raise _Fail(wire.ERR_INTERNAL, "instance %d is not open" % handle)
                reply = _call_batch(instance, body, call_id, cancel)
            else:
                raise _Fail(wire.ERR_INTERNAL, "unexpected op %d on a worker channel" % msg.op)
            wire.send_ok(sock, msg.request_id, reply)
        except _Fail as f:
            _send_error(sock, msg.request_id, f.code, f.message, f.row, f.trace)
        except MemoryError:
            _send_error(sock, msg.request_id, wire.ERR_OUT_OF_MEMORY, "MemoryError", -1, "")
            _leave(1)
        except OSError:
            _leave(1)
        except BaseException as e:
            _send_error(
                sock,
                msg.request_id,
                wire.ERR_INTERNAL,
                "%s: %s" % (type(e).__name__, e),
                -1,
                "".join(traceback.format_exception(type(e), e, e.__traceback__)),
            )


def _send_error(sock, request_id, code, message, row, trace):
    try:
        wire.send_error(sock, request_id, code, message, row, -1, trace)
    except OSError:
        _leave(1)


def _leave(status):
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except Exception:
            pass
    os._exit(status)
