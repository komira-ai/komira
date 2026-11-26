"""The processes of the komira/python runtime: a zygote per generation, a forked
worker per context, the import checks of load, the worker's sandbox, and what
shutdown leaves behind.

    test_udf_process.py --lib-dir <dir>

`<dir>/libkomira_udf_python.so` (`libkomira_udf_python.dylib` on macOS) is
`//src/udf_python:komira_udf_python`.
"""

import errno
import json
import os
import sys

import pyarrow as pa

import udf_host as h

I64 = pa.int64()


def ints(*values):
    return pa.array(list(values), I64)


def listing(path):
    with open(path, encoding="utf-8") as f:
        return f.read().splitlines()


def spawned(env, gen):
    (e,) = [e for e in env.trace.events("spawn") if e["gen"] == str(gen)]
    return int(e["pid"])


WHO = """import os

def who(k):
    return os.getpid() if k == 0 else os.getppid()
"""


def two_contexts_run_in_two_workers_forked_from_the_zygote(env):
    rt = env.runtime()
    udf = rt.load_ok(env.bundle_spec({"who.py": WHO}, "who:who"))
    zygote = spawned(env, 1)
    assert zygote != os.getpid()
    seen = []
    for _ in range(2):
        ctx = rt.open_context_ok()
        out = ctx.open_instance_ok(udf).call_ok([ints(0, 1)])
        assert len(out) == 2
        pid, parent = out.to_pylist()
        assert parent == zygote, (parent, zygote)
        assert pid not in (os.getpid(), zygote), pid
        seen.append(pid)
    assert seen[0] != seen[1], seen
    assert sorted(env.trace.pids("fork")) == sorted(seen), env.trace.events("fork")
    assert env.trace.pids("spawn") == [zygote]
    assert env.trace.events("hello")[0]["tag"] == h.abi_tag()


IMPORTED = """OUT = %r
with open(OUT, "a", encoding="utf-8") as f:
    f.write("imported\\n")

def twice(x):
    return x * 2
"""


def the_bundle_is_imported_once_for_four_contexts(env):
    out = env.path("imports.txt")
    rt = env.runtime()
    udf = rt.load_ok(env.bundle_spec({"once.py": IMPORTED % out}, "once:twice"))
    ctxs = [rt.open_context_ok(slot) for slot in range(4)]
    for ctx in ctxs:
        assert ctx.open_instance_ok(udf).call_ok([ints(1, 2, 3)]).to_pylist() == [2, 4, 6]
    assert listing(out) == ["imported"]
    assert len(env.trace.events("fork")) == 4


THREADS = {
    "thread_mod": ("import threading\n_e = threading.Event()\n"
                   "threading.Thread(target=_e.wait, daemon=True).start()\n\n"
                   "def f(x):\n    return x\n"),
    "raw_thread_mod": ("import _thread\n_l = _thread.allocate_lock()\n_l.acquire()\n"
                       "_thread.start_new_thread(_l.acquire, ())\n\n"
                       "def f(x):\n    return x\n"),
    "plain_mod": "def f(x):\n    return x + 1\n",
}


def an_import_that_starts_a_thread_retires_the_generation(env):
    rt = env.runtime()
    for gen, mod in ((1, "thread_mod"), (2, "raw_thread_mod")):
        status, udf, err = rt.load(env.bundle_spec({mod + ".py": THREADS[mod]}, mod + ":f"))
        assert (status, udf) == (h.ERR_LOAD, None)
        assert err.message == (
            "importing '%s' started 1 thread(s) (2 threads); Python UDFs run in workers "
            "forked from a single-threaded process" % mod), err
        names = env.trace.names()
        assert "fork" not in names
        assert "retire" in names[-3:] and names[-1] == "shutdown", names
        assert env.trace.events("retire")[-1]["gen"] == str(gen)
        assert h.process_gone(spawned(env, gen)), "the retired zygote was not reaped"
    udf = rt.load_ok(env.bundle_spec({"plain_mod.py": THREADS["plain_mod"]}, "plain_mod:f"))
    assert spawned(env, 3) not in (spawned(env, 1), spawned(env, 2))
    assert env.trace.events("load")[-1]["gen"] == "3"
    ctx = rt.open_context_ok()
    assert ctx.open_instance_ok(udf).call_ok([ints(1)]).to_pylist() == [2]


def a_runtime_whose_abi_differs_from_the_interpreter_refuses_the_load(env):
    rt = env.runtime(options=env.options(abi="cp399"))
    status, udf, err = rt.load(env.bundle_spec({"plain_mod.py": THREADS["plain_mod"]}, "plain_mod:f"))
    assert (status, udf) == (h.ERR_ABI, None)
    assert err.message == "the interpreter's tag %s differs from the runtime's abi cp399" % h.abi_tag(), err
    assert env.trace.names()[-1] == "shutdown", env.trace.names()
    assert h.process_gone(spawned(env, 1))


def a_missing_interpreter_fails_the_first_load_naming_it(env):
    missing = env.path("no_such_python")
    rt = env.runtime(options=env.options(interpreter=missing))
    status, udf, err = rt.load(env.bundle_spec({"plain_mod.py": THREADS["plain_mod"]}, "plain_mod:f"))
    assert (status, udf) == (h.ERR_LOAD, None)
    assert err.message == "could not start the interpreter '%s': %s" % (
        missing, os.strerror(errno.ENOENT)), err
    assert env.trace.events("spawn") == []


def a_bundle_whose_bytes_differ_from_the_digest_is_not_imported(env):
    out = env.path("imports.txt")
    rt = env.runtime()
    spec = env.bundle_spec({"once.py": IMPORTED % out}, "once:twice")
    other = h.make_zip({"once.py": "raise SystemExit\n"})
    path = os.path.join(env.code_root, spec.hex)
    with open(path, "wb") as f:
        f.write(other)
    import hashlib

    got = hashlib.sha256(other).hexdigest()
    status, udf, err = rt.load(spec)
    assert (status, udf) == (h.ERR_CODE_DIGEST, None)
    assert err.message == "code object bundle %s: the bytes' sha256 is %s" % (spec.hex, got), err
    assert not os.path.exists(out), "the bundle was imported"
    os.unlink(path)
    status, udf, err = rt.load(spec)
    assert status == h.ERR_CODE_DIGEST
    assert err.message == "code object bundle %s: missing" % spec.hex, err
    assert not os.path.exists(out)


PROBE = """import json, os, sys

OUT = %r

def probe(x):
    fds = fd_names()
    info = {
        "environ": dict(os.environ), "cwd": os.getcwd(), "cwd_list": os.listdir("."),
        "isolated": sys.flags.isolated, "utf8": sys.flags.utf8_mode, "fds": fds,
    }
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(info, f)
    return x
""" + h.FD_NAMES


def the_worker_runs_isolated_with_its_own_environment_directories_and_fds(env):
    out = env.path("probe.json")
    rt = env.runtime()
    udf = rt.load_ok(env.bundle_spec({"probe.py": PROBE % out}, "probe:probe"))
    ctx = rt.open_context_ok()
    assert ctx.open_instance_ok(udf).call_ok([ints(7)]).to_pylist() == [7]
    with open(out, encoding="utf-8") as f:
        info = json.load(f)
    environ = info["environ"]
    home = environ.pop("HOME")
    tmp = environ.pop("TMPDIR")
    if sys.platform == "darwin":
        # CoreFoundation sets this one in its own process as it starts (libarrow links it):
        # "0x<uid>:<encoding>:<region>", not the engine's.
        cf = environ.pop("__CF_USER_TEXT_ENCODING")
        assert cf.startswith("0x%X:" % os.getuid()), cf
    assert environ == {
        "OMP_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1", "MKL_NUM_THREADS": "1",
        "VECLIB_MAXIMUM_THREADS": "1", "NUMEXPR_NUM_THREADS": "1",
        "JE_ARROW_MALLOC_CONF": "background_thread:false", "LC_ALL": "C",
        "TZ": "UTC", "PATH": "/usr/bin:/bin",
    }, environ
    work = os.path.dirname(home)
    assert os.path.basename(work).startswith("worker-"), work
    assert (home, tmp, info["cwd"]) == (work + "/home", work + "/tmp", work + "/cwd")
    zygote_dir = os.path.dirname(work)
    assert os.path.dirname(zygote_dir) == env.scratch, zygote_dir
    assert os.path.basename(zygote_dir).startswith("zygote-"), zygote_dir
    assert info["cwd_list"] == []
    assert (info["isolated"], info["utf8"]) == (1, 1)
    fds = {int(k): v for k, v in info["fds"].items()}
    assert fds[0] == "/dev/null", fds
    # CPython 3.14 holds its own executable open; that descriptor is the
    # interpreter's, not one the runtime passed down.
    exe = os.path.realpath(sys.executable)
    rest = sorted(v for k, v in fds.items() if k > 2 and v != exe)
    if sys.platform == "darwin":
        # The cancel word, a file under the runtime's scratch that is unlinked already
        # (F_GETPATH still names it); the kqueue of the thread that ends the worker with its
        # zygote, which fstat reports as S_IFIFO; and the worker's socket.
        assert len(rest) == 3 and os.path.dirname(rest[0]) == env.scratch and \
            os.path.basename(rest[0]).startswith("cancel-") and not os.path.exists(rest[0]) and \
            rest[1:] == ["mode:10000", "socket:"], fds
    else:
        assert len(rest) == 2 and rest[0].startswith("/memfd:komira-udf-cancel") and \
            rest[1].startswith("socket:"), fds


NOISY = """import sys

def noisy(x):
    sys.stdout.write("." * (1 << 20))
    sys.stdout.flush()
    sys.stderr.write("." * (1 << 20))
    sys.stderr.flush()
    return x + 1
"""


def a_megabyte_on_stdout_and_stderr_per_batch_does_not_block_the_protocol(env):
    # The zygote and its workers inherit descriptors 1 and 2 when the first
    # load spawns the zygote, so point them at files for this case: the bytes
    # land there, not in the test's own output.
    sys.stdout.flush()
    sys.stderr.flush()
    saved = [os.dup(1), os.dup(2)]
    outs = [env.path("stdout"), env.path("stderr")]
    try:
        for fd, path in zip((1, 2), outs):
            out = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.dup2(out, fd)
            os.close(out)
        rt = env.runtime()
        udf = rt.load_ok(env.bundle_spec({"noisy.py": NOISY}, "noisy:noisy"))
        inst = rt.open_context_ok().open_instance_ok(udf)
        for base in (0, 10):
            assert inst.call_ok([ints(base, base + 1)]).to_pylist() == [base + 1, base + 2]
        rt.shutdown()
    finally:
        for fd, old in zip((1, 2), saved):
            os.dup2(old, fd)
            os.close(old)
    for path in outs:
        with open(path, "rb") as f:
            got = f.read()
        assert got == b"." * (4 << 20), (path, len(got), got.replace(b".", b"")[:400])


ODD = """import os, sys

def odd(x):
    if x == 1:
        input()
    if x == 2:
        sys.exit(0)
    if x == 3:
        raise KeyboardInterrupt
    return os.getpid()
"""


def input_exit_and_interrupt_are_raised_errors_and_the_worker_survives(env):
    rt = env.runtime()
    udf = rt.load_ok(env.bundle_spec({"odd.py": ODD}, "odd:odd"))
    inst = rt.open_context_ok().open_instance_ok(udf)
    (pid,) = inst.call_ok([ints(0)]).to_pylist()
    for value, message in ((1, "EOFError: EOF when reading a line"), (2, "SystemExit: 0"),
                           (3, "KeyboardInterrupt")):
        r = inst.call([ints(value)])
        assert (r.status, r.err.message, r.err.row) == (h.ERR_RAISED, message, 0), r.err
        assert inst.call_ok([ints(0)]).to_pylist() == [pid]
    assert len(env.trace.events("fork")) == 1


def an_instance_of_a_udf_loaded_after_its_context_opened_is_refused(env):
    rt = env.runtime()
    first = rt.load_ok(env.bundle_spec({"plain_mod.py": THREADS["plain_mod"]}, "plain_mod:f"))
    ctx = rt.open_context_ok()
    second = rt.load_ok(env.bundle_spec({"who.py": WHO}, "who:who"))
    status, inst, err = ctx.open_instance(second)
    assert (status, inst) == (h.ERR_UNSUPPORTED, None)
    assert err.message == "UDF 'who:who' was loaded after this context was opened; open a new context", err
    assert ctx.open_instance_ok(first).call_ok([ints(1)]).to_pylist() == [2]
    again = rt.open_context_ok()
    assert again.open_instance_ok(second).call_ok([ints(0)]).to_pylist()[0] != os.getpid()


def shutdown_leaves_no_zygote_and_no_worker(env):
    rt = env.runtime()
    udf = rt.load_ok(env.bundle_spec({"who.py": WHO}, "who:who"))
    workers = []
    for _ in range(3):
        ctx = rt.open_context_ok()
        workers.append(ctx.open_instance_ok(udf).call_ok([ints(0)]).to_pylist()[0])
    zygote = spawned(env, 1)
    assert not h.process_gone(zygote)
    rt.shutdown()
    for pid in [zygote] + workers:
        assert h.process_gone(pid), "process %d outlived shutdown" % pid
    assert env.trace.events("shutdown")[-1]["pid"] == str(zygote)


def a_package_entry_imports_from_the_sys_path_options(env):
    pkg = env.path("pkgdir")
    os.mkdir(pkg)
    with open(os.path.join(pkg, "pkgmod.py"), "w", encoding="utf-8") as f:
        f.write("def inc(x):\n    return x + 1\n")
    rt = env.runtime(options=env.options() + ["sys_path=" + pkg])
    spec = h.Spec("pkgmod:inc", form=h.FORM_PACKAGE)
    udf = rt.load_ok(spec)
    assert rt.open_context_ok().open_instance_ok(udf).call_ok([ints(4)]).to_pylist() == [5]


COUNTER = """COUNT = 0


def bump(x):
    global COUNT
    COUNT += 1
    return COUNT
"""


def a_module_global_written_in_one_context_is_not_seen_by_the_next(env):
    rt = env.runtime()
    udf = rt.load_ok(env.bundle_spec({"counter.py": COUNTER}, "counter:bump"))
    first = rt.open_context_ok()
    inst = first.open_instance_ok(udf)
    assert [inst.call_ok([ints(0)]).to_pylist() for _ in range(2)] == [[1], [2]]
    inst.close()
    first.close()
    second = rt.open_context_ok()
    assert second.open_instance_ok(udf).call_ok([ints(0)]).to_pylist() == [1]


def the_check_for_processes_that_outlive_a_shutdown_names_a_running_one(env):
    import subprocess
    stray = subprocess.Popen([sys.executable, "-I", "-c", "import sys; sys.stdin.read()"],
                             stdin=subprocess.PIPE)
    try:
        assert env.leaked() == []
        with open(env.trace.path, "a", encoding="utf-8") as f:
            f.write("fork ctx=1 pid=%d\n" % stray.pid)
        assert env.leaked() == [stray.pid]
    finally:
        stray.stdin.close()
        stray.wait()
    assert env.leaked() == []


def a_runtime_that_ran_calls_leaves_no_process_after_its_shutdown(env):
    rt = env.runtime()
    udf = rt.load_ok(env.bundle_spec({"who.py": WHO}, "who:who"))
    for _ in range(2):
        rt.open_context_ok().open_instance_ok(udf).call_ok([ints(0)])
    assert len(env.trace.pids("spawn") + env.trace.pids("fork")) == 3
    rt.shutdown()
    env.runtimes.remove(rt)
    assert env.leaked() == []


def the_wire_codec_decodes_what_it_encodes_and_refuses_a_broken_stream(env):
    import socket
    from komira._udf import wire as w

    assert w.split_request(w.pack_head(7, -5, 9) + b"body") == (7, -5, 9, b"body")
    message = "r\u00e9sum\u00e9 failed"
    assert w.unpack_error(w.pack_error(w.ERR_RAISED, message, 3, 4, "trace")) == (
        w.ERR_RAISED, 3, 4, message, "trace")
    a, b = socket.socketpair()
    try:
        pipe_r, pipe_w = os.pipe()
        w.send_message(a, w.OP_CALL_BATCH, 41, b"payload", fds=[pipe_r])
        os.close(pipe_r)
        got = w.recv_message(b)
        assert (got.op, got.request_id, got.flags, got.payload) == (w.OP_CALL_BATCH, 41, w.FLAG_INLINE, b"payload")
        (passed,) = got.fds
        os.write(pipe_w, b"x")
        assert os.read(passed, 1) == b"x"
        os.close(passed)
        os.close(pipe_w)
        w.send_message(a, w.OP_OK, 42)
        assert w.recv_message(b)[:4] == (w.OP_OK, 42, 0, b"")
        a.sendall(b"\0" * w.HEADER_SIZE)
        try:
            w.recv_message(b)
        except w.WireError as e:
            assert str(e) == "bad magic 0x00000000", e
        else:
            raise AssertionError("a header with another magic was read")
        a.sendall(w.HEADER.pack(w.MAGIC, w.OP_OK, 1, 0, 0, 0, 10) + b"short")
        a.shutdown(socket.SHUT_WR)
        try:
            w.recv_message(b)
        except w.WireError as e:
            assert str(e) == "end of stream after 5 of 10 payload bytes", e
        else:
            raise AssertionError("a payload cut short was read")
        assert w.recv_message(b) is None
    finally:
        a.close()
        b.close()


def a_hello_of_another_wire_version_is_refused_by_the_zygote(env):
    import importlib.util
    import struct
    import types
    from komira._udf import wire as w

    spec = importlib.util.spec_from_file_location("zygote_under_test", h.zygote_path())
    zygote = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(zygote)
    here = types.SimpleNamespace(wire=w, wire_version=w.WIRE_VERSION, pid=1)
    body = struct.pack("<III", w.WIRE_VERSION + 1, 0, 0)
    try:
        zygote.Zygote._hello(here, body)
    except zygote._Refusal as r:
        assert (r.code, r.message) == (
            w.ERR_ABI, "wire version %d requested, this zygote speaks %d" % (w.WIRE_VERSION + 1, w.WIRE_VERSION)), r
    else:
        raise AssertionError("a HELLO of another wire version was answered")
    assert zygote.Zygote._hello(here, struct.pack("<III", w.WIRE_VERSION, 0, 0)).startswith(
        struct.pack("<III", w.WIRE_VERSION, 1, 0))


def a_result_that_is_not_exactly_the_declared_type_is_refused_with_its_row(env):
    import pyarrow as pa
    from komira._udf import worker

    def refused(value, rtype, row):
        try:
            worker._check_value(value, rtype, row)
        except worker._Fail as f:
            return f.code, f.row, f.message
        raise AssertionError("%r was accepted as %s" % (value, rtype))

    w = worker.wire
    assert refused(1 << 63, pa.int64(), 3) == (
        w.ERR_RETURN_TYPE, 3, "row 3 returned int 9223372036854775808, which is not int64 without loss")
    assert refused(True, pa.int64(), 0)[0] == w.ERR_RETURN_TYPE
    assert refused(1.5, pa.int64(), 0)[0] == w.ERR_RETURN_TYPE
    assert refused((1 << 53) + 1, pa.float64(), 2)[0] == w.ERR_RETURN_TYPE
    assert worker._check_value((1 << 63) - 1, pa.int64(), 0) == (1 << 63) - 1
    assert worker._check_value(1 << 53, pa.float64(), 0) == float(1 << 53)
    assert worker._check_value(None, pa.int64(), 0) is None


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    me = sys.modules["__main__"]
    cases = [f for f in (getattr(me, n) for n in dir(me))
             if getattr(f, "__module__", None) == "__main__" and callable(f)
             and getattr(f, "__code__", None) is not None
             and f.__code__.co_argcount == 1 and f.__code__.co_varnames[0] == "env"]
    for case in cases:
        with h.Env(lib_dir) as env:
            case(env)
        print("ok", case.__name__)


if __name__ == "__main__":
    main(sys.argv[1:])
