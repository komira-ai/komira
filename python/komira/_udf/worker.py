"""The worker: the loop that runs in a process the zygote forked, serving one context.

`serve` never returns; it ends the process. The protocol is only on the worker's socket:
user code's stdout and stderr go to the inherited descriptors 1 and 2.
"""

import dataclasses
import datetime
import decimal
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
    elif sys.platform == "darwin":
        _end_with_the_zygote(zygote_pid)
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


def _end_with_the_zygote(zygote_pid):
    """macOS, which has no PR_SET_PDEATHSIG: one thread that ends this worker when the
    zygote ends, waiting on a kqueue EVFILT_PROC NOTE_EXIT filter for its pid. The parent
    is checked once the filter is registered, so an end before that is seen too; a
    registration refused with ESRCH is a zygote already gone."""
    import select
    import threading

    kq = select.kqueue()
    try:
        kq.control([select.kevent(zygote_pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT)], 0, 0)
    except ProcessLookupError:
        os._exit(0)
    if os.getppid() != zygote_pid:
        os._exit(0)

    def watch():
        kq.control(None, 1)
        os._exit(0)

    threading.Thread(target=watch, name="komira-udf-zygote-watch", daemon=True).start()


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


_EPOCH = datetime.datetime(1970, 1, 1)
_MICROSECOND = datetime.timedelta(microseconds=1)
_MICROS_PER_TICK = {"s": 1000000, "ms": 1000, "us": 1}
_FLOAT_CODES = {16: "e", 32: "f"}


class _Mismatch(Exception):
    """A value is not an exact member of a type: `path` is where in the value, `reason` says why if not by its type."""

    def __init__(self, path, value, reason=None):
        super().__init__(path)
        self.path = path
        self.value = value
        self.reason = reason

    def detail(self):
        if self.reason:
            return "%s: %s" % (self.path, self.reason) if self.path else self.reason
        if self.path:
            return "%s is %s %r" % (self.path, type(self.value).__name__, self.value)
        return ""


def _float_exact(value, bits):
    """Whether the float `value` is the same number at `bits` bits of precision (NaN and infinities are)."""
    code = _FLOAT_CODES.get(bits)
    if code is None:
        return True
    try:
        back = struct.unpack(code, struct.pack(code, value))[0]
    except OverflowError:
        return False
    return back == value or value != value


def _timestamp_ticks(value, t, path):
    """The instant of the datetime `value` in the unit of the timestamp type `t`, by integer arithmetic."""
    offset = value.utcoffset()
    if (offset is not None) != (t.tz is not None):
        raise _Mismatch(path, value)
    delta = value.replace(tzinfo=None) - _EPOCH
    if offset is not None:
        delta -= offset
    micros = delta // _MICROSECOND
    if t.unit == "ns":
        ticks = micros * 1000
    else:
        per = _MICROS_PER_TICK[t.unit]
        if micros % per:
            raise _Mismatch(path, value)
        ticks = micros // per
    if not -(1 << 63) <= ticks < (1 << 63):
        raise _Mismatch(path, value)
    return ticks


def _decimal_exact(value, t, path):
    """The decimal `value` as a Decimal with exactly the scale of the decimal128 type `t`, by integer arithmetic."""
    precision, scale = t.precision, t.scale
    if isinstance(value, int):
        if abs(value) >= 10 ** (precision - scale):
            raise _Mismatch(path, value)
        unscaled = abs(value) * 10**scale
        negative = value < 0
    else:
        if not value.is_finite():
            raise _Mismatch(path, value)
        sign, digits, exponent = value.as_tuple()
        start = 0
        while start < len(digits) and digits[start] == 0:
            start += 1
        digits = digits[start:]
        shift = exponent + scale
        if shift < 0:
            drop = -shift
            if drop >= len(digits):
                if digits:
                    raise _Mismatch(path, value)
            elif any(digits[-drop:]):
                raise _Mismatch(path, value)
            else:
                digits = digits[:-drop]
            shift = 0
        if len(digits) + (shift if digits else 0) > precision:
            raise _Mismatch(path, value)
        unscaled = int("".join(map(str, digits))) * 10**shift if digits else 0
        negative = sign == 1
    exact = tuple(int(c) for c in str(unscaled))
    return decimal.Decimal((1 if negative and unscaled else 0, exact, -scale))


def _convert(value, t, path, types):
    """Return `value` as an exact member of the Arrow type `t` in the form `pa.array` takes, else raise _Mismatch."""
    if value is None:
        return None
    if types.is_boolean(t):
        if not isinstance(value, bool):
            raise _Mismatch(path, value)
        return value
    if types.is_integer(t):
        if isinstance(value, bool) or not isinstance(value, int):
            raise _Mismatch(path, value)
        bits = t.bit_width
        low = -(1 << (bits - 1)) if types.is_signed_integer(t) else 0
        if not low <= value < low + (1 << bits):
            raise _Mismatch(path, value)
        return value
    if types.is_floating(t):
        if isinstance(value, bool):
            raise _Mismatch(path, value)
        if isinstance(value, float):
            if not _float_exact(value, t.bit_width):
                raise _Mismatch(path, value)
            return value
        if isinstance(value, int):
            try:
                ok = float(value) == value and int(float(value)) == value
            except OverflowError:
                ok = False
            if ok and _float_exact(float(value), t.bit_width):
                return float(value)
        raise _Mismatch(path, value)
    if types.is_string(t) or types.is_large_string(t):
        if not isinstance(value, str):
            raise _Mismatch(path, value)
        try:
            value.encode("utf-8")
        except UnicodeEncodeError:
            raise _Mismatch(path, value) from None
        return value
    if types.is_binary(t) or types.is_large_binary(t):
        if not isinstance(value, (bytes, bytearray, memoryview)):
            raise _Mismatch(path, value)
        return bytes(value)
    if types.is_date32(t):
        if not isinstance(value, datetime.date) or isinstance(value, datetime.datetime):
            raise _Mismatch(path, value)
        return value
    if types.is_timestamp(t):
        if not isinstance(value, datetime.datetime):
            raise _Mismatch(path, value)
        return _timestamp_ticks(value, t, path)
    if types.is_decimal128(t):
        if isinstance(value, bool) or not isinstance(value, (decimal.Decimal, int)):
            raise _Mismatch(path, value)
        return _decimal_exact(value, t, path)
    if types.is_list(t) or types.is_large_list(t):
        if not isinstance(value, (list, tuple)):
            raise _Mismatch(path, value)
        item = t.value_type
        return [_convert(v, item, "%s[%d]" % (path, i), types) for i, v in enumerate(value)]
    if types.is_struct(t):
        return _convert_struct(value, t, path, types)
    raise _Mismatch(path, value)


def _convert_struct(value, t, path, types):
    """The dict of the dict or dataclass instance `value` for the struct type `t`; its keys are exactly the fields."""
    if isinstance(value, dict):
        given = value
    elif dataclasses.is_dataclass(value) and not isinstance(value, type):
        given = {f.name: getattr(value, f.name) for f in dataclasses.fields(value)}
    else:
        raise _Mismatch(path, value)
    fields = [t[i] for i in range(t.num_fields)]
    names = [f.name for f in fields]
    for name in names:
        if name not in given:
            raise _Mismatch(path, value, "the field %r is missing" % (name,))
    for key in given:
        if key not in names:
            raise _Mismatch(path, value, "the key %r is not a field" % (key,))
    return {f.name: _convert(given[f.name], f.type, "%s[%r]" % (path, f.name), types) for f in fields}


def _check_value(value, rtype, row):
    """Return `value` as an exact member of `rtype` (or None), else raise ERR_RETURN_TYPE."""
    import pyarrow as pa

    try:
        return _convert(value, rtype, "", pa.types)
    except _Mismatch as m:
        message = "row %d returned %s %r, which is not %s without loss" % (row, type(value).__name__, value, rtype)
        detail = m.detail()
        if detail:
            message += ": " + detail
        raise _Fail(wire.ERR_RETURN_TYPE, message, row) from None


def _unholdable_leaf(array, types):
    """The type of the first date32 or timestamp array inside `array` (itself included) that Python cannot hold."""
    t = array.type
    if types.is_date32(t) or types.is_timestamp(t):
        try:
            array.to_pylist()
        except (ValueError, OverflowError):
            return t
        return None
    if types.is_struct(t):
        inner = array.flatten()
    elif types.is_list(t) or types.is_large_list(t):
        inner = [array.flatten()]
    else:
        return None
    for child in inner:
        found = _unholdable_leaf(child, types)
        if found is not None:
            return found
    return None


def _column_values(batch):
    """Every argument column as Python lists. A date or timestamp that a `datetime.date` or `datetime.datetime`
    cannot hold (before year 1 or past year 9999) ends the call with ERR_UNSUPPORTED naming the row and the argument."""
    import pyarrow as pa

    columns = []
    for position, column in enumerate(batch.columns):
        try:
            columns.append(column.to_pylist())
            continue
        except (ValueError, OverflowError):
            # The first row that fails, then the leaf inside that row alone:
            # the message names a row and a type that belong together.
            row, leaf = None, None
            for i in range(len(column)):
                try:
                    column[i].as_py()
                except (ValueError, OverflowError):
                    row, leaf = i, _unholdable_leaf(column.slice(i, 1), pa.types)
                    break
            if leaf is None:
                raise
        python_type = "datetime.date" if pa.types.is_date32(leaf) else "datetime.datetime"
        message = "row %d of argument '%s' holds a %s outside the years 1 to 9999, which %s cannot hold" % (
            row,
            batch.schema.field(position).name,
            leaf,
            python_type,
        )
        raise _Fail(wire.ERR_UNSUPPORTED, message, row)
    return columns


def _run_values(fn, batch, rtype, cancel, call_id):
    import pyarrow as pa

    columns = _column_values(batch)
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
    try:
        return pa.array(out, type=rtype)
    except (pa.ArrowInvalid, pa.ArrowTypeError, OverflowError) as e:
        raise _Fail(wire.ERR_RETURN_TYPE, "the returned values do not fit %s: %s" % (rtype, e)) from None


def _cast_stays_in_a_family(src, dst, types):
    """Whether an Arrow type `src` may be cast to `dst` without changing what kind of value it holds: integer to
    integer or float, float to float, string or binary to its large form (and back), timestamp to a timestamp of
    the same time zone, decimal to decimal, date32 to date32, bool to bool, and a list or struct whose items or
    fields (same names, same order) pass the same rule."""
    if types.is_integer(src):
        return types.is_integer(dst) or types.is_floating(dst)
    if types.is_floating(src):
        return types.is_floating(dst)
    if types.is_string(src) or types.is_large_string(src):
        return types.is_string(dst) or types.is_large_string(dst)
    if types.is_binary(src) or types.is_large_binary(src):
        return types.is_binary(dst) or types.is_large_binary(dst)
    if types.is_timestamp(src):
        return types.is_timestamp(dst) and src.tz == dst.tz
    if types.is_decimal128(src):
        return types.is_decimal128(dst)
    if types.is_date32(src):
        return types.is_date32(dst)
    if types.is_boolean(src):
        return types.is_boolean(dst)
    if types.is_list(src) or types.is_large_list(src):
        return (types.is_list(dst) or types.is_large_list(dst)) and _cast_stays_in_a_family(
            src.value_type, dst.value_type, types
        )
    if types.is_struct(src):
        if not types.is_struct(dst) or src.num_fields != dst.num_fields:
            return False
        return all(
            src[i].name == dst[i].name and _cast_stays_in_a_family(src[i].type, dst[i].type, types)
            for i in range(src.num_fields)
        )
    return False


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
        if not _cast_stays_in_a_family(result.type, rtype, pa.types):
            raise lossy
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
                reply = struct.pack("<I", len(instances))
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
