"""komira-test/python-worker: the Python UDF runtime as a worker process.

The engine reaches this process only through its proxy runtime
(native/proxy_runtime.c), which turns each entry of the UDF runtime C ABI
into one message of the worker protocol (docs/design/udf_runtime_interface.md
section 5.2; the header is komira_udf_wire.h). One process serves one engine
thread: one context, one interpreter, one GIL.

    python3.13 -I -S -B komira_udf_pyworker.py --role R --dir D --codec C

  --role control  answers DESCRIBE, VALIDATE and LOAD (a LOAD here checks the
                  spec and the code's digest; it runs no user code)
  --role zygote   the same, but LOAD imports or deserializes the UDF, and FORK
                  forks a context worker that inherits it
  --role context  serves one context: LOAD, OPEN_*, CALL_BATCH, CLOSE_*
  --dir D         the runtime directory: python/, pyrt/ (the adapter of the
                  in-process runtime, komira_udf_pyrt.py, and the fixture
                  modules), pyworker/, native/lib/ (libraries loaded before any
                  extension module), site/<wheel>
  --codec own     Arrow IPC read and written by kudf_ipc.py
  --codec pyarrow Arrow IPC read and written by pyarrow

The control socket is fd 3. HELLO brings the shared region (a memfd, with
SCM_RIGHTS) unless the engine runs the pipe transport. User code runs through
the in-process runtime's adapter (komira_udf_pyrt.Instance), so the same
type-hint rules and per-row and numpy readers serve both transports.
"""

import ctypes
import hashlib
import mmap
import os
import resource
import signal
import socket
import struct
import sys
import time
import traceback
import warnings

HEADER = struct.Struct("<IIQIIQQ")
MAGIC = 0x4644554B
WIRE_VERSION = 1
INLINE = 1
OP = dict(HELLO=1, DESCRIBE=2, VALIDATE=3, LOAD=4, UNLOAD=5, OPEN_CONTEXT=6, CLOSE_CONTEXT=7, OPEN_INSTANCE=8,
          CLOSE_INSTANCE=9, CALL_BATCH=10, CANCEL=21, SHUTDOWN=22, OK=128, ERROR=129, FORK=64, CLOCK=65)

OK, ERR_ABI, ERR_DESCRIPTOR, ERR_UNSUPPORTED, ERR_CODE_DIGEST, ERR_LOAD = 0, 1, 2, 3, 4, 5
ERR_RETURN_TYPE, ERR_INTERNAL = 7, 15
SHAPE_SCALAR, SHAPE_MAP_BATCHES_COLUMN = 1, 4
FORM_PACKAGE, FORM_BUNDLE, FORM_VALUE = 1, 2, 3
CALL_HEAD = 64
WIDTH = {"l": 8, "g": 8}

# The control page (pyw.h).
CTRL_BYTES = 4096
W_CLOCK, W_CANCEL, W_HEAD = 16 // 4, 32 // 4, 64 // 4
W_RING, RING_SLOTS = 256 // 4, 256

CAPS = ("komira-test/python-worker", "cp313",
        # max_descriptor_version, shapes, threading (SINGLE_THREAD),
        # thread_affine, transports (WORKER), hosting (EMBEDDED), devices
        # (CPU), features, udf_class (MANAGED), global_lock
        (0, SHAPE_SCALAR | SHAPE_MAP_BATCHES_COLUMN, 3, 1, 2, 1, 1, 0, 2, 1))


class Refused(Exception):
    """A request refused with a status."""

    def __init__(self, code, message, trace=None, row=-1):
        super().__init__(message)
        self.code, self.message, self.trace, self.row = code, message, trace, row


def _s(b):
    """A control-body string: u32 length (0xFFFFFFFF for None), UTF-8."""
    if b is None:
        return struct.pack("<I", 0xFFFFFFFF)
    if isinstance(b, str):
        b = b.encode("utf-8", "replace")
    return struct.pack("<I", len(b)) + b


class _Body:
    """A bounded reader over a request's control body."""

    def __init__(self, buf):
        self.b, self.at = buf, 0

    def take(self, fmt):
        v = struct.unpack_from(fmt, self.b, self.at)
        self.at += struct.calcsize(fmt)
        return v if len(v) > 1 else v[0]

    def bytes(self, n):
        if self.at + n > len(self.b):
            raise Refused(ERR_INTERNAL, "a truncated control body")
        v = bytes(self.b[self.at : self.at + n])
        self.at += n
        return v

    def str(self):
        n = self.take("<I")
        return None if n == 0xFFFFFFFF else self.bytes(n).decode("utf-8")


class SlotBuffer:
    """One engine-to-worker slot as a buffer exporter (PEP 688). The slot is
    freed (its id pushed onto the release ring) once the call is over and the
    last view of it is gone, so a view user code keeps holds the slot."""

    __slots__ = ("w", "slot", "view", "exports", "done")

    def __init__(self, w, slot, view):
        self.w, self.slot, self.view, self.exports, self.done = w, slot, view, 0, False

    def __buffer__(self, flags):
        self.exports += 1
        return self.view

    def __release_buffer__(self, view):
        self.exports -= 1
        if self.done and self.exports == 0:
            self.w.free_slot(self.slot)

    def finish(self):
        self.done = True
        if self.exports == 0:
            self.w.free_slot(self.slot)


class Loaded:
    """A loaded UDF: the bound types and, where user code was loaded, the
    adapter's Instance."""

    def __init__(self, spec, inst):
        self.spec, self.inst = spec, inst


class Worker:
    def __init__(self, role, rtdir, codec):
        self.role, self.dir, self.codec = role, rtdir, codec
        self.sock = socket.socket(fileno=3)
        self.mm = None
        self.ctrl = None
        self.ids = 0
        self.udfs, self.contexts, self.instances = {}, {}, {}
        self.req = 0
        self.local_cancel = memoryview(bytearray(4))
        import kudf_ipc
        import komira_udf_pyrt

        self.ipc, self.ad = kudf_ipc, komira_udf_pyrt
        self.writer = kudf_ipc.BatchWriter()
        self.pa = None
        if codec == "pyarrow":
            import pyarrow

            self.pa = pyarrow

    # ---- the socket -----------------------------------------------------------

    def recv_exact(self, n):
        buf = bytearray(n)
        view = memoryview(buf)
        got = 0
        while got < n:
            r = self.sock.recv_into(view[got:], n - got)
            if r == 0:
                os._exit(0)  # the engine closed the channel: this worker is done
            got += r
        return buf

    def recv_header(self, with_fds):
        fds = []
        if with_fds:
            data, anc, _, _ = self.sock.recvmsg(HEADER.size, socket.CMSG_SPACE(16))
            for level, kind, cdata in anc:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    fds += list(struct.unpack("<{}i".format(len(cdata) // 4), cdata[: len(cdata) // 4 * 4]))
            if len(data) == 0:
                os._exit(0)
            data = bytes(data) + bytes(self.recv_exact(HEADER.size - len(data)) if len(data) < HEADER.size else b"")
        else:
            data = self.recv_exact(HEADER.size)
        h = HEADER.unpack(data)
        if h[0] != MAGIC:
            raise SystemExit("komira_udf_pyworker: a message without the protocol's magic")
        return h, fds

    def send(self, op, req, body=b"", in_heap=0, service_ns=0):
        """A reply: `body` inline, or (in_heap > 0) `in_heap` bytes the caller
        wrote at the start of the worker-to-engine heap. `service_ns` (the
        time since the request was read, for the engine's measurements) rides
        in the header's slot field, which a reply does not otherwise use."""
        slot = min(service_ns, 0xFFFFFFFF)
        if in_heap:
            self.sock.sendall(HEADER.pack(MAGIC, op, req, 0, slot, 0, in_heap))
        else:
            self.sock.sendall(HEADER.pack(MAGIC, op, req, INLINE if body else 0, slot, 0, len(body)) + bytes(body))

    def send_error(self, req, code, message, trace=None, row=-1):
        self.send(OP["ERROR"], req, struct.pack("<iqq", code, row, -1) + _s(message) + _s(trace))

    # ---- the shared region -----------------------------------------------------

    def free_slot(self, slot):
        if self.ctrl is None:
            return
        head = self.ctrl[W_HEAD]
        self.ctrl[W_RING + head % RING_SLOTS] = slot
        self.ctrl[W_HEAD] = (head + 1) & 0xFFFFFFFF

    def now_shm(self):
        self.ctrl[W_CLOCK] = (self.ctrl[W_CLOCK] + 1) & 0xFFFFFFFF
        return time.monotonic_ns()

    def now_pipe(self):
        """The pipe transport's clock read: tells the engine (CLOCK)."""
        self.sock.sendall(HEADER.pack(MAGIC, OP["CLOCK"], self.req, 0, 0, 0, 0))
        return time.monotonic_ns()

    def on_cancel_signal(self, signum, frame):
        """The pipe transport's cancel: the engine sends SIGUSR1 while a call
        runs (the CANCEL message waits on the socket until the call ends)."""
        self.local_cancel.cast("i")[0] = 1

    # ---- requests ----------------------------------------------------------------

    def hello(self, body, fds):
        b = _Body(body)
        version, major, _minor, flags, shm_bytes, heap_bytes = b.take("<IIIIQQ")
        if version != WIRE_VERSION or major != 1:
            raise Refused(ERR_ABI, "HELLO: wire {} ABI {}; this worker speaks wire 1, ABI 1".format(version, major))
        if self.mm is not None:
            self.mm.close()
            self.mm = self.ctrl = None
        if flags & 1:
            if not fds:
                raise Refused(ERR_INTERNAL, "HELLO: shared memory without its file")
            self.mm = mmap.mmap(fds[0], shm_bytes)
            os.close(fds[0])
            self.heap = heap_bytes
            mv = memoryview(self.mm)
            self.ctrl = mv[:CTRL_BYTES].cast("I")
            self.e2w = mv[CTRL_BYTES : CTRL_BYTES + heap_bytes]
            self.w2e = mv[CTRL_BYTES + heap_bytes : CTRL_BYTES + 2 * heap_bytes]
            self.cancel_view = mv[32:36]
            self.now = self.now_shm
        else:
            self.cancel_view = self.local_cancel
            self.now = self.now_pipe
            signal.signal(signal.SIGUSR1, self.on_cancel_signal)
        return struct.pack("<Ii", WIRE_VERSION, os.getpid())

    def describe(self):
        return _s(CAPS[0]) + _s(CAPS[1]) + struct.pack("<10I", *CAPS[2])

    def read_spec(self, body):
        b = _Body(body)
        s = {}
        s["shape"], s["form"], s["null_mode"], s["stability"], s["descriptor_version"] = b.take("<iiiiI")
        s["entry"] = b.str()
        s["descriptor"] = b.bytes(b.take("<I"))
        s["code_root"] = b.str()
        s["code"] = [(b.str(), b.bytes(32)) for _ in range(b.take("<I"))]
        b.at = (b.at + 7) // 8 * 8
        try:
            if self.pa is not None:
                s["args"], s["result"] = self.pa_schemas(body, b.at)
            else:
                s["args"], used = self.ipc.read_schema(body, b.at, len(body) - b.at)
                s["result"], _ = self.ipc.read_schema(body, b.at + used, len(body) - b.at - used)
        except Exception as exc:
            raise Refused(ERR_INTERNAL, "the spec's schemas: {}".format(exc))
        return s

    def pa_schemas(self, body, at):
        pa = self.pa
        out = []
        stream = pa.BufferReader(pa.py_buffer(bytes(body[at:])))
        for _ in range(2):
            msg = pa.ipc.read_message(stream)
            schema = pa.ipc.read_schema(msg)
            fmts = []
            for f in schema:
                t = f.type
                fmt = "l" if t == pa.int64() else "g" if t == pa.float64() else "?" + str(t)
                fmts.append((f.name, fmt, f.nullable))
            out.append(fmts)
        return out[0], out[1]

    def check_spec(self, s):
        """The checks that need no user code (python_runtime.c check_spec, with
        VALUE added): form, entry grammar, descriptor, code objects, shape and
        the types the adapter maps."""
        form = s["form"]
        if form not in (FORM_PACKAGE, FORM_BUNDLE, FORM_VALUE):
            raise Refused(ERR_DESCRIPTOR, "code form is not PACKAGE, BUNDLE or VALUE")
        entry = s["entry"] or ""
        if form != FORM_VALUE:
            mod, colon, fn = entry.partition(":")
            if not mod or not colon or not fn or ":" in fn:
                raise Refused(ERR_DESCRIPTOR, "entry is not <module>:<function>")
        if s["descriptor_version"] > 0:
            raise Refused(ERR_DESCRIPTOR, "descriptor_version is newer than 0, the newest read here")
        if s["descriptor"]:
            raise Refused(ERR_DESCRIPTOR, "descriptor version 0 is empty; these bytes are not canonical")
        if form == FORM_VALUE:
            if len(s["code"]) != 1 or s["code"][0][0] != "payload":
                raise Refused(ERR_DESCRIPTOR, "a VALUE needs exactly one code object, role payload")
        elif s["code"]:
            raise Refused(ERR_UNSUPPORTED, "code objects are read only for VALUE (spike)")
        if s["shape"] not in (SHAPE_SCALAR, SHAPE_MAP_BATCHES_COLUMN):
            raise Refused(ERR_UNSUPPORTED, "shape is not SCALAR or MAP_BATCHES_COLUMN")
        if len(s["args"]) > 8 or any(f[1] not in WIDTH for f in s["args"]):
            raise Refused(ERR_UNSUPPORTED, "an argument type is not int64 or float64")
        if len(s["result"]) != 1 or s["result"][0][1] not in WIDTH:
            raise Refused(ERR_UNSUPPORTED, "the result type is not int64 or float64")
        s["arg_fmts"] = "".join(f[1] for f in s["args"])
        s["result_fmt"] = s["result"][0][1]

    def payload(self, s):
        """The VALUE's code object, checked against its sha256."""
        role, sha = s["code"][0]
        path = os.path.join(s["code_root"] or "", sha.hex())
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError as exc:
            raise Refused(ERR_LOAD, "code object {} ({}): {}".format(role, sha.hex(), exc))
        if hashlib.sha256(data).digest() != sha:
            raise Refused(ERR_CODE_DIGEST, "code object {}: its bytes do not match sha256 {}".format(role, sha.hex()))
        return data

    def validate(self, s):
        self.check_spec(s)
        if s["form"] != FORM_VALUE:
            code, msg = self.ad.validate(s["entry"], s["shape"], s["arg_fmts"], s["result_fmt"])
            if code != OK:
                raise Refused(code, msg)

    def load(self, body):
        s = self.read_spec(body)
        self.validate(s)
        inst = None
        if self.role == "control":
            if s["form"] == FORM_VALUE:
                self.payload(s)  # the digest, checked; deserializing would run user code
        else:
            inst = self.load_code(s)
        self.ids += 1
        self.udfs[self.ids] = Loaded(s, inst)
        return struct.pack("<q", self.ids)

    def load_code(self, s):
        """Imports or deserializes the UDF and binds it (the adapter's rules)."""
        ad = self.ad
        if s["form"] != FORM_VALUE:
            code, second = ad.open_instance(s["entry"], s["shape"], s["arg_fmts"], s["result_fmt"], s["null_mode"])
            if code != OK:
                raise Refused(code, second)
            return second
        data = self.payload(s)
        try:
            import cloudpickle

            f = cloudpickle.loads(data)
        except BaseException as exc:
            raise Refused(ERR_LOAD, "deserializing the VALUE: {}".format(ad._exception_text(exc)))
        if not callable(f):
            raise Refused(ERR_LOAD, "the VALUE is a {}, not a function".format(type(f).__name__))
        import inspect
        import typing

        name = getattr(f, "__qualname__", "the VALUE")
        try:
            hints = typing.get_type_hints(f)
            names = [p.name for p in inspect.signature(f).parameters.values()]
        except BaseException as exc:
            raise Refused(ERR_LOAD, "{}: the type hints do not resolve: {}".format(name, ad._exception_text(exc)))
        params = [ad._hint_of_object(hints[n]) if n in hints else None for n in names]
        ret = ad._hint_of_object(hints["return"]) if "return" in hints else None
        why = ad._check_signature(name, params, ret, s["shape"], s["arg_fmts"], s["result_fmt"])
        if why:
            raise Refused(ERR_LOAD, why)
        np = sys.modules.get("numpy") if any(p and p[0] == "numpy" for p in params + [ret]) else None
        return ad.Instance(f, s["shape"], ret[0], s["arg_fmts"], s["result_fmt"], np)

    def open_instance(self, body):
        ctx, uid = struct.unpack_from("<qq", body, 0)
        if ctx not in self.contexts:
            raise Refused(ERR_INTERNAL, "open_instance: no context {}".format(ctx))
        u = self.udfs.get(uid)
        if u is None or u.inst is None:
            raise Refused(ERR_INTERNAL, "open_instance: no loaded UDF {}".format(uid))
        i = u.inst
        self.ids += 1
        self.instances[self.ids] = (self.ad.Instance(i.f, i.shape, i.kind, i.arg_fmts, i.result_fmt, i.np), u.spec)
        return struct.pack("<q", self.ids)

    # ---- a call --------------------------------------------------------------------

    def call_batch(self, h, payload, slot):
        """`payload`: the request's bytes (a slot view or an inline buffer)."""
        inst_id, deadline, _call_id = struct.unpack_from("<QqQ", payload, 0)
        entry = self.instances.get(inst_id)
        if entry is None:
            raise Refused(ERR_INTERNAL, "call_batch: no instance {}".format(inst_id))
        inst, spec = entry
        exporter = SlotBuffer(self, h[4], payload) if slot else None
        base = memoryview(exporter) if exporter is not None else payload
        views = []
        try:
            if self.pa is not None:
                n, cols, keep = self.pa_columns(base, spec)
            else:
                n, raw = self.ipc.read_batch(base, CALL_HEAD, len(base) - CALL_HEAD, [8] * len(spec["args"]))
                cols = []
                for fmt, (vat, bat, _nulls) in zip(spec["arg_fmts"], raw):
                    d = base[vat : vat + 8 * n]
                    v = base[bat : bat + (n + 7) // 8] if bat is not None else None
                    views += [d] if v is None else [d, v]
                    cols.append((fmt, d, v, 0))
                keep = None
            return self.run(inst, spec, n, cols, deadline)
        except self.ipc.IpcError as exc:
            raise Refused(ERR_INTERNAL, "UDF_RUNTIME_FAULT: the engine's batch: {}".format(exc))
        finally:
            cols = keep = None
            for v in views:
                try:
                    v.release()
                except BufferError:
                    pass  # user code still views it; the slot waits for it
            if exporter is not None:
                try:
                    base.release()
                except BufferError:
                    pass
                exporter.finish()

    def pa_columns(self, base, spec):
        pa = self.pa
        types = {"l": pa.int64(), "g": pa.float64()}
        if not hasattr(self, "_pa_schema") or self._pa_schema[0] is not spec:
            self._pa_schema = (spec, pa.schema([(f[0], types[f[1]], f[2]) for f in spec["args"]]))
        batch = pa.ipc.read_record_batch(pa.py_buffer(base[CALL_HEAD:]), self._pa_schema[1])
        cols = []
        for fmt, arr in zip(spec["arg_fmts"], batch.columns):
            bufs = arr.buffers()
            v = memoryview(bufs[0]) if bufs[0] is not None and arr.null_count else None
            cols.append((fmt, memoryview(bufs[1]), v, arr.offset))
        return batch.num_rows, cols, batch

    def run(self, inst, spec, n, cols, deadline):
        """Calls the adapter; returns the reply's size in the heap, or an
        inline payload."""
        w = self.writer
        rfmt = spec["result_fmt"]
        scalar = spec["shape"] == SHAPE_SCALAR
        _, voff, body = w.layout(n, 8)
        size = w.head + body
        in_heap = self.mm is not None and self.pa is None and size <= self.heap
        out = outv = None
        if scalar:
            if in_heap:
                dst = self.w2e
            else:
                dst = bytearray(size)
            dst[w.head : w.head + voff] = b"\xff" * voff
            outv = memoryview(dst)[w.head : w.head + (n + 7) // 8]
            out = memoryview(dst)[w.head + voff : w.head + voff + 8 * n]
        if self.ctrl is None:
            self.local_cancel.cast("i")[0] = 0  # the engine clears the shared one before each call
        r = inst.call(n, cols, out, outv, self.cancel_view, self.now, deadline)
        if out is not None:
            out.release()
            outv.release()
        if r[0] != OK:
            raise Refused(r[0], r[1], r[2], r[3])
        if scalar:
            nulls = r[1]
        else:
            data, valid, nulls, m = r[1], r[2], r[3], r[4]
            n = m
            _, voff, body = w.layout(n, 8)
            size = w.head + body
            in_heap = self.mm is not None and self.pa is None and size <= self.heap
            dst = self.w2e if in_heap else bytearray(size)
            raw = memoryview(data).cast("B")
            if len(raw) != 8 * n:
                raise Refused(ERR_RETURN_TYPE, "the result's values buffer is not 8 bytes per row")
            dst[w.head + voff : w.head + voff + 8 * n] = raw
            raw.release()
            if valid is not None:
                vb = memoryview(valid).cast("B")
                if len(vb) < (n + 7) // 8:
                    raise Refused(ERR_RETURN_TYPE, "the result's validity is shorter than its rows")
                dst[w.head : w.head + (n + 7) // 8] = vb[: (n + 7) // 8]
                vb.release()
        if self.pa is not None:
            return self.pa_encode(dst, n, voff, nulls, rfmt)
        w.write(dst, 0, n, 8, nulls)
        return size if in_heap else bytes(dst[:size])

    def pa_encode(self, dst, n, voff, nulls, rfmt):
        pa = self.pa
        w = self.writer
        typ = pa.int64() if rfmt == "l" else pa.float64()
        valid = pa.py_buffer(bytes(dst[w.head : w.head + (n + 7) // 8])) if nulls else None
        values = pa.py_buffer(bytes(dst[w.head + voff : w.head + voff + 8 * n]))
        arr = pa.Array.from_buffers(typ, n, [valid, values], null_count=nulls)
        msg = pa.RecordBatch.from_arrays([arr], names=["result"]).serialize()
        if self.mm is not None and msg.size <= self.heap:
            self.w2e[: msg.size] = memoryview(msg).cast("B")
            return msg.size
        return msg.to_pybytes()

    # ---- the loop --------------------------------------------------------------------

    def fork(self, req, fds):
        if self.role != "zygote" or len(fds) != 1:
            raise Refused(ERR_INTERNAL, "FORK: not a zygote, or no socket came with it")
        threads = len(os.listdir("/proc/self/task"))
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            pid = os.fork()
        if pid == 0:
            signal.signal(signal.SIGCHLD, signal.SIG_DFL)
            self.sock.close()
            os.dup2(fds[0], 3)
            os.close(fds[0])
            self.sock = socket.socket(fileno=3)
            self.role = "context"
            if self.mm is not None:
                self.ctrl = self.e2w = self.w2e = self.cancel_view = None
                self.mm.close()
                self.mm = None
            return False
        os.close(fds[0])
        text = "; ".join(str(w.message) for w in caught)
        self.send(OP["OK"], req, struct.pack("<ii", pid, threads) + _s(text))
        return True

    def serve(self):
        if self.role == "zygote":
            signal.signal(signal.SIGCHLD, signal.SIG_IGN)  # the kernel reaps the children
        hello_done = False
        while True:
            h, fds = self.recv_header(not hello_done or self.role == "zygote")
            t0 = time.perf_counter_ns()
            _, op, req, flags, slot, off, length = h
            if op == OP["CANCEL"]:
                continue  # a cancel for a call that already answered
            self.req = req
            payload = b""
            in_slot = False
            if length and flags & INLINE:
                payload = memoryview(self.recv_exact(length))
            elif length:
                if self.mm is None or off + length > self.heap:
                    self.send_error(req, ERR_INTERNAL, "a payload outside the engine-to-worker heap")
                    continue
                payload = self.e2w[off : off + length]
                in_slot = True
            try:
                if op == OP["HELLO"]:
                    self.send(OP["OK"], req, self.hello(payload, fds))
                    hello_done = True
                elif op == OP["SHUTDOWN"]:
                    os._exit(0)
                elif op == OP["FORK"]:
                    if not self.fork(req, fds):
                        hello_done = False  # the child: its HELLO is next
                elif op == OP["CALL_BATCH"]:
                    out = self.call_batch(h, payload, in_slot)
                    if isinstance(out, int):
                        self.send(OP["OK"], req, in_heap=out, service_ns=time.perf_counter_ns() - t0)
                    else:
                        self.send(OP["OK"], req, out, service_ns=time.perf_counter_ns() - t0)
                else:
                    self.send(OP["OK"], req, self.control(op, payload))
            except Refused as r:
                self.send_error(req, r.code, r.message, r.trace, r.row)
            except Exception as exc:
                self.send_error(req, ERR_INTERNAL, "komira_udf_pyworker: {}".format(self.ad._exception_text(exc)),
                                traceback.format_exc())
            finally:
                payload = None

    def control(self, op, body):
        if op == OP["DESCRIBE"]:
            return self.describe()
        if op == OP["VALIDATE"]:
            self.validate(self.read_spec(body))
            return b""
        if op == OP["LOAD"]:
            return self.load(body)
        if op == OP["UNLOAD"]:
            self.udfs.pop(struct.unpack_from("<q", body, 0)[0], None)
            return b""
        if op == OP["OPEN_CONTEXT"]:
            if self.role != "context":
                raise Refused(ERR_INTERNAL, "OPEN_CONTEXT on a {} worker".format(self.role))
            self.ids += 1
            self.contexts[self.ids] = struct.unpack_from("<I", body, 0)[0]
            return struct.pack("<q", self.ids)
        if op == OP["CLOSE_CONTEXT"]:
            self.contexts.pop(struct.unpack_from("<q", body, 0)[0], None)
            return b""
        if op == OP["OPEN_INSTANCE"]:
            return self.open_instance(body)
        if op == OP["CLOSE_INSTANCE"]:
            self.instances.pop(struct.unpack_from("<q", body, 0)[0], None)
            return b""
        raise Refused(ERR_UNSUPPORTED, "op {} is not served by this worker".format(op))


def main(argv):
    opts = dict(zip(argv[1::2], argv[2::2]))
    role, rtdir, codec = opts.get("--role"), opts.get("--dir"), opts.get("--codec", "own")
    if role not in ("control", "zygote", "context") or not rtdir:
        raise SystemExit("usage: komira_udf_pyworker.py --role control|zygote|context --dir D [--codec own|pyarrow]")
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))  # a crash leaves no core file behind
    sys.path[:0] = [os.path.join(rtdir, "pyworker"), os.path.join(rtdir, "pyrt")]
    for lib in ("libgcc_s.so.1", "libstdc++.so.6", "libz.so.1"):
        p = os.path.join(rtdir, "native", "lib", lib)
        if os.path.exists(p):
            ctypes.CDLL(p, mode=ctypes.RTLD_GLOBAL)
    import komira_udf_pyrt

    komira_udf_pyrt.add_site_dirs(os.path.join(rtdir, "site"))
    Worker(role, rtdir, codec).serve()


if __name__ == "__main__":
    main(sys.argv)
