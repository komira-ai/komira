"""The zygote: the long-lived process that loads UDF code once and forks workers.

Run by path, `python -I -X utf8 zygote.py --control-fd 3 --wire-version 3 --scratch <dir>
[--sys-path <entry>]...`. Until the `--sys-path` entries are on `sys.path` it imports only
the standard library; its sibling modules are loaded by file path, so importing the
`komira` package (and what that pulls in) is never needed.
"""

import argparse
import hashlib
import importlib
import importlib.util
import os
import select
import signal
import socket
import struct
import sys
import traceback


def _load_sibling(name):
    """Load `name`.py from this file's directory as module `_komira_udf_<name>`."""
    key = "_komira_udf_" + name
    mod = sys.modules.get(key)
    if mod is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
        spec = importlib.util.spec_from_file_location(key, path)
        mod = importlib.util.module_from_spec(spec)
        sys.modules[key] = mod
        spec.loader.exec_module(mod)
    return mod


def _parse_args(argv):
    p = argparse.ArgumentParser(prog="zygote")
    p.add_argument("--control-fd", type=int, required=True)
    p.add_argument("--wire-version", type=int, required=True)
    p.add_argument("--scratch", required=True)
    p.add_argument("--sys-path", action="append", default=[])
    return p.parse_args(argv)


def thread_count():
    """The number of OS threads of this process. On macOS, less the threads of its dispatch
    workqueue: those the kernel starts for libdispatch, which loading some libraries does
    (libarrow does: `import pyarrow` leaves one), and which a fork does not copy."""
    if sys.platform.startswith("linux"):
        with open("/proc/self/status", "rb") as f:
            for line in f:
                if line.startswith(b"Threads:"):
                    return int(line.split()[1])
        raise RuntimeError("no Threads line in /proc/self/status")
    if sys.platform == "darwin":
        import ctypes

        class TaskInfo(ctypes.Structure):
            _fields_ = [(n, ctypes.c_uint64) for n in (
                "pti_virtual_size", "pti_resident_size", "pti_total_user",
                "pti_total_system", "pti_threads_user", "pti_threads_system")] + [
                (n, ctypes.c_int32) for n in (
                "pti_policy", "pti_faults", "pti_pageins", "pti_cow_faults",
                "pti_messages_sent", "pti_messages_received", "pti_syscalls_mach",
                "pti_syscalls_unix", "pti_csw", "pti_threadnum", "pti_numrunning",
                "pti_priority")]

        proc_pidinfo = ctypes.CDLL(None, use_errno=True).proc_pidinfo
        proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        info = TaskInfo()
        got = proc_pidinfo(os.getpid(), 4, 0, ctypes.byref(info), ctypes.sizeof(info))
        if got != ctypes.sizeof(info):
            raise RuntimeError("proc_pidinfo(PROC_PIDTASKINFO) returned %d" % got)
        # PROC_PIDWORKQUEUEINFO (12): pwq_nthreads, pwq_runthreads, pwq_blockedthreads,
        # pwq_state. It returns 0 bytes for a process that has no workqueue.
        workqueue = (ctypes.c_uint32 * 4)()
        got = proc_pidinfo(os.getpid(), 12, 0, ctypes.byref(workqueue), ctypes.sizeof(workqueue))
        if got not in (0, ctypes.sizeof(workqueue)):
            raise RuntimeError("proc_pidinfo(PROC_PIDWORKQUEUEINFO) returned %d" % got)
        return info.pti_threadnum - (workqueue[0] if got else 0)
    import threading

    return threading.active_count()


def _free_threaded():
    import sysconfig

    if sysconfig.get_config_var("Py_GIL_DISABLED"):
        return True
    gil_enabled = getattr(sys, "_is_gil_enabled", None)
    return bool(gil_enabled is not None and not gil_enabled())


class _Refusal(Exception):
    """A request answered with an ERROR reply."""

    def __init__(self, code, message, trace="", flags=0):
        super().__init__(message)
        self.code = code
        self.message = message
        self.trace = trace
        self.flags = flags


class Zygote:
    def __init__(self, args, wire, worker):
        self.wire = wire
        self.worker = worker
        self.scratch = args.scratch
        self.wire_version = args.wire_version
        self.pid = os.getpid()
        self.ctl = socket.socket(fileno=args.control_fd)
        self.registry = {}
        self.bundles = {}
        self.workers = {}  # pid -> context id
        self.wake_r, self.wake_w = os.pipe()
        os.set_blocking(self.wake_r, False)
        os.set_blocking(self.wake_w, False)
        signal.signal(signal.SIGCHLD, lambda *_: None)
        signal.set_wakeup_fd(self.wake_w, warn_on_full_buffer=False)

    # --- main loop ---------------------------------------------------------

    def run(self):
        while True:
            ready, _, _ = select.select([self.ctl, self.wake_r], [], [])
            try:
                if self.wake_r in ready:
                    self._reap()
                if self.ctl in ready:
                    msg = self.wire.recv_message(self.ctl)
                    if msg is None:
                        return self._stop_workers()
                    if self._handle(msg):
                        return 0
            except (self.wire.WireError, OSError):
                self._stop_workers()
                return 1

    def _stop_workers(self):
        for pid in list(self.workers):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for pid in list(self.workers):
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        self.workers.clear()
        return 0

    def _reap(self):
        try:
            while os.read(self.wake_r, 4096):
                pass
        except BlockingIOError:
            pass
        while True:
            try:
                pid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                return
            if pid == 0:
                return
            ctx = self.workers.pop(pid, None)
            if ctx is None:
                continue
            if os.WIFEXITED(status):
                how, value = 0, os.WEXITSTATUS(status)
            elif os.WIFSIGNALED(status):
                how, value = 1, os.WTERMSIG(status)
            else:
                continue
            self.wire.send_message(self.ctl, self.wire.OP_EXIT, 0, struct.pack("<QIii", ctx, pid, how, value))

    # --- requests ----------------------------------------------------------

    def _handle(self, msg):
        """Answer one request; return True when the zygote should exit."""
        w = self.wire
        reply_fds = []
        try:
            handle, _deadline, _call, body = w.split_request(msg.payload)
            if msg.op == w.OP_HELLO:
                reply = self._hello(body)
            elif msg.op == w.OP_LOAD:
                reply = self._load(handle, body)
            elif msg.op == w.OP_UNLOAD:
                self.registry.pop(handle, None)
                reply = struct.pack("<I", len(self.registry))
            elif msg.op == w.OP_FORK:
                reply, pidfd = self._fork(handle, body, msg.fds)
                if pidfd is not None:
                    reply_fds.append(pidfd)
            elif msg.op == w.OP_SHUTDOWN:
                self._stop_workers()
                w.send_ok(self.ctl, msg.request_id)
                return True
            else:
                raise _Refusal(w.ERR_INTERNAL, "unexpected op %d on the control channel" % msg.op)
        except _Refusal as r:
            w.send_error(self.ctl, msg.request_id, r.code, r.message, trace=r.trace, flags=r.flags)
            return False
        except w.WireError as e:
            w.send_error(self.ctl, msg.request_id, w.ERR_INTERNAL, "malformed request: %s" % e)
            return False
        except Exception as e:
            w.send_error(
                self.ctl, msg.request_id, w.ERR_INTERNAL, "%s: %s" % (type(e).__name__, e),
                trace="".join(traceback.format_exception(type(e), e, e.__traceback__)),
            )
            return False
        finally:
            if msg.op != w.OP_FORK:
                w._close_all(msg.fds)
        try:
            w.send_message(self.ctl, w.OP_OK, msg.request_id, reply, fds=reply_fds)
        finally:
            w._close_all(reply_fds)
        return False

    def _hello(self, body):
        w = self.wire
        if len(body) < 12:
            raise _Refusal(w.ERR_INTERNAL, "HELLO body of %d bytes is too short" % len(body))
        (version,) = struct.unpack_from("<I", body, 0)
        if version != w.WIRE_VERSION or self.wire_version != w.WIRE_VERSION:
            raise _Refusal(
                w.ERR_ABI,
                "wire version %d requested, this zygote speaks %d" % (version, w.WIRE_VERSION),
            )
        return (
            struct.pack("<III", w.WIRE_VERSION, self.pid, 1 if _free_threaded() else 0)
            + w.pack_str(sys.implementation.name)
            + w.pack_str(getattr(sys.implementation, "cache_tag", None) or "")
            + w.pack_str(importlib.util.MAGIC_NUMBER.hex())
        )

    def _find_schema(self, body, candidates):
        """Read `u32 len, IPC Schema message` at the first candidate offset where an
        encapsulated message (continuation marker) starts; return (bytes, offset after)."""
        for off in candidates:
            if off + 8 <= len(body):
                (n,) = struct.unpack_from("<I", body, off)
                if bytes(body[off + 4 : off + 8]) == b"\xff\xff\xff\xff" and off + 4 + n <= len(body):
                    return bytes(body[off + 4 : off + 4 + n]), off + 4 + n
        raise self.wire.WireError("no Arrow IPC schema message in the LOAD body")

    def _parse_load(self, body):
        w = self.wire
        form, shape, batch_format, null_mode = struct.unpack_from("<IIII", body, 0)
        off = 16
        entry, off = w.read_str(body, off)
        code_root, off = w.read_str(body, off)
        (n_code,) = struct.unpack_from("<I", body, off)
        off += 4
        codes = []
        for _ in range(n_code):
            role, off = w.read_str(body, off)
            if off + 32 > len(body):
                raise w.WireError("code object digest truncated at byte %d" % off)
            codes.append((role, bytes(body[off : off + 32])))
            off += 32
        schema_args, off = self._find_schema(body, sorted({off, (off + 7) & ~7}))
        schema_result, off = self._find_schema(body, sorted({off, (off + 7) & ~7}))
        return form, shape, batch_format, null_mode, entry, code_root, codes, schema_args, schema_result

    def _check_codes(self, code_root, codes):
        w = self.wire
        for role, digest in codes:
            want = digest.hex()
            try:
                with open(os.path.join(code_root, want), "rb") as f:
                    data = f.read()
            except OSError:
                raise _Refusal(w.ERR_CODE_DIGEST, "code object %s %s: missing" % (role, want)) from None
            got = hashlib.sha256(data).hexdigest()
            if got != want:
                raise _Refusal(
                    w.ERR_CODE_DIGEST, "code object %s %s: the bytes' sha256 is %s" % (role, want, got)
                )

    def _load(self, udf, body):
        w = self.wire
        form, shape, batch_format, null_mode, entry, code_root, codes, sa, sr = self._parse_load(body)
        self._check_codes(code_root, codes)
        module, _, qualname = entry.partition(":")
        if form == w.FORM_BUNDLE:
            bundle = next((d.hex() for r, d in codes if r == "bundle"), None)
            if bundle is None:
                raise _Refusal(w.ERR_INTERNAL, "a BUNDLE load lists no code object of role 'bundle'")
            top = module.split(".")[0]
            previous = self.bundles.get(top)
            if previous is not None and previous != bundle:
                raise _Refusal(
                    w.ERR_LOAD,
                    "module '%s' was imported from another bundle" % module,
                    flags=w.FLAG_RETIRE | w.FLAG_RETRY,
                )
            self.bundles[top] = bundle
            path = os.path.join(code_root, bundle)
            if path not in sys.path:
                sys.path.append(path)
                importlib.invalidate_caches()
        try:
            fn = importlib.import_module(module)
            for part in qualname.split("."):
                fn = getattr(fn, part)
        except BaseException as e:  # a module may raise anything at import, SystemExit included
            raise _Refusal(
                w.ERR_LOAD,
                "import of '%s' failed: %s: %s" % (module, type(e).__name__, e),
                trace="".join(traceback.format_exception(type(e), e, e.__traceback__)),
            ) from None
        if not callable(fn):
            raise _Refusal(w.ERR_LOAD, "'%s' is not callable" % entry)
        threads = thread_count()
        if threads > 1:
            raise _Refusal(
                w.ERR_LOAD,
                "importing '%s' started %d thread(s) (%d threads); Python UDFs run in workers "
                "forked from a single-threaded process" % (module, threads - 1, threads),
                flags=w.FLAG_RETIRE,
            )
        self.registry[udf] = {
            "fn": fn,
            "entry": entry,
            "form": form,
            "shape": shape,
            "batch_format": batch_format,
            "schema_args": sa,
            "schema_result": sr,
        }
        return struct.pack("<I", threads)

    def _fork(self, context, body, fds):
        w = self.wire
        if len(fds) != 2 or len(body) < 4:
            w._close_all(fds)
            raise _Refusal(w.ERR_INTERNAL, "FORK needs a slot and two descriptors")
        threads = thread_count()
        if threads > 1:
            w._close_all(fds)
            raise _Refusal(w.ERR_INTERNAL, "FORK in a process of %d threads" % threads)
        for stream in (sys.stdout, sys.stderr):
            stream.flush()
        try:
            pid = os.fork()
        except OSError as e:
            w._close_all(fds)
            raise _Refusal(w.ERR_INTERNAL, "fork failed: %s" % e) from None
        if pid == 0:
            # The child never returns into the zygote's loop, whatever serve raises.
            try:
                self.worker.serve(
                    fds[0], fds[1], self.ctl, (self.wake_r, self.wake_w), self.pid, self.scratch, self.registry
                )
            finally:
                os._exit(1)
        w._close_all(fds)
        self.workers[pid] = context
        if not sys.platform.startswith("linux"):
            # macOS has no pidfd: the reply carries the pid alone, and the library signals
            # the worker by its pid while its socket is open (docs/design/udf_python_worker.md 5.3).
            return struct.pack("<I", pid), None
        try:
            # Opened before the worker can be reaped (this loop reaps), so it names this
            # process and no later one with its pid: the library signals the worker only
            # through it.
            pidfd = os.pidfd_open(pid)
        except OSError as e:
            os.kill(pid, signal.SIGKILL)
            raise _Refusal(w.ERR_INTERNAL, "pidfd_open of the new worker failed: %s" % e) from None
        return struct.pack("<I", pid), pidfd


def main(argv=None):
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    os.closerange(4, 1 << 16)
    for entry in args.sys_path:
        sys.path.append(entry)
    wire = _load_sibling("wire")
    sys.modules.setdefault("_komira_udf_wire", wire)
    worker = _load_sibling("worker")
    return Zygote(args, wire, worker).run()


if __name__ == "__main__":
    sys.exit(main())
